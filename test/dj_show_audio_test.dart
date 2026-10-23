import 'dart:io';
import 'dart:typed_data';

import 'package:finamp/services/ai_service.dart';
import 'package:finamp/services/dj_show_audio.dart';
import 'package:finamp/services/dj_voice_preferences.dart';
import 'package:finamp/services/dj_voice_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:path/path.dart' as path;
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
    await expectLater(DjJingleStore.save(Uint8List(2 * 1024 * 1024 + 1), scope: 'account-a'), throwsFormatException);
    final id = await DjJingleStore.save(tone(1200), scope: 'account-a');
    expect(await DjJingleStore.read(id, scope: 'account-a'), isNotNull);
    expect(await DjJingleStore.read(id, scope: 'account-b'), isNull);
    expect(await DjJingleStore.read('../not-a-jingle', scope: 'account-a'), isNull);
    await expectLater(DjJingleStore.save(tone(1, seconds: 13), scope: 'account-a'), throwsFormatException);
    await DjJingleStore.remove(id, scope: 'account-a');
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
}
