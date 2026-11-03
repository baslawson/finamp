import 'dart:math';
import 'dart:typed_data';

import 'package:finamp/services/ai_service.dart';
import 'package:finamp/services/dj_voice_service.dart';
import 'package:flutter_test/flutter_test.dart';

const rate = 24000;

List<int> pcm(double amplitude, {int count = rate}) {
  final data = ByteData(count * 2);
  for (var i = 0; i < count; i++) {
    data.setInt16(i * 2, (amplitude * 32767 * sin(2 * pi * 160 * i / rate)).round(), Endian.little);
  }
  return data.buffer.asUint8List();
}

List<double> samples(List<int> wav) {
  final data = ByteData.sublistView(Uint8List.fromList(wav), 44);
  return [for (var i = 0; i < data.lengthInBytes ~/ 2; i++) data.getInt16(i * 2, Endian.little) / 32768];
}

double rms(Iterable<double> samples) {
  final values = samples.toList();
  return sqrt(values.fold(0.0, (sum, value) => sum + value * value) / values.length);
}

void main() {
  test('disabling the boost lowers the final balanced voice level without changing its length', () {
    final file = AiService.wav(pcm(0.2), sampleRate: rate);
    final on = AiService.balanceSpeechWav(file);
    final off = AiService.balanceSpeechWav(file, boost: false);
    expect(rms(samples(on)) / rms(samples(off)), closeTo(1.25, 0.001));
    expect(off.length, on.length);
  });
  test('soft and loud characters reach a consistent active speech level', () {
    final soft = AiService.balanceSpeechWav(AiService.wav(pcm(0.1), sampleRate: rate));
    final loud = AiService.balanceSpeechWav(AiService.wav(pcm(0.6), sampleRate: rate));
    expect(rms(samples(soft)), closeTo(rms(samples(loud)), 0.001));
    expect(rms(samples(soft)), closeTo(0.18, 0.001));
  });

  test('dramatic pauses and Bluetooth padding do not increase the voice level', () {
    final speech = pcm(0.15);
    final pause = List.filled(rate, 0);
    final plain = AiService.balanceSpeechWav(AiService.wav(speech, sampleRate: rate));
    final spaced = AiService.balanceSpeechWav(AiService.wav([...pause, ...speech, ...pause], sampleRate: rate));
    expect(samples(spaced).skip(rate ~/ 2).take(rate), samples(plain));
    expect(spaced.length, 44 + speech.length + pause.length * 2);
    expect(samples(spaced).take(rate ~/ 2).every((sample) => sample == 0), isTrue);
    expect(samples(spaced).skip(rate * 3 ~/ 2).every((sample) => sample == 0), isTrue);
  });

  test('a quiet final word keeps its position, relative volume and complete tail', () {
    final body = pcm(0.3);
    final pause = List.filled(rate ~/ 2, 0);
    final finalWord = pcm(0.012, count: rate ~/ 3);
    final padding = List.filled(rate, 0);
    final original = AiService.wav([...body, ...pause, ...finalWord, ...padding], sampleRate: rate);
    final balanced = AiService.balanceSpeechWav(original);
    expect(DjVoiceService.wavDuration(balanced), DjVoiceService.wavDuration(original));
    final result = samples(balanced);
    final ending = result.skip(rate + pause.length ~/ 2).take(finalWord.length ~/ 2);
    expect(rms(ending) / rms(result.take(rate)), closeTo(0.012 / 0.3, 0.001));
    expect(ending.where((sample) => sample != 0).length, greaterThan(rate ~/ 4));
    expect(result.skip(result.length - padding.length ~/ 2).every((sample) => sample == 0), isTrue);
  });

  test('amplification is bounded and peaks retain headroom', () {
    final verySoft = samples(AiService.balanceSpeechWav(AiService.wav(pcm(0.01), sampleRate: rate)));
    expect(verySoft.map((sample) => sample.abs()).reduce(max), lessThanOrEqualTo(0.0401));
    final spiky = pcm(0.1);
    spiky[1000] = 0xff;
    spiky[1001] = 0x7f;
    final balanced = samples(AiService.balanceSpeechWav(AiService.wav(spiky, sampleRate: rate)));
    expect(balanced.map((sample) => sample.abs()).reduce(max), lessThanOrEqualTo(0.9501));
  });

  test('silence, near-silence and unsupported files are left alone', () {
    for (final amplitude in [0.0, 0.001]) {
      final file = AiService.wav(pcm(amplitude), sampleRate: rate);
      expect(AiService.balanceSpeechWav(file), file);
    }
    expect(AiService.balanceSpeechWav([1, 2, 3]), [1, 2, 3]);
    final stereo = AiService.wav(pcm(0.2), sampleRate: rate)..[22] = 2;
    expect(AiService.balanceSpeechWav(stereo), stereo);
  });
}
