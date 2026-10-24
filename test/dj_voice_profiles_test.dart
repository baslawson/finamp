import 'dart:io';

import 'package:finamp/hive_registrar.g.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/dj_voice_preferences.dart';
import 'package:finamp/services/dj_voice_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

const off = (mode: DjVoiceMode.off, every: 4, character: DjVoiceCharacter.pirate, aiVoice: true, volume: 0.6);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferencesAsyncPlatform? original;
  setUp(() async {
    original = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    await DjVoicePreferences.saveGlobal(const DjVoiceProfile(settings: off));
    await DjVoiceService.initialize();
  });
  tearDown(() async {
    await DjVoiceService.resumeDj();
    SharedPreferencesAsyncPlatform.instance = original;
  });

  test('legacy settings and new options survive saves through the original settings API', () async {
    await DjVoiceService.saveProfile(
      const DjVoiceProfile(
        settings: off,
        length: DjAnnouncementLength.chatty,
        rotate: true,
        favourites: [DjVoiceCharacter.pirate, DjVoiceCharacter.trailer],
      ),
    );
    await DjVoiceService.saveSettings((
      mode: off.mode,
      every: 7,
      character: off.character,
      aiVoice: off.aiVoice,
      volume: .4,
    ));
    final profile = await DjVoiceService.loadProfile();
    expect(profile.settings.every, 7);
    expect(profile.settings.volume, .4);
    expect(profile.length, DjAnnouncementLength.chatty);
    expect(profile.rotates, isTrue);
    expect(profile.favourites, [DjVoiceCharacter.pirate, DjVoiceCharacter.trailer]);
    expect(await SharedPreferencesAsync().getInt('djVoiceEvery'), 7);
  });

  test('station edits and reset leave the main defaults and other stations alone', () async {
    const station = DjVoiceProfile(settings: off, length: DjAnnouncementLength.brief);
    await DjVoiceService.saveProfile(station, stationId: 'station-a');
    await DjVoiceService.saveProfile(
      const DjVoiceProfile(settings: off, length: DjAnnouncementLength.chatty),
      stationId: 'station-b',
    );
    expect((await DjVoiceService.loadProfile()).length, DjAnnouncementLength.normal);
    expect((await DjVoiceService.loadProfile(stationId: 'station-a')).length, DjAnnouncementLength.brief);
    await DjVoiceService.clearStationProfile('station-a');
    expect(await DjVoiceService.hasStationProfile('station-a'), isFalse);
    expect((await DjVoiceService.loadProfile(stationId: 'station-a')).length, DjAnnouncementLength.normal);
    expect((await DjVoiceService.loadProfile(stationId: 'station-b')).length, DjAnnouncementLength.chatty);
  });

  test('co-host reservation preserves favourites across global and station reloads', () async {
    const profile = DjVoiceProfile(
      settings: off,
      rotate: true,
      favourites: [DjVoiceCharacter.pirate, DjVoiceCharacter.trailer, DjVoiceCharacter.meditation],
      show: DjShowSettings(duoChance: 25, coHost: DjVoiceCharacter.pirate),
    );
    await DjVoiceService.saveProfile(profile);
    await DjVoiceService.saveProfile(profile, stationId: 'duo');
    await DjVoiceService.initialize();
    for (final id in <String?>[null, 'duo']) {
      final restored = await DjVoiceService.loadProfile(stationId: id);
      expect(restored.favourites, profile.favourites);
      expect(restored.rotationFavourites, {DjVoiceCharacter.trailer, DjVoiceCharacter.meditation});
      expect(restored.rotates, isTrue);
      final disabled = restored.copyWith(show: restored.show.copyWith(duoChance: 0));
      expect(disabled.rotationFavourites, profile.favourites.toSet());
      final changed = restored.copyWith(show: restored.show.copyWith(coHost: DjVoiceCharacter.trailer));
      expect(changed.rotationFavourites, {DjVoiceCharacter.pirate, DjVoiceCharacter.meditation});
    }
  });

  test('one eligible favourite pauses rotation without losing the requested rotation', () {
    const profile = DjVoiceProfile(
      settings: off,
      rotate: true,
      favourites: [DjVoiceCharacter.pirate, DjVoiceCharacter.trailer],
      show: DjShowSettings(duoChance: 25, coHost: DjVoiceCharacter.pirate),
    );
    expect(profile.rotates, isFalse);
    expect(profile.rotate, isTrue);
    expect(profile.singleCharacter, DjVoiceCharacter.trailer);
    final restored = DjVoiceProfile.fromJson(profile.toJson());
    expect(restored.singleCharacter, DjVoiceCharacter.trailer);
    expect(restored.copyWith(show: restored.show.copyWith(duoChance: 0)).rotates, isTrue);
    expect(restored.copyWith(rotate: false).singleCharacter, off.character);
  });

  test('legacy duplicate and unavailable favourites cannot enable a rotation', () {
    const profile = DjVoiceProfile(
      settings: off,
      rotate: true,
      favourites: [DjVoiceCharacter.pirate, DjVoiceCharacter.trailer, DjVoiceCharacter.trailer],
      show: DjShowSettings(duoChance: 25, coHost: DjVoiceCharacter.pirate),
    );
    expect(profile.rotationFavourites, {DjVoiceCharacter.trailer});
    expect(profile.rotates, isFalse);
    final empty = profile.copyWith(favourites: [DjVoiceCharacter.pirate, DjVoiceCharacter.byTimeOfDay]);
    expect(empty.rotationFavourites, isEmpty);
    expect(empty.rotates, isFalse);
    expect(empty.singleCharacter, off.character);
  });

  test('random timing defaults off and persists independently of the fixed frequency', () async {
    expect(DjVoiceProfile.fromJson({}).randomTiming, isFalse);
    expect(DjVoiceProfile.fromJson({'randomTiming': 'true'}).randomTiming, isFalse);
    const profile = DjVoiceProfile(settings: off, randomTiming: true);
    await DjVoiceService.saveProfile(profile);
    await DjVoiceService.initialize();
    final restored = await DjVoiceService.loadProfile();
    expect(restored.randomTiming, isTrue);
    expect(restored.settings.every, 4);
    await DjVoiceService.saveSettings((mode: off.mode, every: 8, character: off.character, aiVoice: true, volume: .4));
    expect((await DjVoiceService.loadProfile()).randomTiming, isTrue);
    expect((await DjVoiceService.loadProfile()).settings.every, 8);
    await DjVoiceService.saveProfile(restored.copyWith(randomTiming: false), stationId: 'fixed');
    await DjVoiceService.saveProfile(profile, stationId: 'random');
    expect((await DjVoiceService.loadProfile(stationId: 'fixed')).randomTiming, isFalse);
    expect((await DjVoiceService.loadProfile(stationId: 'random')).randomTiming, isTrue);
    expect((await DjVoiceService.loadProfile()).randomTiming, isTrue);
    expect(DjListeningPreset.car.apply(profile).randomTiming, isTrue);
  });

  test('station options are isolated by server/user scope', () async {
    await DjVoicePreferences.saveStations('account-a', {'same-id': const DjVoiceProfile(settings: off)});
    expect((await DjVoicePreferences.loadStations('account-a')).containsKey('same-id'), isTrue);
    expect(await DjVoicePreferences.loadStations('account-b'), isEmpty);
  });

  test('quiet survives restart and resume keeps all configured DJ options', () async {
    await DjVoiceService.quietFor(const Duration(minutes: 30));
    final until = DjVoiceService.status.value.$3;
    expect(DjVoiceService.isQuiet, isTrue);
    await DjVoiceService.initialize();
    expect(DjVoiceService.status.value.$3, until);
    expect(await DjVoiceService.loadSettings(), off);
    await DjVoiceService.resumeDj();
    expect(DjVoiceService.isQuiet, isFalse);
    expect(await SharedPreferencesAsync().getInt('djVoiceQuietUntil'), isNull);
    expect(await DjVoiceService.loadSettings(), off);
  });

  test('quiet expires even when no music is playing', () async {
    await DjVoiceService.quietFor(const Duration(milliseconds: 100));
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(DjVoiceService.isQuiet, isFalse);
    expect(DjVoiceService.status.value.$3, isNull);
    expect(await DjVoicePreferences.loadQuietUntil(DateTime.now()), isNull);
  });

  test('resuming immediately cannot leave an old quiet deadline on disk', () async {
    final quiet = DjVoiceService.quietFor(const Duration(minutes: 15));
    final resume = DjVoiceService.resumeDj();
    await Future.wait([quiet, resume]);
    expect(DjVoiceService.isQuiet, isFalse);
    expect(await DjVoicePreferences.loadQuietUntil(DateTime.now()), isNull);
  });

  test('invalid and expired options safely keep playback defaults', () async {
    final profile = DjVoiceProfile.fromJson({
      'every': -20,
      'volume': double.nan,
      'length': 'removed',
      'favourites': ['pirate', 'pirate', 'removed', 'byTimeOfDay'],
      'rotate': true,
    });
    expect(profile.settings.every, 1);
    expect(profile.settings.volume, 0.7);
    expect(profile.length, DjAnnouncementLength.normal);
    expect(profile.favourites, [DjVoiceCharacter.pirate]);
    expect(profile.rotates, isFalse);
    await DjVoicePreferences.saveQuietUntil(DateTime.now().subtract(const Duration(minutes: 1)));
    expect(await DjVoicePreferences.loadQuietUntil(DateTime.now()), isNull);
    await expectLater(DjVoiceService.quietFor(Duration.zero), throwsArgumentError);
    expect(DjVoiceService.isQuiet, isFalse);
  });

  test('an invalid saved quiet deadline cannot prevent DJ startup', () async {
    await SharedPreferencesAsync().setInt('djVoiceQuietUntil', 9223372036854775807);
    await DjVoiceService.initialize();
    expect(DjVoiceService.isQuiet, isFalse);
    expect(await SharedPreferencesAsync().getInt('djVoiceQuietUntil'), isNull);
  });

  test('station identity survives a real saved queue source round trip', () async {
    Hive.registerAdapters();
    final directory = await Directory.systemTemp.createTemp('finamp-dj-station-');
    try {
      Hive.init(directory.path);
      final box = await Hive.openBox<QueueItemSource>('source');
      const source = QueueItemSource.rawId(
        type: QueueItemSourceType.radio,
        name: QueueItemSourceName(type: QueueItemSourceNameType.radio, localizationParameter: 'Evening station'),
        id: 'seed',
        djStationId: 'saved-station',
        genreMix: 'Pop | Rock',
      );
      await box.put('station', source);
      await box.close();
      final reopened = await Hive.openBox<QueueItemSource>('source');
      expect(reopened.get('station')!.id, 'seed');
      expect(reopened.get('station')!.djStationId, 'saved-station');
      expect(reopened.get('station')!.genreMix, 'Pop | Rock');
      expect(source.withItem(BaseItemDto(id: const BaseItemId('seed'))).djStationId, 'saved-station');
      expect(source.withItem(BaseItemDto(id: const BaseItemId('seed'))).genreMix, 'Pop | Rock');
    } finally {
      await Hive.close();
      await directory.delete(recursive: true);
    }
  });
}
