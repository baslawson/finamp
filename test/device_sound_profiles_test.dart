import 'dart:convert';
import 'dart:io';
import 'package:audio_service/audio_service.dart';
import 'package:finamp/hive_registrar.g.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/locale_adapter.dart';
import 'package:finamp/models/theme_mode_adapter.dart';
import 'package:finamp/services/device_sound_profiles.dart';
import 'package:finamp/services/dj_voice_service.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:finamp/services/genre_eq_service.dart';
import 'package:finamp/services/music_player_background_task.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:just_audio/just_audio.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

class _Player extends Fake implements MusicPlayerBackgroundTask {
  @override
  final playbackState = BehaviorSubject.seeded(PlaybackState(playing: false));
  @override
  final mediaItem = BehaviorSubject<MediaItem?>.seeded(null);
  @override
  AndroidEqualizer? get equalizer => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'a crash journal restores the baseline, connections apply saved sound, and disconnect restores user settings',
    () async {
      final folder = await Directory.systemTemp.createTemp('finamp-sound-profiles-');
      Hive.registerAdapters();
      Hive.registerAdapter(ThemeModeAdapter());
      Hive.registerAdapter(ColorAdapter());
      Hive.registerAdapter(LocaleAdapter());
      Hive.init(folder.path);
      final box = await Hive.openBox<FinampSettings>('FinampSettings');
      final settings = FinampSettings(
        downloadLocations: [],
        downloadLocationsMap: {},
        tabSortBy: {},
        tabSortOrder: {},
        homeScreenConfiguration: const FinampHomeScreenConfiguration(actions: [], sections: []),
        gridImageSize: 130,
        homeScreenImageSize: 90,
        deviceId: 'test',
      );
      await box.put('FinampSettings', settings);
      final oldPrefs = SharedPreferencesAsyncPlatform.instance;
      SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
      final prefs = SharedPreferencesAsync(), player = _Player();
      GetIt.instance.registerSingleton<MusicPlayerBackgroundTask>(player);
      try {
        await DjVoiceService.saveProfile(
          const DjVoiceProfile(
            settings: (
              mode: DjVoiceMode.off,
              every: 2,
              character: DjVoiceCharacter.energetic,
              aiVoice: true,
              volume: .7,
            ),
          ),
        );
        final baseline = await DeviceSoundProfiles.capture();
        final car = {
          ...baseline,
          'level': 2,
          'tone': '{"bass":2}',
          'genreEq': true,
          'dj': {...(baseline['dj'] as Map), 'volume': .4},
        };
        final headphones = {...baseline, 'level': 0};
        await prefs.setString('deviceSoundProfiles', jsonEncode({'Car': car, 'Headphones': headphones}));
        await prefs.setString('deviceSoundBaseline', jsonEncode(baseline));
        await prefs.setBool('deviceSoundEnabled', true);
        settings.normalizationLevel = 2;
        await box.put('FinampSettings', settings);
        await DeviceSoundProfiles.initialize();
        expect(FinampSettingsHelper.finampSettings.normalizationLevel, 1);
        expect(await prefs.getString('deviceSoundBaseline'), isNull);
        await DeviceSoundProfiles.updateConnections(['Car']);
        expect(DeviceSoundProfiles.active, 'Car');
        expect(settings.normalizationLevel, 2);
        expect((await DjVoiceService.loadProfile()).settings.volume, .4);
        expect(await prefs.getString('headphoneTone'), '{"bass":2}');
        expect(GenreEqService.enabled, true);
        await DjVoiceService.saveProfile(
          DjVoiceService.effectiveProfile.copyWith(
            settings: (mode: DjVoiceMode.off, every: 2, character: DjVoiceCharacter.chill, aiVoice: true, volume: .3),
          ),
        );
        expect(DjVoiceService.effectiveProfile.settings.volume, .3);
        await DeviceSoundProfiles.updateConnections(['Car', 'Headphones']);
        expect(DeviceSoundProfiles.active, 'Car');
        await DeviceSoundProfiles.updateConnections(['Headphones']);
        expect(settings.normalizationLevel, 0);
        await DeviceSoundProfiles.setEnabled(false);
        expect(settings.normalizationLevel, 1);
        expect(await prefs.getString('headphoneTone'), isNull);
        expect((await DjVoiceService.loadProfile()).settings.volume, .7);
        expect(await prefs.getString('deviceSoundBaseline'), isNull);
        expect(await prefs.getString('deviceSoundProfiles'), isNotNull);
        expect(GenreEqService.enabled, false);
      } finally {
        await GetIt.instance.reset();
        await DjVoiceService.initialize();
        await player.playbackState.close();
        await player.mediaItem.close();
        SharedPreferencesAsyncPlatform.instance = oldPrefs;
        await Hive.close();
        await folder.delete(recursive: true);
      }
    },
  );
}
