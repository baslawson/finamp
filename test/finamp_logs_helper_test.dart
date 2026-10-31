import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'package:finamp/services/finamp_logs_helper.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.folder);
  final String folder;
  @override
  Future<String?> getApplicationSupportPath() async => folder;
  @override
  Future<String?> getApplicationDocumentsPath() async => folder;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test("lines logged while the file is flushed for an upload are kept, not thrown", () async {
    final folder = await Directory.systemTemp.createTemp("finamp-logs");
    // The log stays open (the helper never closes it), so Windows may refuse: the system cleans its temp folder.
    addTearDown(() => folder.delete(recursive: true).catchError((_) => folder));
    PathProviderPlatform.instance = _Paths(folder.path);
    final helper = FinampLogsHelper();
    await helper.openLog();
    LogRecord record(String message) => LogRecord(Level.INFO, message, "Test");
    helper.addLog(record("before"));
    final flushing = helper.flush();
    helper.addLog(record("during"));
    await flushing;
    helper.addLog(record("after"));
    await helper.flush();
    final text = await File("${folder.path}/finamp-logs.txt").readAsString();
    expect(text.indexOf("before"), lessThan(text.indexOf("during")));
    expect(text.indexOf("during"), lessThan(text.indexOf("after")));
  });

  test("a bug report zip holds the logs, screenshot and note", () async {
    final zip = await FinampLogsHelper.zipReport(
      "finamp-logs.txt",
      "the logged line",
      Uint8List.fromList([137, 80, 78, 71]),
      " It broke ",
    );
    final archive = ZipDecoder().decodeBytes(zip);
    final names = [for (final file in archive.files) file.name];
    expect(names, containsAll(["screenshot.png", "note.txt"]));
    expect(utf8.decode(archive.findFile("note.txt")!.content as List<int>), "It broke");
    final logs = archive.files.firstWhere((file) => file.name.endsWith(".txt") && file.name != "note.txt");
    expect(utf8.decode(logs.content as List<int>), contains("the logged line"));
  });
}
