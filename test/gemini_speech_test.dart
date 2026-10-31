import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:finamp/services/ai_service.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _audio(List<int> bytes, {String mime = "audio/L16;codec=pcm;rate=24000"}) => {
  "inlineData": {"mimeType": mime, "data": base64Encode(bytes)},
};

Map<String, dynamic> _response(List<Map<String, dynamic>> parts, {String reason = "STOP"}) => {
  "candidates": [
    {
      "finishReason": reason,
      "content": {"parts": parts},
    },
  ],
};

List<int> _tone(int count, {int rate = 24000}) {
  final bytes = ByteData(count * 2);
  for (var i = 0; i < count; i++) {
    bytes.setInt16(i * 2, (3000 * sin(2 * pi * 140 * i / rate)).round(), Endian.little);
  }
  return bytes.buffer.asUint8List();
}

void main() {
  test('English language control reaches current and older Gemini TTS requests without changing the transcript', () {
    const line = 'Next one: In the Closet, from Michael Jackson.';
    for (final model in [
      'models/gemini-3.8-flash-tts',
      'models/gemini-3.1-flash-tts-preview',
      'models/gemini-2.5-pro-preview-tts',
    ]) {
      final request = AiService.geminiSpeechRequest(
        model,
        line,
        style: 'Read in English.',
        voice: 'Fenrir',
        languageCode: 'en-AU',
      );
      final config = request['generationConfig'] as Map<String, dynamic>;
      expect((config['speechConfig'] as Map<String, dynamic>)['languageCode'], 'en-AU');
      final text = (request['contents'] as List).single['parts'][0]['text'] as String;
      expect(text, endsWith(line));
    }
  });

  test("Gemini 3.8 receives only the transcript as text, and requests raw PCM", () {
    final request = AiService.geminiSpeechRequest(
      "models/gemini-3.8-flash-tts",
      "Up next, Queen.",
      style: "Warm and upbeat.",
      voice: "Puck",
    );
    final contents = request["contents"] as List<dynamic>;
    final parts = (contents.single as Map<String, dynamic>)["parts"] as List<dynamic>;
    expect(parts.single, {
      "text": "Up next, Queen.",
      "speechMetadata": {"style": "Warm and upbeat."},
    });
    final config = request["generationConfig"] as Map<String, dynamic>;
    expect(config["responseFormat"], {
      "audio": {"mimeType": "AUDIO_L16", "sampleRate": 24000},
    });
    expect(config["speechConfig"], {
      "voiceConfig": {
        "prebuiltVoiceConfig": {"voiceName": "Puck"},
      },
    });
  });

  test("older preview models keep their supported prompt and response format", () {
    for (final model in ["models/gemini-2.5-pro-preview-tts", "models/gemini-3.1-flash-tts-preview"]) {
      final request = AiService.geminiSpeechRequest(model, "Up next, Queen.", style: "Warm.", voice: "Fenrir");
      final contents = request["contents"] as List<dynamic>;
      final parts = (contents.single as Map<String, dynamic>)["parts"] as List<dynamic>;
      final part = parts.single as Map<String, dynamic>;
      expect(part["text"], endsWith("#### TRANSCRIPT\nUp next, Queen."));
      expect(part.containsKey("speechMetadata"), isFalse);
      expect((request["generationConfig"] as Map<String, dynamic>).containsKey("responseFormat"), isFalse);
    }
  });

  test("all audio parts are kept in order, including the part with the last word", () {
    final first = _tone(24000);
    final last = _tone(12000);
    final result = AiService.geminiSpeechAudio(
      _response([
        {"text": "Not audio"},
        {..._audio(_tone(2400)), "thought": true},
        _audio(first),
        _audio([1, 2], mime: "image/png"),
        _audio(last),
      ]),
    );
    expect(result.sampleRate, 24000);
    expect(result.pcm.length, first.length + last.length + 24000);
    // After the join, the second part is still at its original sample position.
    final samples = ByteData.sublistView(Uint8List.fromList(result.pcm));
    final original = ByteData.sublistView(Uint8List.fromList(last));
    expect(
      samples.getInt16(first.length + 2402, Endian.little),
      closeTo(original.getInt16(2402, Endian.little) * 1.25, 2),
    );
    expect(result.pcm.sublist(first.length + last.length).every((byte) => byte == 0), isTrue);
  });

  test("Gemini preserves a quiet final word after a pause through decoding and cleanup", () {
    final first = _tone(24000);
    final pause = List.filled(9600, 0);
    final random = Random(7);
    final whisper = ByteData(19200);
    for (var i = 0; i < whisper.lengthInBytes; i += 2) {
      whisper.setInt16(i, random.nextInt(600) - 300, Endian.little);
    }
    final input = [...first, ...pause, ...whisper.buffer.asUint8List()];
    final result = AiService.geminiSpeechAudio(_response([_audio(input)]));
    expect(result.pcm.length, input.length + 24000);
    expect(result.pcm.sublist(first.length + pause.length, input.length - 1440).any((byte) => byte != 0), isTrue);
  });

  test("WAV response headers are decoded, including extra chunks and the actual sample rate", () {
    final pcm = _tone(16000, rate: 16000);
    final file = AiService.wav(pcm, sampleRate: 16000);
    // RIFF permits extra chunks, with odd sizes padded to an even byte boundary.
    final withMetadata = Uint8List.fromList([
      ...file.take(12),
      ...ascii.encode("JUNK"),
      3,
      0,
      0,
      0,
      1,
      2,
      3,
      0,
      ...file.skip(12),
    ]);
    ByteData.sublistView(withMetadata).setUint32(4, withMetadata.length - 8, Endian.little);
    final result = AiService.geminiSpeechAudio(_response([_audio(withMetadata, mime: "audio/wav")]));
    expect(result.sampleRate, 16000);
    expect(result.pcm.length, pcm.length + 16000);
    // No RIFF header has become speech samples or a second WAV wrapper.
    final decoded = ByteData.sublistView(Uint8List.fromList(result.pcm));
    final original = ByteData.sublistView(Uint8List.fromList(pcm));
    expect(decoded.getInt16(4002, Endian.little), closeTo(original.getInt16(4002, Endian.little) * 1.25, 2));
  });

  test("incomplete generations and truncated audio aren't played", () {
    expect(
      () => AiService.geminiSpeechAudio(_response([_audio(_tone(24000))], reason: "MAX_TOKENS")),
      throwsA(isA<AiException>().having((e) => e.message, "message", contains("incomplete speech"))),
    );
    final truncated = AiService.wav(_tone(24000), sampleRate: 24000)..removeLast();
    for (final part in [
      _audio(truncated, mime: "audio/wav"),
      _audio([1, 2, 3]),
      _audio([1, 2], mime: "audio/mpeg"),
    ]) {
      expect(() => AiService.geminiSpeechAudio(_response([part])), throwsA(isA<AiException>()));
    }
    expect(() => AiService.geminiSpeechAudio(_response([])), throwsA(isA<AiException>()));
  });

  test("audio parts with different sample rates aren't joined at the wrong speed", () {
    expect(
      () => AiService.geminiSpeechAudio(
        _response([_audio(_tone(24000)), _audio(_tone(16000, rate: 16000), mime: "audio/l16;rate=16000")]),
      ),
      throwsA(isA<AiException>()),
    );
  });

  test("model discovery includes current and older preview TTS names", () {
    expect(
      AiService.speechModelOrder([
        "models/gemini-3.8-flash-lite-tts",
        "models/gemini-2.5-pro-preview-tts",
        "models/gemini-3.1-flash-tts-preview",
        "models/gemini-3.8-flash-tts",
        "models/gemini-3.8-flash",
      ]),
      [
        "models/gemini-3.8-flash-tts",
        "models/gemini-3.8-flash-lite-tts",
        "models/gemini-3.1-flash-tts-preview",
        "models/gemini-2.5-pro-preview-tts",
      ],
    );
  });
}
