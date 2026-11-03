import 'dart:io';

import 'package:finamp/services/ai_service.dart';
import 'package:finamp/services/dj_audio_import.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel("com.unicornsonlsd.finamp/dj_voice");
  final wav = AiService.wav(Uint8List(4800), sampleRate: 24000);
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null),
  );

  test('a WAV is told apart from an MP3 by what it holds, not its name', () {
    expect(DjAudioImport.isWav(wav), isTrue);
    expect(DjAudioImport.isWav([0x49, 0x44, 0x33, 4, 0, 0, 0, 0, 0, 0, 0, 0]), isFalse, reason: 'an MP3 with tags');
    expect(DjAudioImport.isWav([1, 2]), isFalse);
  });

  test("an MP3 comes back as the phone's WAV of it; one the phone can't read is turned down", () async {
    MethodCall? asked;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      asked = call;
      final output = call.arguments['output'] as String;
      await File(output).writeAsBytes(wav);
      return output;
    });
    expect(await DjAudioImport.decode('/picked/chime.mp3', 'Unreadable'), wav);
    expect(asked!.method, 'decodeAudio');
    expect(asked!.arguments['input'], '/picked/chime.mp3');
    expect(asked!.arguments['maxSeconds'], 12);
    expect(File(asked!.arguments['output'] as String).existsSync(), isFalse, reason: 'its copy is cleaned up');

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (_) async => throw PlatformException(code: 'decode'),
    );
    await expectLater(
      DjAudioImport.decode('/picked/broken.mp3', 'Unreadable'),
      throwsA(isA<FormatException>().having((e) => e.message, 'message', 'Unreadable')),
    );
  });
}
