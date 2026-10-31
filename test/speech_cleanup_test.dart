import 'dart:math';
import 'dart:typed_data';

import 'package:finamp/services/ai_service.dart';
import 'package:finamp/services/dj_voice_service.dart';
import 'package:flutter_test/flutter_test.dart';

List<int> _pcm(List<double> samples) {
  final data = ByteData(samples.length * 2);
  for (final (i, sample) in samples.indexed) {
    data.setInt16(i * 2, (sample * 32767).round(), Endian.little);
  }
  return data.buffer.asUint8List();
}

List<double> _samples(List<int> pcm) {
  final data = ByteData.sublistView(Uint8List.fromList(pcm));
  return [for (var i = 0; i < pcm.length ~/ 2; i++) data.getInt16(i * 2, Endian.little) / 32768];
}

void main() {
  const rate = 24000;
  final endPause = rate * AiService.endPause.inMilliseconds ~/ 1000;
  // What is kept, faded out, after where the words seem to end.
  final tail = rate * AiService.tail.inMilliseconds ~/ 1000;
  final random = Random(1);
  // A voice-like sound: a 140 Hz tone with its harmonics, like vocal cords. One second of it, then a second of static.
  double voiced(int i) =>
      0.3 * [for (var h = 1; h <= 25; h++) sin(2 * pi * h * 140 * i / rate) / h].reduce((a, b) => a + b);
  final voice = [for (var i = 0; i < rate; i++) voiced(i)];
  final hiss = [for (var i = 0; i < rate; i++) (random.nextDouble() - 0.5) * 0.6];
  // Muffled static, like a badly tuned radio: white noise through a low-pass filter.
  List<double> muffled(double level) {
    var state = 0.0;
    return [for (final sample in hiss) state += 0.25 * (sample * level - state)];
  }

  test("trailing static is cut, the end fades into a short silence", () {
    final cleaned = _samples(AiService.cleanSpeech(_pcm([...voice, ...hiss]), sampleRate: rate));
    // Voice, a faded moment of static and the silence after it; well under the 2 s it came in with.
    expect(cleaned.length, lessThanOrEqualTo(rate + rate * 20 ~/ 1000 + tail + endPause));
    expect(cleaned.length, greaterThan(rate));
    expect(cleaned.sublist(cleaned.length - endPause).every((sample) => sample == 0), isTrue);
    expect(cleaned.first.abs(), lessThan(0.01)); // faded in
  });

  test("clean speech keeps its length (plus the pause)", () {
    final cleaned = AiService.cleanSpeech(_pcm(voice), sampleRate: rate);
    expect(cleaned.length ~/ 2, rate + endPause);
  });

  test("odd byte counts and silence don't break it", () {
    expect(AiService.cleanSpeech([1, 2, 3], sampleRate: rate).length.isEven, isTrue);
    expect(AiService.cleanSpeech(List.filled(4800, 0), sampleRate: rate), isEmpty);
  });

  test("whole WAV files are cleaned too, other formats are left alone", () {
    final file = AiService.wav(_pcm([...voice, ...hiss]), sampleRate: rate);
    final cleaned = AiService.cleanWav(file);
    expect(cleaned.length, lessThan(44 + rate * 2 * 1.8));
    expect(String.fromCharCodes(cleaned.sublist(0, 4)), "RIFF");

    final stereo = List<int>.of(file);
    stereo[22] = 2;
    expect(AiService.cleanWav(stereo), stereo);
    expect(AiService.cleanWav([1, 2, 3]), [1, 2, 3]);
  });

  test("static straight after the voice is cut off, not kept as a tail", () {
    final cleaned = AiService.cleanSpeech(_pcm([...voice, ...hiss]), sampleRate: rate).length ~/ 2;
    // At most one 20 ms window of static survives, then the faded tail.
    expect(cleaned, lessThanOrEqualTo(rate + rate * 20 ~/ 1000 + tail + endPause));
  });

  test("quieter static is cut too", () {
    final quiet = [for (final sample in hiss) sample * 0.3];
    final cleaned = AiService.cleanSpeech(_pcm([...voice, ...quiet]), sampleRate: rate).length ~/ 2;
    expect(cleaned, lessThanOrEqualTo(rate + rate * 20 ~/ 1000 + tail + endPause));
  });

  test("a word dying away is kept", () {
    final fading = [for (var i = 0; i < rate ~/ 10; i++) exp(-i / (rate * 0.02)) * voiced(rate + i)];
    final cleaned = AiService.cleanSpeech(_pcm([...voice, ...fading]), sampleRate: rate).length ~/ 2;
    expect(cleaned, greaterThanOrEqualTo(rate + rate * 60 ~/ 1000 + endPause));
  });

  test("spectral flatness tells a tone from noise", () {
    expect(AiService.spectralFlatness(voice, 0, 480), lessThan(0.2));
    expect(AiService.spectralFlatness(hiss, 0, 480), greaterThan(0.4));
    expect(AiService.harmonicFlatness(voice, 0, 960, sampleRate: rate), lessThan(0.2));
    expect(AiService.harmonicFlatness(muffled(1), 0, 960, sampleRate: rate), greaterThan(0.4));
  });

  /// How loud what's left after [from] is (root mean square).
  double loudnessAfter(List<double> samples, int from) {
    if (from >= samples.length) return 0;
    final rest = samples.sublist(from);
    return sqrt(rest.map((sample) => sample * sample).reduce((a, b) => a + b) / rest.length);
  }

  test("muffled static straight after the voice is cut", () {
    final cleaned = _samples(AiService.cleanSpeech(_pcm([...voice, ...muffled(1)]), sampleRate: rate));
    // A bare 60 ms may survive, then the faded tail; nothing after that.
    expect(cleaned.length, lessThanOrEqualTo(rate + rate * 60 ~/ 1000 + tail + endPause));
    expect(loudnessAfter(cleaned, rate + rate * 60 ~/ 1000 + tail), lessThan(0.001));
  });

  test("static after a pause is cut at the pause", () {
    final pause = List.filled(rate ~/ 4, 0.0);
    final cleaned = _samples(AiService.cleanSpeech(_pcm([...voice, ...pause, ...muffled(1)]), sampleRate: rate));
    expect(cleaned.length, lessThanOrEqualTo(rate + rate * 20 ~/ 1000 + tail + endPause));
    expect(loudnessAfter(cleaned, rate), lessThan(0.001));
    final hissing = _samples(AiService.cleanSpeech(_pcm([...voice, ...pause, ...hiss]), sampleRate: rate));
    expect(loudnessAfter(hissing, rate), lessThan(0.001));
  });

  test("a last word after a pause is kept", () {
    final pause = List.filled(rate ~/ 4, 0.0);
    final word = voice.sublist(0, rate ~/ 3);
    final cleaned = AiService.cleanSpeech(_pcm([...voice, ...pause, ...word]), sampleRate: rate).length ~/ 2;
    expect(cleaned, greaterThanOrEqualTo(rate + rate ~/ 4 + rate ~/ 3 - rate * 20 ~/ 1000));
  });

  test("a last consonant after a short hush is kept, but static after one isn't", () {
    final hush = List.filled(rate * 80 ~/ 1000, 0.0);
    final consonant = [for (final sample in hiss.take(rate * 150 ~/ 1000)) sample * 0.2]; // a soft "s"
    final word = AiService.cleanSpeech(_pcm([...voice, ...hush, ...consonant]), sampleRate: rate).length ~/ 2;
    expect(word, voice.length + hush.length + consonant.length + endPause);

    final static = _samples(AiService.cleanSpeech(_pcm([...voice, ...hush, ...hiss]), sampleRate: rate));
    expect(static.length, lessThanOrEqualTo(rate + rate * 20 ~/ 1000 + tail + endPause));
  });

  test("Gemini gets the style notes apart from the words to say", () {
    final prompt = AiService.geminiSpeechPrompt("Style: warm and upbeat.", "Up next, Queen.");
    expect(prompt, startsWith("### DIRECTOR'S NOTES\nStyle: warm and upbeat."));
    expect(prompt, endsWith("#### TRANSCRIPT\nUp next, Queen."));
  });

  test("a breathy last word after a pause is kept", () {
    // "... up next, Queen.": a pause, then a short word with some breath in it.
    final pause = List.filled(rate ~/ 5, 0.0);
    final breathy = [for (var i = 0; i < rate * 3 ~/ 10; i++) 0.8 * voiced(i) + 0.2 * hiss[i]];
    final cleaned = AiService.cleanSpeech(_pcm([...voice, ...pause, ...breathy]), sampleRate: rate).length ~/ 2;
    expect(cleaned, greaterThanOrEqualTo(rate + rate ~/ 5 + rate * 25 ~/ 100));
  });

  test("a last phrase full of hissing consonants after a pause is kept", () {
    // "... by Aerosmith.": vowels and "s"/"th" sounds take turns, so half of it sounds like noise.
    final pause = List.filled(rate ~/ 5, 0.0);
    final phrase = [
      for (var part = 0; part < 6; part++)
        for (var i = 0; i < rate ~/ 10; i++) part.isEven ? 0.8 * voiced(i) + 0.2 * hiss[i] : hiss[rate ~/ 2 + i] * 0.5,
    ];
    final cleaned = AiService.cleanSpeech(_pcm([...voice, ...pause, ...phrase]), sampleRate: rate).length ~/ 2;
    expect(cleaned, greaterThanOrEqualTo(rate + rate ~/ 5 + rate * 5 ~/ 10));
  });

  test("a last word the trimmer takes for noise still comes through, fading out", () {
    // The end of "Fire" or "Roses", long and breathy enough to pass for static: at least the tail is kept.
    final breath = [for (final sample in hiss.take(rate * 400 ~/ 1000)) sample * 0.5];
    final cleaned = _samples(AiService.cleanSpeech(_pcm([...voice, ...breath]), sampleRate: rate));
    expect(cleaned.length, greaterThanOrEqualTo(rate + tail + endPause));
    // Just after the voice it's still clearly there.
    expect(loudnessAfter(cleaned.sublist(0, rate + rate * 60 ~/ 1000), rate), greaterThan(0.05));
  });

  test("Gemini keeps a whole soft last word after a pause", () {
    final pause = List.filled(rate ~/ 5, 0.0);
    // A whispered ending has no harmonics for the noise detector to recognise.
    final ending = [for (final sample in hiss.take(rate * 400 ~/ 1000)) sample * 0.08];
    final input = [...voice, ...pause, ...ending];
    final cleaned = _samples(AiService.cleanSpeech(_pcm(input), sampleRate: rate, trimNoise: false));
    expect(cleaned.length, input.length + endPause);
    final nearEnd = input.length - rate * 80 ~/ 1000;
    expect(loudnessAfter(cleaned.sublist(0, nearEnd), nearEnd - rate * 40 ~/ 1000), greaterThan(0.01));
  });

  test("the end of the last word isn't faded away", () {
    final cleaned = _samples(AiService.cleanSpeech(_pcm(voice), sampleRate: rate));
    // 40 ms before the end the voice is still at full strength (with the boost); only the last 30 ms fade.
    final end = voice.length - rate * 40 ~/ 1000;
    expect(
      loudnessAfter(cleaned.sublist(0, end), end - rate * 20 ~/ 1000),
      closeTo(loudnessAfter(voice.sublist(0, end), end - rate * 20 ~/ 1000) * AiService.voiceBoost, 0.02),
    );
  });

  test("a WAV file says how long it plays", () {
    final file = AiService.wav(_pcm(voice), sampleRate: rate);
    expect(DjVoiceService.wavDuration(file), const Duration(seconds: 1));
    expect(DjVoiceService.wavDuration([1, 2, 3]), isNull);
  });

  test("the voice comes out 25% louder, without clipping", () {
    final quiet = [for (var i = 0; i < rate; i++) 0.5 * voiced(i)];
    final cleaned = _samples(AiService.cleanSpeech(_pcm(quiet), sampleRate: rate));
    double peak(List<double> samples) => samples.map((sample) => sample.abs()).reduce(max);
    expect(peak(cleaned) / peak(quiet), closeTo(1.25, 0.02));
    final loud = _samples(AiService.cleanSpeech(_pcm([for (final sample in voice) sample * 2]), sampleRate: rate));
    expect(peak(loud), lessThan(1.0));
  });

  test('turning boost off bypasses its soft limiter while retaining fades and end padding', () {
    final input = List<double>.filled(rate, .95);
    final cleaned = _samples(AiService.cleanSpeech(_pcm(input), sampleRate: rate, trimNoise: false, boost: false));
    expect(cleaned[rate ~/ 2], closeTo(.95, .0001));
    expect(cleaned.first.abs(), lessThan(.0001));
    expect(cleaned.length, rate + rate ~/ 2);
    expect(cleaned.skip(rate).every((value) => value == 0), isTrue);
  });

  test("spots a voice that read the line twice", () {
    const line = "Keeping that massive guitar energy rolling this morning. Here is Bush with their classic, Comedown.";
    // 16 words: about 5.5 s said normally, 8 s slowly, 10 s or more read twice.
    expect(AiService.tooLongFor(line, const Duration(milliseconds: 5500)), isFalse);
    expect(AiService.tooLongFor(line, const Duration(seconds: 8)), isFalse);
    expect(AiService.tooLongFor(line, const Duration(seconds: 10)), isTrue);
    // Takes from a user's log: normal, and two read twice.
    const favourites =
        "Still awake and craving some swagger? Let us kick off your favourites with Guns N' Roses tearing through "
        "Sympathy For The Devil. Axl and Slash give this classic a properly wicked edge.";
    expect(AiService.tooLongFor(favourites, const Duration(milliseconds: 10930)), isFalse);
    const novocaine = "Keep rolling with Bon Jovi's Novocaine, before Aerosmith slides in next, mate.";
    expect(AiService.tooLongFor(novocaine, const Duration(milliseconds: 10250)), isTrue);
    const kickOff =
        "Kicking off from your library with a massive anthem, here is Knockin' On Heaven's Door by Guns N' Roses. "
        "Slash's soaring lead guitar makes this legendary cover hit just right.";
    expect(AiService.tooLongFor(kickOff, const Duration(milliseconds: 19610)), isTrue);
  });

  test("speech models are tried flash first, newest first, then pro", () {
    expect(
      AiService.speechModelOrder([
        "models/gemini-2.5-pro-preview-tts",
        "models/gemini-3.8-flash",
        "models/gemini-2.5-flash-preview-tts",
        "models/gemini-3.8-flash-tts",
        "models/gemini-3.8-pro-tts",
        "models/gemini-3.8-flash-tts",
      ]),
      [
        "models/gemini-3.8-flash-tts",
        "models/gemini-2.5-flash-preview-tts",
        "models/gemini-3.8-pro-tts",
        "models/gemini-2.5-pro-preview-tts",
      ],
    );
  });
}
