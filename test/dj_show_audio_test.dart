import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:finamp/services/ai_service.dart';
import 'package:finamp/services/dj_news_sting.dart';
import 'package:finamp/services/dj_show_audio.dart';
import 'package:finamp/services/dj_voice_preferences.dart';
import 'package:finamp/services/dj_voice_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

List<int> tone(int sample, {int rate = 24000, int seconds = 1}) {
  final pcm = ByteData(rate * seconds * 2);
  for (var i = 0; i < pcm.lengthInBytes ~/ 2; i++) {
    pcm.setInt16(i * 2, sample, Endian.little);
  }
  return AiService.wav(pcm.buffer.asUint8List(), sampleRate: rate);
}

/// A 24 kHz WAV [seconds] long whose every sample, [seconds] in, is [level] of it.
List<int> shaped(double seconds, int Function(double at) level) {
  final frames = (24000 * seconds).round(), pcm = ByteData(frames * 2);
  for (var i = 0; i < frames; i++) {
    pcm.setInt16(i * 2, level(i / 24000), Endian.little);
  }
  return AiService.wav(pcm.buffer.asUint8List(), sampleRate: 24000);
}

/// A WAV as editors save one: 24-bit or 32-bit float in an extensible header, [frames] of it, each channel's sample
/// from [sample] on a -1 to 1 scale.
List<int> editorWav({
  required int rate,
  required int channels,
  required bool float,
  required int frames,
  required double Function(int frame, int channel) sample,
}) {
  final width = float ? 4 : 3, data = frames * channels * width;
  final bytes = ByteData(68 + data);
  void tag(int at, String text) {
    for (var i = 0; i < 4; i++) {
      bytes.setUint8(at + i, text.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  bytes.setUint32(4, 60 + data, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  bytes.setUint32(16, 40, Endian.little);
  bytes.setUint16(20, 0xFFFE, Endian.little);
  bytes.setUint16(22, channels, Endian.little);
  bytes.setUint32(24, rate, Endian.little);
  bytes.setUint32(28, rate * channels * width, Endian.little);
  bytes.setUint16(32, channels * width, Endian.little);
  bytes.setUint16(34, width * 8, Endian.little);
  bytes.setUint16(36, 22, Endian.little);
  bytes.setUint16(38, width * 8, Endian.little);
  bytes.setUint16(44, float ? 3 : 1, Endian.little);
  tag(60, 'data');
  bytes.setUint32(64, data, Endian.little);
  for (var frame = 0; frame < frames; frame++) {
    for (var channel = 0; channel < channels; channel++) {
      final at = 68 + (frame * channels + channel) * width, value = sample(frame, channel);
      if (float) {
        bytes.setFloat32(at, value, Endian.little);
      } else {
        final int24 = (value * 8388607).round() & 0xFFFFFF;
        bytes.setUint8(at, int24 & 0xFF);
        bytes.setUint8(at + 1, int24 >> 8 & 0xFF);
        bytes.setUint8(at + 2, int24 >> 16);
      }
    }
  }
  return bytes.buffer.asUint8List();
}

/// A [Random] that gives these rolls in turn.
class _Rolls implements Random {
  _Rolls(this.rolls);
  final List<int> rolls;
  var _next = 0;
  @override
  int nextInt(int max) => rolls[_next++ % rolls.length];
  @override
  double nextDouble() => 0;
  @override
  bool nextBool() => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory folder;
  late PathProviderPlatform oldPaths;
  late SharedPreferencesAsyncPlatform? oldPrefs;
  setUp(() async {
    folder = await Directory.systemTemp.createTemp('finamp-show-test-');
    oldPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(folder.path);
    oldPrefs = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
  });
  tearDown(() async {
    PathProviderPlatform.instance = oldPaths;
    SharedPreferencesAsyncPlatform.instance = oldPrefs;
    await folder.delete(recursive: true);
  });
  test('composition preserves the full frame order with a fixed silent gap', () {
    final output = ByteData.sublistView(DjShowAudio.pcm(DjShowAudio.join([tone(1200), tone(-2300)])));
    expect(output.lengthInBytes, (24000 * 2 + 2880) * 2);
    for (var i = 0; i < output.lengthInBytes ~/ 2; i++) {
      expect(
        output.getInt16(i * 2, Endian.little),
        i < 24000
            ? 1200
            : i < 26880
            ? 0
            : -2300,
      );
    }
  });
  test('different provider sample rates become one mono 24 kHz clip without truncation', () {
    final pcm = ByteData.sublistView(DjShowAudio.pcm(DjShowAudio.join([tone(1100, rate: 8000), tone(2200)])));
    expect(pcm.lengthInBytes, (48000 + 2880) * 2);
    expect(pcm.getInt16(23999 * 2, Endian.little), 1100);
    expect(pcm.getInt16((26880 + 23999) * 2, Endian.little), 2200);
  });
  test('a 48 kHz 24-bit stereo WAV, as editors save one, becomes the 24 kHz mono clip', () {
    final wav = editorWav(
      rate: 48000,
      channels: 2,
      float: false,
      frames: 48000,
      sample: (frame, channel) => channel == 0 ? 0.25 : 0.5,
    );
    final pcm = ByteData.sublistView(DjShowAudio.pcm(wav));
    expect(pcm.lengthInBytes, 48000);
    expect(pcm.getInt16(12000 * 2, Endian.little), closeTo(32767 * 0.375, 2), reason: 'both channels, together');
  });
  test('32-bit float WAVs are read, and high sounds are smoothed away on the way down to 24 kHz', () {
    // The highest sound 48 kHz holds: every other sample up, then down. At 24 kHz it can't be heard, so it's gone.
    final wav = editorWav(
      rate: 48000,
      channels: 1,
      float: true,
      frames: 4800,
      sample: (frame, _) => 0.2 + (frame.isEven ? 0.5 : -0.5),
    );
    final pcm = ByteData.sublistView(DjShowAudio.pcm(wav));
    expect(pcm.lengthInBytes, 4800);
    for (var i = 0; i < 2400; i++) {
      expect(pcm.getInt16(i * 2, Endian.little), closeTo(32767 * 0.2, 2));
    }
  });
  test('a 44.1 kHz tone comes down to 24 kHz as that tone, with no wobble added', () {
    final source = ByteData(44100 * 2);
    for (var i = 0; i < 44100; i++) {
      source.setInt16(i * 2, (sin(2 * pi * 5000 * i / 44100) * 16000).round(), Endian.little);
    }
    final pcm = ByteData.sublistView(DjShowAudio.pcm(AiService.wav(source.buffer.asUint8List(), sampleRate: 44100)));
    final count = pcm.lengthInBytes ~/ 2;
    expect(count, 24000);
    // The tone the result holds, and what's left of it besides.
    var a = 0.0, b = 0.0;
    for (var i = 0; i < count; i++) {
      final y = pcm.getInt16(i * 2, Endian.little);
      a += y * sin(2 * pi * 5000 * i / 24000) * 2 / count;
      b += y * cos(2 * pi * 5000 * i / 24000) * 2 / count;
    }
    var rest = 0.0;
    for (var i = 0; i < count; i++) {
      final t = 2 * pi * 5000 * i / 24000;
      rest += pow(pcm.getInt16(i * 2, Endian.little) - a * sin(t) - b * cos(t), 2);
    }
    final amplitude = sqrt(a * a + b * b);
    expect(amplitude, greaterThan(16000 * 0.8), reason: 'the tone is still there');
    expect(sqrt(rest / count) / (amplitude / sqrt2), lessThan(0.03), reason: 'and little else');
  });
  test('malformed, truncated and overlong WAVs are rejected before playback', () {
    expect(() => DjShowAudio.pcm([1, 2]), throwsFormatException);
    expect(() => DjShowAudio.pcm(tone(1).sublist(0, 70)), throwsFormatException);
    expect(() => DjShowAudio.join([tone(1, seconds: 23), tone(2, seconds: 23)]), throwsFormatException);
    expect(() => DjShowAudio.pcm(tone(1, seconds: 13), maxSeconds: 12), throwsFormatException);
  });
  test('stereo jingles downmix safely and get short click-free edges', () {
    final data = ByteData(24000 * 4);
    for (var i = 0; i < 24000; i++) {
      data.setInt16(i * 4, 1000, Endian.little);
      data.setInt16(i * 4 + 2, 3000, Endian.little);
    }
    final wav = Uint8List.fromList(AiService.wav(data.buffer.asUint8List(), sampleRate: 24000));
    final header = ByteData.sublistView(wav);
    header.setUint16(22, 2, Endian.little);
    header.setUint16(32, 4, Endian.little);
    header.setUint32(28, 96000, Endian.little);
    final result = ByteData.sublistView(DjShowAudio.pcm(DjShowAudio.jingle(wav)));
    expect(result.lengthInBytes, 48000);
    expect(result.getInt16(0, Endian.little), 0);
    expect(result.getInt16(24000, Endian.little), 2000);
    expect(result.getInt16(47998, Endian.little), 0);
  });
  Future<File> recording(DjShowTurn turn) => File(
    '${folder.path}/${turn.character.name}.wav',
  ).writeAsBytes(tone(turn.character == DjVoiceCharacter.aussieMale ? 1100 : 2200));
  const main = DjShowTurn(DjVoiceCharacter.aussieMale, 'Here is the next song.'),
      reply = DjShowTurn(DjVoiceCharacter.chill, 'Great choice.');
  test('a complete two-host jingle clip is ready before playback and releases component files', () async {
    final clip = await DjShowBuilder.prepare(
      main: main,
      reply: reply,
      jingle: tone(-1000),
      record: recording,
      wanted: () => true,
    );
    expect(clip!.text, '${main.text}\n${reply.text}');
    final audio = ByteData.sublistView(DjShowAudio.pcm(await clip.file.readAsBytes()));
    expect(audio.getInt16(0, Endian.little), -1000);
    expect(audio.getInt16(26880 * 2, Endian.little), 1100);
    expect(audio.getInt16(53760 * 2, Endian.little), 2200);
    expect(path.normalize((await folder.list().toList()).single.path), path.normalize(clip.file.path));
  });
  test('in a live show, the news chime follows the jingle and the words start after both', () async {
    final jingle = tone(-1000);
    final opening = await DjShowAudio.joinAsync([jingle, DjNewsSting.wav]);
    final clip = await DjShowBuilder.prepare(main: main, jingle: opening, record: recording, wanted: () => true);
    expect(clip!.lead, DjShowAudio.startAfter(opening));
    expect(clip.lead, greaterThan(DjShowAudio.startAfter(jingle) + const Duration(milliseconds: 900)));
    final audio = ByteData.sublistView(DjShowAudio.pcm(await clip.file.readAsBytes()));
    expect(audio.getInt16(0, Endian.little), -1000, reason: 'the jingle first');
    final words = clip.lead.inMicroseconds * DjShowAudio.sampleRate ~/ 1000000;
    expect(audio.getInt16(words * 2, Endian.little), 1100, reason: 'then the host, after the chime');
  });

  test('a failed co-host keeps the original host recording and transcript', () async {
    final clip = await DjShowBuilder.prepare(
      main: main,
      reply: reply,
      wanted: () => true,
      record: (turn) async {
        if (turn == reply) throw StateError('API unavailable');
        return recording(turn);
      },
    );
    expect(clip!.text, main.text);
    expect(clip.file.path, endsWith('aussieMale.wav'));
    expect(await clip.file.readAsBytes(), tone(1100));
  });
  test('both hosts are recorded at the same time, the main host asked first', () async {
    final started = <DjShowTurn>[];
    var finishedMain = false;
    final clip = await DjShowBuilder.prepare(
      main: main,
      reply: reply,
      wanted: () => true,
      record: (turn) async {
        started.add(turn);
        if (turn == reply) expect(finishedMain, isFalse, reason: 'the co-host did not wait for the main host');
        final file = await recording(turn);
        if (turn == main) finishedMain = true;
        return file;
      },
    );
    expect(started, [main, reply]);
    expect(clip!.text, '${main.text}\n${reply.text}');
  });
  test('a failed main host also removes the co-host recorded alongside it', () async {
    final clip = await DjShowBuilder.prepare(
      main: main,
      reply: reply,
      wanted: () => true,
      record: (turn) async {
        if (turn == main) return null;
        return recording(turn);
      },
    );
    expect(clip, isNull);
    expect(await folder.list().toList(), isEmpty);
  });
  test('a corrupt jingle cannot suppress a successful main announcement', () async {
    final clip = await DjShowBuilder.prepare(main: main, jingle: [0, 1, 2], record: recording, wanted: () => true);
    expect(clip!.file.path, endsWith('aussieMale.wav'));
  });
  test('cancellation during the second recording releases every temporary file', () async {
    var wanted = true;
    final clip = await DjShowBuilder.prepare(
      main: main,
      reply: reply,
      wanted: () => wanted,
      record: (turn) async {
        final file = await recording(turn);
        if (turn == reply) wanted = false;
        return file;
      },
    );
    expect(clip, isNull);
    expect(await folder.list().toList(), isEmpty);
  });
  test('jingles persist per account and reject arbitrary paths or overlong imports', () async {
    await expectLater(
      DjJingleStore.save(Uint8List(DjJingleStore.maxImport + 1), scope: 'account-a'),
      throwsFormatException,
    );
    final id = await DjJingleStore.save(tone(1200), scope: 'account-a');
    expect(await DjJingleStore.read(id, scope: 'account-a'), isNotNull);
    expect(await DjJingleStore.read(id, scope: 'account-b'), isNull);
    expect(await DjJingleStore.read('../not-a-jingle', scope: 'account-a'), isNull);
    await expectLater(DjJingleStore.save(tone(1, seconds: 13), scope: 'account-a'), throwsFormatException);
    await DjJingleStore.remove(id, scope: 'account-a');
    expect(await DjJingleStore.read(id, scope: 'account-a'), isNull);
  });
  test('a secondary jingle takes turns with the primary one, and is saved with it', () {
    const both = DjShowSettings(jingleId: 'a', jingle2Id: 'b', jingle2Chance: 30);
    expect(both.jingleFor(0), 'b');
    expect(both.jingleFor(29), 'b');
    expect(both.jingleFor(30), 'a');
    expect(both.jingleFor(99), 'a');
    expect(const DjShowSettings(jingleId: 'a').jingleFor(0), 'a', reason: 'no secondary');
    expect(const DjShowSettings(jingle2Id: 'b').jingleFor(99), 'b', reason: 'only a secondary');
    expect(const DjShowSettings().hasJingle, isFalse);
    final back = DjShowSettings.fromJson(both.copyWith(jingle2Text: 'Finamp FM').toJson());
    expect((back.jingle2Id, back.jingle2Text, back.jingle2Chance), ('b', 'Finamp FM', 30));
    final sounds = DjShowSettings.fromJson(both.copyWith(jingleSound: 'podcast', jingle2Sound: 'news').toJson());
    expect((sounds.jingleSound, sounds.jingle2Sound), ('podcast', 'news'), reason: 'which of the sounds each one is');
    expect(DjShowSettings.fromJson(const {}).jingleSound, '');
    expect(DjShowSettings.fromJson(const {}).jingle2Chance, 30);
    expect(const DjVoiceProfile(show: DjShowSettings(jingle2Id: 'b')).toJson(), contains('show'));
    expect(
      const DjVoiceProfile(show: DjShowSettings(jingle2Text: 'Finamp FM')).toJson(),
      contains('show'),
      reason: 'the secondary words alone are kept',
    );
  });
  test("a secondary jingle stays while a station uses it", () async {
    final id = await DjJingleStore.save(tone(1200), scope: 'account-a');
    final profile = DjVoiceProfile(show: DjShowSettings(identityEnabled: true, jingle2Id: id));
    await DjVoicePreferences.saveStations('account-a', {'station-a': profile});
    await DjVoiceService.discardUnusedJingle(id, scope: 'account-a');
    expect(await DjJingleStore.read(id, scope: 'account-a'), isNotNull);
    await DjVoicePreferences.saveStations('account-a', {});
    await DjVoiceService.discardUnusedJingle(id, scope: 'account-a');
    expect(await DjJingleStore.read(id, scope: 'account-a'), isNull);
  });
  test('removing a jingle preserves references in other saved stations until the last one is removed', () async {
    final id = await DjJingleStore.save(tone(1200), scope: 'account-a');
    final profile = DjVoiceProfile(show: DjShowSettings(identityEnabled: true, jingleId: id));
    await DjVoicePreferences.saveStations('account-a', {'station-a': profile, 'station-b': profile});
    await DjVoiceService.discardUnusedJingle(id, scope: 'account-a');
    expect(await DjJingleStore.read(id, scope: 'account-a'), isNotNull);
    await DjVoicePreferences.saveStations('account-a', {'station-b': profile});
    await DjVoiceService.discardUnusedJingle(id, scope: 'account-a');
    expect(await DjJingleStore.read(id, scope: 'account-a'), isNotNull);
    await DjVoicePreferences.saveStations('account-a', {});
    await DjVoiceService.discardUnusedJingle(id, scope: 'account-a');
    expect(await DjJingleStore.read(id, scope: 'account-a'), isNull);
  });
  group('talking over a jingle', () {
    int at(ByteData audio, double seconds) => audio.getInt16((seconds * 24000).round() * 2, Endian.little);
    const rolls = [0.0, 0.2, 0.5, 0.8, 0.999];

    test('only a jingle of 3 seconds or more is talked over, never in its first second or last half second', () {
      expect(DjShowAudio.talkOverPoint(tone(8000, seconds: 2), 0.5), isNull);
      expect(DjShowAudio.talkOverPoint(DjNewsSting.wav, 0.5), isNull, reason: 'the bells are too short');
      expect(DjShowAudio.talkOverPoint(tone(0, seconds: 6), 0.5), isNull, reason: 'silence');
      for (final roll in rolls) {
        final point = DjShowAudio.talkOverPoint(tone(8000, seconds: 6), roll)!;
        expect(point, greaterThanOrEqualTo(const Duration(seconds: 1)));
        expect(point, lessThan(const Duration(milliseconds: 5500)));
      }
    });
    test('the voice comes in at a quieter moment of the jingle, before its sound dies away', () {
      final soft = shaped(6, (s) => s >= 2 && s < 3.5 ? 500 : 8000);
      for (final roll in rolls) {
        final point = DjShowAudio.talkOverPoint(soft, roll)!;
        expect(point.inMilliseconds, inInclusiveRange(2000, 3450), reason: 'roll $roll');
      }
      final fading = shaped(8, (s) => s < 4 ? 8000 : 0);
      for (final roll in rolls) {
        expect(
          DjShowAudio.talkOverPoint(fading, roll)!.inMilliseconds,
          inInclusiveRange(1000, 2950),
          reason: 'not in the silence after it',
        );
      }
      expect(
        {for (final roll in rolls) DjShowAudio.talkOverPoint(soft, roll)}.length,
        greaterThan(1),
        reason: 'not the same moment every time',
      );
    });
    test('the jingle dips under the voice and comes back up after it', () {
      final audio = ByteData.sublistView(
        DjShowAudio.pcm(
          DjShowAudio.overlay(tone(8000, seconds: 6), tone(1000, seconds: 2), at: const Duration(seconds: 3)),
        ),
      );
      expect(audio.lengthInBytes, 6 * 24000 * 2, reason: 'as long as the jingle');
      expect(at(audio, 2), 8000, reason: 'full volume before');
      expect(at(audio, 2.875), allOf(greaterThan(2000), lessThan(8000)), reason: 'dipping over the 250 ms before');
      expect(at(audio, 3.5), 8000 * 0.25 + 1000, reason: 'a quarter of its volume under the voice');
      expect(at(audio, 5.2), allOf(greaterThan(2000), lessThan(8000)), reason: 'coming back up');
      expect(at(audio, 5.5), 8000, reason: 'back up 400 ms after');
      final under = ByteData.sublistView(
        DjShowAudio.pcm(
          DjShowAudio.overlay(
            tone(8000, seconds: 6),
            tone(1000, seconds: 2),
            at: const Duration(seconds: 3),
            under: 0.5,
          ),
        ),
      );
      expect(at(under, 3.5), 5000, reason: 'the level chosen');
    });
    test('a voice longer than the jingle carries on alone, and the two together never clip', () {
      final long = ByteData.sublistView(
        DjShowAudio.pcm(
          DjShowAudio.overlay(tone(8000, seconds: 4), tone(1000, seconds: 5), at: const Duration(seconds: 2)),
        ),
      );
      expect(long.lengthInBytes, 7 * 24000 * 2);
      expect(at(long, 6.5), 1000, reason: 'the voice as it was');
      final loud = ByteData.sublistView(
        DjShowAudio.pcm(
          DjShowAudio.overlay(
            tone(30000, seconds: 4),
            tone(30000, seconds: 1),
            at: const Duration(seconds: 2),
            under: 1,
          ),
        ),
      );
      expect(at(loud, 2.5), allOf(greaterThan(30000), lessThanOrEqualTo(32767)), reason: 'eased, not wrapped round');
      expect(at(loud, 1), 30000, reason: 'the jingle alone untouched');
      expect(
        () => DjShowAudio.overlay(tone(8000, seconds: 6), tone(1000, seconds: 44), at: const Duration(seconds: 3)),
        throwsFormatException,
      );
    });
    test('a show reads the words over the jingle, starting where it dips', () async {
      final jingle = tone(-8000, seconds: 6);
      final clip = await DjShowBuilder.prepare(
        main: main,
        bed: (sound: jingle, roll: 0.5, under: 0.25),
        record: recording,
        wanted: () => true,
      );
      final point = DjShowAudio.talkOverPoint(jingle, 0.5)!;
      expect(clip!.lead, point);
      final audio = ByteData.sublistView(DjShowAudio.pcm(await clip.file.readAsBytes()));
      expect(audio.lengthInBytes, 6 * 24000 * 2, reason: 'the one-second words inside the jingle');
      expect(at(audio, 0.5), -8000);
      expect(at(audio, point.inMicroseconds / 1e6 + 0.5), -2000 + 1100);
      expect(path.normalize((await folder.list().toList()).single.path), path.normalize(clip.file.path));
    });
    test('the news is read over the chime after a jingle that plays in full', () async {
      final jingle = tone(-1000), chime = tone(-8000, seconds: 4);
      final clip = await DjShowBuilder.prepare(
        main: main,
        jingle: jingle,
        bed: (sound: chime, roll: 0, under: 0.25),
        record: recording,
        wanted: () => true,
      );
      expect(clip!.lead, DjShowAudio.startAfter(jingle) + DjShowAudio.talkOverPoint(chime, 0)!);
      final audio = ByteData.sublistView(DjShowAudio.pcm(await clip.file.readAsBytes()));
      expect(at(audio, 0.5), -1000, reason: 'the jingle first, at full volume');
      expect(at(audio, clip.lead.inMicroseconds / 1e6 + 0.5), -2000 + 1100);
    });
    test('one too short to talk over plays before the words, as before', () async {
      final clip = await DjShowBuilder.prepare(
        main: main,
        bed: (sound: DjNewsSting.wav, roll: 0.5, under: 0.25),
        record: recording,
        wanted: () => true,
      );
      expect(clip!.lead, DjShowAudio.startAfter(DjNewsSting.wav));
      final audio = ByteData.sublistView(DjShowAudio.pcm(await clip.file.readAsBytes()));
      expect(at(audio, clip.lead.inMicroseconds / 1e6 + 0.5), 1100, reason: 'the words alone');
      final broken = await DjShowBuilder.prepare(
        main: main,
        bed: (sound: [0, 1, 2], roll: 0.5, under: 0.25),
        record: recording,
        wanted: () => true,
      );
      expect(broken!.file.path, endsWith('aussieMale.wav'), reason: 'a damaged one is left out');
    });
    test('how often and how loud are saved with the station, and for the news', () async {
      const show = DjShowSettings();
      expect((show.talkOver, show.underVoice), (50, 25));
      final back = DjShowSettings.fromJson(show.copyWith(talkOver: 0, underVoice: 40).toJson());
      expect((back.talkOver, back.underVoice), (0, 40));
      expect(DjShowSettings.fromJson(const {'underVoice': 90}).underVoice, 50);
      expect(DjShowSettings.fromJson(const {'underVoice': 1}).underVoice, 5);
      expect(const DjVoiceProfile(show: DjShowSettings(talkOver: 80)).toJson(), contains('show'));
      expect(const DjVoiceProfile().toJson(), isNot(contains('show')));

      DjNewsSting.reset();
      expect(await DjNewsSting.talkOver(), (chance: 50, under: 25));
      await DjNewsSting.setTalkOver(chance: 70);
      await DjNewsSting.setTalkOver(under: 80);
      DjNewsSting.reset();
      expect(await DjNewsSting.talkOver(), (chance: 70, under: 50), reason: 'remembered, and no louder than half');
      DjNewsSting.reset();
    });
  });
  group('your own news chime', () {
    setUp(DjNewsSting.reset);
    tearDown(DjNewsSting.reset);
    test('is kept at the voice rate in place of the built-in one, until you go back to that', () async {
      expect(await DjNewsSting.isOwn(), isFalse);
      expect(await DjNewsSting.chime(), DjNewsSting.wav);
      final ten = editorWav(rate: 48000, channels: 2, float: false, frames: 480000, sample: (_, _) => 0.1);
      expect(ten.length, greaterThan(2 * 1024 * 1024), reason: 'bigger than jingles used to be allowed');
      await DjNewsSting.import(ten);
      expect(await DjNewsSting.isOwn(), isTrue);
      final own = ByteData.sublistView(DjShowAudio.pcm(await DjNewsSting.chime()));
      expect(own.lengthInBytes, 240000 * 2);
      expect(own.getInt16(120000 * 2, Endian.little), closeTo(3277, 2));
      DjNewsSting.reset();
      expect(await DjNewsSting.isOwn(), isTrue, reason: 'still there next time the app starts');
      await DjNewsSting.remove();
      expect(await DjNewsSting.chime(), DjNewsSting.wav);
      DjNewsSting.reset();
      expect(await DjNewsSting.isOwn(), isFalse);
    });
    test("too long, too big or not a WAV isn't taken, and the chime stays as it was", () async {
      await expectLater(DjNewsSting.import(tone(1, seconds: 13)), throwsFormatException);
      await expectLater(DjNewsSting.import(Uint8List(DjJingleStore.maxImport + 1)), throwsFormatException);
      await expectLater(DjNewsSting.import([1, 2, 3]), throwsFormatException);
      expect(await DjNewsSting.isOwn(), isFalse);
    });
    test('a damaged file left behind falls back to the built-in chime', () async {
      await File('${folder.path}/dj-news-chime.wav').writeAsBytes([1, 2, 3]);
      expect(await DjNewsSting.chime(), DjNewsSting.wav);
    });
    test('importing one chooses it; removing it goes back to the bells', () async {
      expect(await DjNewsSting.chosen(), DjNewsSting.bells);
      await DjNewsSting.choose(DjNewsSting.own);
      expect(await DjNewsSting.chosen(), DjNewsSting.bells, reason: 'there is none to choose yet');
      await DjNewsSting.import(tone(900));
      expect(await DjNewsSting.chosen(), DjNewsSting.own);
      DjNewsSting.reset();
      expect(await DjNewsSting.chosen(), DjNewsSting.own, reason: 'remembered');
      await DjNewsSting.remove();
      expect(await DjNewsSting.chosen(), DjNewsSting.bells);
    });
  });
  group('the sounds that come with the app', () {
    setUp(DjNewsSting.reset);
    tearDown(DjNewsSting.reset);
    test('are listed, each a short recording at the voice rate', () async {
      final sounds = await DjSounds.all();
      expect(sounds, isNotEmpty);
      expect(sounds.map((sound) => sound.id).toSet(), hasLength(sounds.length));
      for (final sound in sounds) {
        expect(sound.name, isNotEmpty);
        final recording = await DjSounds.recording(sound.id);
        expect(recording, isNotNull, reason: sound.id);
        final seconds = DjShowAudio.pcm(recording!).length / 2 / DjShowAudio.sampleRate;
        expect(seconds, inInclusiveRange(0.2, 12), reason: sound.id);
        expect(DjShowAudio.pcm(recording), hasLength(DjShowAudio.pcm(DjShowAudio.jingle(recording)).length));
      }
      expect(await DjSounds.recording('../pubspec'), isNull, reason: 'only the ones listed');
    });
    test('one chosen plays before the news, and stays chosen', () async {
      final sound = (await DjSounds.all()).first;
      await DjNewsSting.choose(sound.id);
      expect(await DjNewsSting.chime(), await DjSounds.recording(sound.id));
      DjNewsSting.reset();
      expect(await DjNewsSting.chosen(), sound.id);
      await DjNewsSting.choose('a-sound-taken-out');
      expect(await DjNewsSting.chosen(), sound.id, reason: 'not one the app has');
    });
    test('a secondary chime takes turns with the primary at its share of news breaks', () async {
      final sound = (await DjSounds.all()).first;
      final recording = await DjSounds.recording(sound.id);
      expect(await DjNewsSting.secondary(), (chime: DjNewsSting.none, chance: 30));
      await DjNewsSting.chooseSecondary(sound.id);
      await DjNewsSting.setSecondaryChance(40);
      DjNewsSting.random = _Rolls([39, 40]);
      expect(await DjNewsSting.chime(), recording, reason: 'a roll under 40');
      expect(await DjNewsSting.chime(), DjNewsSting.wav, reason: 'the primary, the bells');
      DjNewsSting.reset();
      expect(await DjNewsSting.secondary(), (chime: sound.id, chance: 40), reason: 'remembered');
      await DjNewsSting.chooseSecondary('a-sound-taken-out');
      expect((await DjNewsSting.secondary()).chime, sound.id);
      await DjNewsSting.import(tone(900));
      await DjNewsSting.chooseSecondary(DjNewsSting.own);
      await DjNewsSting.remove();
      expect(await DjNewsSting.secondary(), (chime: DjNewsSting.none, chance: 40), reason: 'their own one gone');
    });
    test("a secondary chime still plays when the primary one is gone after a restart", () async {
      final sound = (await DjSounds.all()).first;
      await DjNewsSting.import(tone(900));
      await DjNewsSting.chooseSecondary(sound.id);
      await DjNewsSting.setSecondaryChance(10);
      await File('${folder.path}/dj-news-chime.wav').delete();
      DjNewsSting.reset();
      DjNewsSting.random = _Rolls([99]);
      expect(await DjNewsSting.chosen(), DjNewsSting.bells);
      expect(await DjNewsSting.chime(), await DjSounds.recording(sound.id), reason: 'not the stand-in bells');
    });
    test('one taken out of the app since it was chosen leaves the bells', () async {
      await SharedPreferencesAsync().setString('djNewsChime', 'a-sound-taken-out');
      expect(await DjNewsSting.chosen(), DjNewsSting.bells);
      expect(await DjNewsSting.chime(), DjNewsSting.wav);
    });
  });
}
