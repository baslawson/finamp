import 'dart:io';
import 'dart:typed_data';

import 'package:finamp/services/ai_service.dart';
import 'package:finamp/services/dj_voice_service.dart';
import 'package:finamp/services/wav_duration.dart';
import 'package:flutter_test/flutter_test.dart';

class _CountedFile extends Fake implements File {
  _CountedFile(this.file);
  final File file;
  late _CountedReader reader;
  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) async =>
      reader = _CountedReader(await file.open(mode: mode));
}

class _CountedReader extends Fake implements RandomAccessFile {
  _CountedReader(this.input);
  final RandomAccessFile input;
  int bytesRead = 0;
  bool closed = false;
  @override
  Future<int> length() => input.length();
  @override
  Future<Uint8List> read(int bytes) async {
    final data = await input.read(bytes);
    bytesRead += data.length;
    return data;
  }

  @override
  Future<RandomAccessFile> setPosition(int position) async {
    await input.setPosition(position);
    return this;
  }

  @override
  Future<void> close() async {
    await input.close();
    closed = true;
  }
}

void main() {
  late Directory folder;
  late File file;
  setUp(() async {
    folder = await Directory.systemTemp.createTemp('finamp-wav-duration-');
    file = File('${folder.path}/voice.wav');
  });
  tearDown(() => folder.delete(recursive: true));

  for (final (rate, channels) in [(24000, 1), (48000, 2)]) {
    test('a 45-second $rate Hz $channels-channel clip reads only 40 bytes', () async {
      final bytes = Uint8List.fromList(AiService.wav(Uint8List(rate * channels * 2 * 45), sampleRate: rate));
      final header = ByteData.sublistView(bytes);
      header.setUint16(22, channels, Endian.little);
      header.setUint32(28, rate * channels * 2, Endian.little);
      header.setUint16(32, channels * 2, Endian.little);
      await file.writeAsBytes(bytes);
      final counted = _CountedFile(file);
      expect(await wavFileDuration(counted), const Duration(seconds: 45));
      expect(await wavFileDuration(file), DjVoiceService.wavDuration(bytes));
      expect(counted.reader.bytesRead, 40);
      expect(counted.reader.closed, isTrue);
    });
  }

  test('large odd-sized metadata is skipped without reading it or the audio', () async {
    final original = AiService.wav(Uint8List(48000), sampleRate: 24000);
    final junk = Uint8List(8 + 100001 + 1);
    junk.setRange(0, 4, 'JUNK'.codeUnits);
    ByteData.sublistView(junk).setUint32(4, 100001, Endian.little);
    final bytes = Uint8List.fromList([...original.take(12), ...junk, ...original.skip(12)]);
    ByteData.sublistView(bytes).setUint32(4, bytes.length - 8, Endian.little);
    await file.writeAsBytes(bytes);
    final counted = _CountedFile(file);
    expect(await wavFileDuration(counted), const Duration(seconds: 1));
    expect(counted.reader.bytesRead, 48);
    expect(counted.reader.closed, isTrue);
  });

  test('a truncated data payload uses the actual available audio length', () async {
    final bytes = Uint8List.fromList(AiService.wav(Uint8List(48000), sampleRate: 24000));
    ByteData.sublistView(bytes).setUint32(40, 48000 * 3, Endian.little);
    await file.writeAsBytes(bytes);
    expect(await wavFileDuration(file), const Duration(seconds: 1));
    expect(await wavFileDuration(file), DjVoiceService.wavDuration(bytes));
  });

  test('unsupported or malformed headers return null and always close the file', () async {
    final valid = Uint8List.fromList(AiService.wav(Uint8List(480), sampleRate: 24000));
    final wrongType = Uint8List.fromList(valid)..setRange(8, 12, 'AVI '.codeUnits);
    final shortFormat = Uint8List.fromList(valid);
    ByteData.sublistView(shortFormat).setUint32(16, 4, Endian.little);
    final zeroRate = Uint8List.fromList(valid);
    ByteData.sublistView(zeroRate).setUint32(28, 0, Endian.little);
    final noFormat = Uint8List.fromList(valid)..setRange(12, 16, 'JUNK'.codeUnits);
    final noData = Uint8List.fromList(valid)..setRange(36, 40, 'JUNK'.codeUnits);
    for (final bytes in [Uint8List(10), wrongType, shortFormat, zeroRate, noFormat, noData]) {
      await file.writeAsBytes(bytes);
      final counted = _CountedFile(file);
      expect(await wavFileDuration(counted), isNull);
      expect(counted.reader.closed, isTrue);
    }
  });
}
