import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:archive/archive_io.dart';
import 'package:clipboard/clipboard.dart';
import 'package:file_picker/file_picker.dart';
import 'package:finamp/services/censored_log.dart';
import 'package:finamp/services/environment_metadata.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as path_helper;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

class FinampLogsHelper {
  final List<LogRecord> logs = [];
  IOSink? _logFileWriter;
  // While the file is being flushed, the sink takes no writes: new lines wait here.
  Future<void>? _flushing;
  final _held = <String>[];

  Future<void> openLog() async {
    WidgetsFlutterBinding.ensureInitialized();
    final basePath = (Platform.isAndroid || Platform.isIOS)
        ? await getApplicationDocumentsDirectory()
        : await getApplicationSupportDirectory();
    final logFile = File(path_helper.join(basePath.path, "finamp-logs.txt"));
    if (logFile.existsSync() && logFile.lengthSync() >= 1024 * 1024 * 10) {
      logFile.renameSync(path_helper.join(basePath.path, "finamp-logs-old.txt"));
    }
    _logFileWriter = logFile.openWrite(mode: FileMode.writeOnlyAppend);
  }

  void addLog(LogRecord log) {
    logs.add(log);
    if (_logFileWriter != null) {
      // This fails if we log an event before setting up userHelper
      var message = log.censoredMessage;
      if (log.getStack == null) {
        // Truncate long messages from chopper, but leave long stack traces
        message = message.substring(0, min(1024 * 5, message.length));
      }
      if (_flushing != null) {
        _held.add(message);
      } else {
        _logFileWriter!.writeln(message);
      }
    }

    // We don't want to keep logs forever due to memory constraints. Trimmed a tenth at a time, as taking the first
    // off a list moves all the rest.
    if (logs.length > keptLogs + keptLogs ~/ 10) {
      logs.removeRange(0, logs.length - keptLogs);
    }
  }

  /// How many of the latest logs are kept in memory (up to a tenth more before they're trimmed).
  @visibleForTesting
  static const keptLogs = kDebugMode ? 10000 : 1000;

  /// Sanitises all logs and returns a massive string
  String getSanitisedLogs() {
    final logsStringBuffer = StringBuffer();

    for (final log in logs) {
      logsStringBuffer.writeln(log.censoredMessage);
    }

    return logsStringBuffer.toString();
  }

  Future<String> getFullLogs() async {
    final fullLogsBuffer = StringBuffer();

    // Get the Log instance and add its metadata at the top
    final logMeta = await EnvironmentMetadata.create();

    // Prepend this metadata to the logs
    fullLogsBuffer.writeln("=== METADATA ===");
    fullLogsBuffer.writeln(logMeta.pretty);
    fullLogsBuffer.writeln("=== LOGS ===");

    if (_logFileWriter != null) {
      final basePath = (Platform.isAndroid || Platform.isIOS)
          ? await getApplicationDocumentsDirectory()
          : await getApplicationSupportDirectory();
      var oldLogs = File(path_helper.join(basePath.path, "finamp-logs-old.txt"));
      var newLogs = File(path_helper.join(basePath.path, "finamp-logs.txt"));
      if (oldLogs.existsSync()) {
        fullLogsBuffer.write(await oldLogs.readAsString());
      }
      if (newLogs.existsSync()) {
        fullLogsBuffer.write(await newLogs.readAsString());
      }
    } else {
      fullLogsBuffer.write(getSanitisedLogs());
    }
    return fullLogsBuffer.toString();
  }

  Future<void> copyLogs() async => await FlutterClipboard.copy(getSanitisedLogs());

  /// Write logs to a file and share the file
  Future<void> shareLogs() async {
    final tempDir = await getTemporaryDirectory();
    final (zipName, internalName) = _logExportName();
    final tempFile = File(path_helper.join(tempDir.path, zipName));
    tempFile.createSync();

    await tempFile.writeAsBytes(await _getLogsArchive(internalName));

    final xFile = XFile(tempFile.path, mimeType: "application/zip");
    await SharePlus.instance.share(ShareParams(files: [xFile]));

    await tempFile.delete();
  }

  /// Write logs to a file and save to user-picked directory
  Future<void> exportLogs() async {
    final (zipName, internalName) = _logExportName();

    await FilePicker.saveFile(
      fileName: zipName,
      // initialDirectory is ignored on mobile
      // initialDirectory only seems to work with a trailing separator for some reason
      initialDirectory: (await getApplicationDocumentsDirectory()).path + path_helper.separator,
      bytes: await _getLogsArchive(internalName),
    );
  }

  /// The logs for the server hub, with a bug report's [screenshot] and [note] when there are.
  Future<Uint8List> reportArchive({Uint8List? screenshot, String? note}) async {
    await _flush();
    final (_, internalName) = _logExportName();
    return zipReport(internalName, await getFullLogs(), screenshot, note);
  }

  /// Up to 20 MB of logs: compressed away from the screen, which would otherwise stall.
  @visibleForTesting
  static Future<Uint8List> zipReport(String name, String logs, Uint8List? screenshot, String? note) => Isolate.run(() {
    final archive = Archive()..add(ArchiveFile.bytes(name, utf8.encode(logs)));
    if (screenshot != null) archive.add(ArchiveFile.bytes("screenshot.png", screenshot));
    if (note != null && note.trim().isNotEmpty) archive.add(ArchiveFile.bytes("note.txt", utf8.encode(note.trim())));
    return ZipEncoder().encodeBytes(archive, level: DeflateLevel.defaultCompression);
  });

  @visibleForTesting
  Future<void> flush() => _flush();

  /// Writes what's buffered to the file, so it can be read whole. Lines logged meanwhile follow afterwards.
  Future<void> _flush() async {
    final writer = _logFileWriter;
    if (writer == null) return;
    for (var busy = _flushing; busy != null; busy = _flushing) {
      await busy;
    }
    final flushing = writer.flush().catchError((_) {});
    _flushing = flushing;
    try {
      await flushing;
    } finally {
      _flushing = null;
      _held.forEach(writer.writeln);
      _held.clear();
    }
  }

  Future<Uint8List> _getLogsArchive(String name) async {
    final logBytes = utf8.encode(await getFullLogs());
    final archive = Archive();
    archive.add(ArchiveFile.bytes(name, logBytes));
    return ZipEncoder().encodeBytes(archive, level: DeflateLevel.defaultCompression);
  }

  (String, String) _logExportName() {
    final baseName = "finamp-logs-${DateTime.now().toIso8601String().replaceAll(RegExp(r'[/?<>:*|.\\"]'), "-")}";
    return ("$baseName.zip", "$baseName.txt");
  }
}
