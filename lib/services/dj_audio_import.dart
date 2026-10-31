import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:finamp/services/dj_show_audio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A recording the listener picks to import, as a station jingle or the news chime: a WAV, or on Android also an MP3,
/// M4A or AAC, which the phone decodes to a WAV.
class DjAudioImport {
  DjAudioImport._();

  static const _channel = MethodChannel("com.unicornsonlsd.finamp/dj_voice");

  static bool get _decodes => !kIsWeb && Platform.isAndroid;

  /// Lets the listener pick a recording and returns it as a WAV, or null when they cancel. Throws a [FormatException]
  /// with [formatMessage] when it's too big or can't be read.
  static Future<List<int>?> pick(String formatMessage) async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: _decodes ? ['wav', 'mp3', 'm4a', 'aac'] : ['wav'],
    );
    if (result == null || result.files.isEmpty) return null;
    final file = result.files.single;
    if (file.size > DjJingleStore.maxImport) throw FormatException(formatMessage);
    final List<int> bytes;
    if (file.bytes != null) {
      bytes = file.bytes!;
    } else if (file.path != null) {
      final source = File(file.path!);
      if (await source.length() > DjJingleStore.maxImport) throw FormatException(formatMessage);
      bytes = await source.readAsBytes();
    } else {
      throw FormatException(formatMessage);
    }
    if (isWav(bytes)) return bytes;
    if (!_decodes || file.path == null) throw FormatException(formatMessage);
    return decode(file.path!, formatMessage);
  }

  @visibleForTesting
  static bool isWav(List<int> bytes) =>
      bytes.length >= 12 &&
      String.fromCharCodes(bytes.sublist(0, 4)) == 'RIFF' &&
      String.fromCharCodes(bytes.sublist(8, 12)) == 'WAVE';

  /// The recording at [path] decoded by the phone, as a WAV.
  static Future<List<int>> decode(String path, String formatMessage) async {
    final temp = await Directory.systemTemp.createTemp('finamp-import-');
    try {
      final output = '${temp.path}/decoded.wav';
      try {
        await _channel.invokeMethod<String>('decodeAudio', {'input': path, 'output': output, 'maxSeconds': 12});
      } on PlatformException {
        throw FormatException(formatMessage);
      }
      return await File(output).readAsBytes();
    } finally {
      await temp.delete(recursive: true).catchError((_) => temp);
    }
  }
}
