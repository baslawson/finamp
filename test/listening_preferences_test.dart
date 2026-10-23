import 'dart:convert';
import 'dart:math';
import 'dart:io';
import 'package:finamp/services/finamp_user_helper.dart';
import 'package:get_it/get_it.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/artist_spacing.dart';
import 'package:finamp/services/device_sound_profiles.dart';
import 'package:finamp/services/headphone_eq_service.dart';
import 'package:finamp/services/listening_log_service.dart';
import 'package:finamp/services/listening_preferences.dart';
import 'package:finamp/services/radio_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

BaseItemDto song(String id, String artist) =>
    BaseItemDto(id: BaseItemId(id), name: id, type: 'Audio', artists: [artist]);

class _User extends Fake implements FinampUserHelper {
  @override
  FinampUser? currentUser;
}

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    await ListeningPreferences.ensureLoaded();
  });
  tearDown(() async {
    for (final rest in ListeningPreferences.rests) {
      await ListeningPreferences.removeRest(rest.key);
    }
    for (final id in ['one', 'two']) {
      await ListeningPreferences.setTransition(id, SongTransition.automatic);
    }
    ListeningSession.excludeFromLearning.value = false;
  });
  test('song rest expires at the exact deadline and does not rest the entire artist', () async {
    await ListeningPreferences.rest(song('one', 'Blink-182'), artist: false, days: 1);
    final rest = ListeningPreferences.rests.single;
    expect(ListeningPreferences.permits(song('one', 'Blink-182')), false);
    expect(ListeningPreferences.permits(song('two', 'Blink-182')), true);
    expect(ListeningPreferences.permits(song('one', 'Blink-182'), now: rest.until), true);
    final raw =
        jsonDecode((await SharedPreferencesAsync().getString('listeningChoices.${RadioPreferencesStore.scope}'))!)
            as Map;
    expect(raw['rests'], hasLength(1));
    await ListeningPreferences.removeRest(rest.key);
    expect(ListeningPreferences.permits(song('one', 'Blink-182')), true);
  });
  test('artist rest uses canonical names; generated mixes omit it but keep an explicit seed', () async {
    final picked = song('one', 'Blink-182');
    await ListeningPreferences.rest(picked, artist: true, days: 7);
    expect(ListeningPreferences.permits(song('other', 'BLINK 182 feat. Someone')), false);
    const source = QueueItemSource.rawId(
      type: QueueItemSourceType.radio,
      id: 'radio',
      name: QueueItemSourceName(type: QueueItemSourceNameType.preTranslated, pretranslatedName: 'Radio'),
    );
    final others = [song('two', 'AC/DC'), song('three', 'Muse')];
    expect(ArtistSpacing.generated([picked, ...others], source).map((v) => v.id.raw), ['two', 'three']);
    expect(ArtistSpacing.generated([picked, ...others], source, keepFirst: true).first, same(picked));
    expect(const RadioPreferences().permits(picked), false);
  });
  test('protected songs suppress both adjacent fades; short fades never lengthen a global fade', () async {
    for (final mode in [SongTransition.fullEnding, SongTransition.gapless]) {
      await ListeningPreferences.setTransition('one', mode);
      expect(ListeningPreferences.fadeSeconds('one', 'two', 8), 0);
      expect(ListeningPreferences.fadeSeconds('two', 'one', 8), mode == SongTransition.gapless ? 0 : 8);
    }
    await ListeningPreferences.setTransition('one', SongTransition.shortFade);
    expect(ListeningPreferences.fadeSeconds('one', 'two', 8), 2);
    expect(ListeningPreferences.fadeSeconds('two', 'one', 1), 1);
    expect(ListeningPreferences.fadeSeconds('one', 'two', 0), 0);
    await ListeningPreferences.setTransition('one', SongTransition.automatic);
    expect(ListeningPreferences.fadeSeconds('one', 'two', 8), 8);
  });
  test('learning status belongs to a listen; turning learning back on does not rewrite it', () {
    final normal = Object(), party = Object();
    ListeningSession.begin(normal);
    ListeningSession.excludeFromLearning.value = true;
    ListeningSession.begin(party);
    ListeningSession.excludeFromLearning.value = false;
    expect(ListeningSession.excluded(normal), false);
    expect(ListeningSession.excluded(party), true);
    ListeningSession.exclude(normal);
    expect(ListeningSession.excluded(normal), true);
  });
  test('old logs default to learning; exclusion persists without removing history metadata', () {
    final entry = ListenEntry(
      time: DateTime.utc(2026),
      listened: const Duration(minutes: 2),
      trackId: 'one',
      track: 'Song',
      excludedFromLearning: true,
    );
    expect(ListenEntry.fromJson(entry.toJson()).excludedFromLearning, true);
    final old = entry.toJson()..remove('excludeLearning');
    expect(ListenEntry.fromJson(old).excludedFromLearning, false);
  });
  test('A/B band-power matching removes a loudness advantage without adding positive headroom', () {
    for (final gains in [
      [0.0, 0.0, 0.0],
      [4.0, 2.0, -2.0],
      [-4.0, 0.0, 4.0],
    ]) {
      final matched = HeadphoneEqService.matchBandPower(gains);
      final power = matched.fold<double>(0, (sum, v) => sum + pow(10, v / 10)) / matched.length;
      expect(power, closeTo(1, 1e-10));
      expect(matched[1] - matched[0], closeTo(gains[1] - gains[0], 1e-10));
    }
  });
  test('damaged tone values are finite and bounded; controls shape distinct frequency ranges', () {
    expect(const HeadphoneTone().curve, isEmpty, reason: 'Neutral tone must leave the existing correction unchanged');
    final tone = HeadphoneTone.fromJson({'bass': 100, 'warmth': double.nan, 'clarity': -20});
    expect(tone.bass, 4);
    expect(tone.warmth, 0);
    expect(tone.clarity, -4);
    expect(tone.curve.first.$2, 4);
    expect(tone.curve.where((v) => v.$1 == 5000).single.$2, -4);
  });
  test('A/B matching remains equal-power when hardware gain limits are reached', () {
    final result = HeadphoneEqService.matchBandPower([-15, -15, 15, 15, 15], minDecibels: -15, maxDecibels: 15);
    expect(result.every((v) => v >= -15 && v <= 15), true);
    expect(result.fold<double>(0, (sum, v) => sum + pow(10, v / 10)) / result.length, closeTo(1, 1e-10));
  });
  test('multiple connected devices keep a stable profile and disconnect selects another saved device', () {
    expect(DeviceSoundProfiles.choose(['Car', 'Headphones'], ['Car', 'Headphones'], 'Car'), 'Car');
    expect(DeviceSoundProfiles.choose(['Headphones'], ['Car', 'Headphones'], 'Car'), 'Headphones');
    expect(DeviceSoundProfiles.choose(['Unrelated'], ['Car'], 'Car'), isNull);
  });
  test('rests and transition choices persist independently for each Jellyfin account', () async {
    FinampUser user(String id) => FinampUser(
      id: id,
      publicAddress: 'http://test',
      localAddress: 'http://test',
      preferLocalNetwork: false,
      isLocal: false,
      accessToken: 'test',
      serverId: 'server',
    );
    final helper = _User()..currentUser = user('first');
    GetIt.instance.registerSingleton<FinampUserHelper>(helper);
    try {
      await ListeningPreferences.ensureLoaded();
      await ListeningPreferences.rest(song('one', 'A'), artist: false, days: 30);
      await ListeningPreferences.setTransition('one', SongTransition.gapless);
      helper.currentUser = user('second');
      await ListeningPreferences.ensureLoaded();
      expect(ListeningPreferences.permits(song('one', 'A')), true);
      expect(ListeningPreferences.transition('one'), SongTransition.automatic);
      helper.currentUser = user('first');
      await ListeningPreferences.ensureLoaded();
      expect(ListeningPreferences.permits(song('one', 'A')), false);
      expect(ListeningPreferences.transition('one'), SongTransition.gapless);
    } finally {
      await GetIt.instance.reset();
      await ListeningPreferences.ensureLoaded();
    }
  });
  test(
    'learning reads exclude party listens while ordinary history keeps them and tolerates a damaged final line',
    () async {
      final folder = await Directory.systemTemp.createTemp('finamp-learning-log-');
      final oldPaths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _Paths(folder.path);
      try {
        ListenEntry entry(bool excluded) => ListenEntry(
          time: DateTime.now(),
          listened: const Duration(minutes: 2),
          trackId: excluded ? 'party' : 'normal',
          track: 'Song',
          excludedFromLearning: excluded,
        );
        await File(
          '${folder.path}/listening_log.jsonl',
        ).writeAsString('${jsonEncode(entry(false).toJson())}\n${jsonEncode(entry(true).toJson())}\n{incomplete');
        expect((await ListeningLogService.load()).map((v) => v.trackId), ['normal', 'party']);
        expect((await ListeningLogService.load(forLearning: true)).map((v) => v.trackId), ['normal']);
      } finally {
        PathProviderPlatform.instance = oldPaths;
        await folder.delete(recursive: true);
      }
    },
  );
}
