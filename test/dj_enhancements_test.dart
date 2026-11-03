import 'dart:io';

import 'package:finamp/services/dj_recordings.dart';
import 'package:finamp/services/dj_voice_preferences.dart';
import 'package:finamp/services/dj_voice_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferencesAsyncPlatform? oldPrefs;
  setUp(() {
    oldPrefs = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
  });
  tearDown(() => SharedPreferencesAsyncPlatform.instance = oldPrefs);

  test('old profiles retain the original music dip; invalid levels are bounded', () {
    expect(DjVoiceProfile.fromJson({}).musicUnderVoice, .22);
    expect(DjVoiceProfile.fromJson({'musicUnderVoice': double.nan}).musicUnderVoice, .22);
    expect(DjVoiceProfile.fromJson({'musicUnderVoice': -1}).musicUnderVoice, 0);
    expect(DjVoiceProfile.fromJson({'musicUnderVoice': 2}).musicUnderVoice, 1);
  });

  test('music level survives global and station profile persistence', () async {
    const profile = DjVoiceProfile(musicUnderVoice: .43);
    await DjVoicePreferences.saveGlobal(profile);
    await DjVoicePreferences.saveStations('account', {'station': profile.copyWith(musicUnderVoice: .09)});
    expect((await DjVoicePreferences.loadGlobal()).musicUnderVoice, .43);
    expect((await DjVoicePreferences.loadStations('account'))['station']!.musicUnderVoice, .09);
  });

  test('saved presets change only the three listening controls', () async {
    const profile = DjVoiceProfile(
      settings: (mode: DjVoiceMode.always, every: 7, character: DjVoiceCharacter.pirate, aiVoice: true, volume: .8),
      rotate: true,
      favourites: [DjVoiceCharacter.pirate, DjVoiceCharacter.trailer],
      musicUnderVoice: .4,
      length: DjAnnouncementLength.chatty,
    );
    final presets = await DjVoicePreferences.loadListeningPresets();
    presets[DjListeningEnvironment.car] = DjListeningPreset.fromProfile(profile);
    await DjVoicePreferences.saveListeningPresets(presets);
    final loaded = await DjVoicePreferences.loadListeningPresets();
    final applied = loaded[DjListeningEnvironment.car]!.apply(
      profile.copyWith(musicUnderVoice: .1, length: DjAnnouncementLength.brief),
    );
    expect(applied.toJson(), profile.toJson());
    final headphones = loaded[DjListeningEnvironment.headphones]!.apply(profile);
    expect(headphones.settings.volume, .65);
    expect(headphones.musicUnderVoice, .3);
    expect(headphones.settings.character, profile.settings.character);
    expect(headphones.settings.mode, profile.settings.mode);
    expect(headphones.settings.every, profile.settings.every);
    expect(headphones.favourites, profile.favourites);
    expect(headphones.rotate, isTrue);
    await SharedPreferencesAsync().setString('djListeningPresets', 'damaged');
    expect((await DjVoicePreferences.loadListeningPresets()).length, 2);
  });

  test('replay copies survive replacement; clearing releases the retained original', () async {
    final folder = await Directory.systemTemp.createTemp('finamp-replay-');
    final store = DjReplayStore();
    try {
      final first = await File('${folder.path}/first.wav').writeAsBytes([1, 2, 3]);
      final second = await File('${folder.path}/second.wav').writeAsBytes([4, 5, 6]);
      store.remember(DjAudioClip(first, 'First line'));
      final replay = (await store.copyForReplay())!;
      expect(replay.text, 'First line');
      expect(replay.file.path, isNot(first.path));
      store.remember(DjAudioClip(second, 'Second line'));
      expect(await replay.file.readAsBytes(), [1, 2, 3]);
      expect(store.latest.value, 'Second line');
      expect(store.owns(second), isTrue);
      store.clear();
      expect(await store.copyForReplay(), isNull);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(await first.exists(), isFalse);
      expect(await second.exists(), isFalse);
      expect(await replay.file.exists(), isTrue);
    } finally {
      store.clear();
      await folder.delete(recursive: true);
    }
  });
}
