import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:finamp/hive_registrar.g.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/models/locale_adapter.dart';
import 'package:finamp/models/theme_mode_adapter.dart';
import 'package:finamp/services/analyzer_service.dart';
import 'package:finamp/services/radio_tuning.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferencesAsyncPlatform? previous;
  late Directory folder;
  setUpAll(() {
    Hive.registerAdapters();
    Hive.registerAdapter(ThemeModeAdapter());
    Hive.registerAdapter(ColorAdapter());
    Hive.registerAdapter(LocaleAdapter());
  });
  setUp(() async {
    folder = await Directory.systemTemp.createTemp('finamp-radio-tuning-');
    Hive.init(folder.path);
    final box = await Hive.openBox<FinampSettings>('FinampSettings');
    await box.put(
      'FinampSettings',
      FinampSettings(
        downloadLocations: [],
        downloadLocationsMap: {},
        tabSortBy: {},
        tabSortOrder: {},
        homeScreenConfiguration: const FinampHomeScreenConfiguration(actions: [], sections: []),
        gridImageSize: 130,
        homeScreenImageSize: 90,
        deviceId: 'test',
      ),
    );
    previous = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    await AnalyzerService.saveSettings(url: 'http://analyzer.test', token: 't');
  });
  tearDown(() async {
    HarmonicMixing.enabled = false;
    SharedPreferencesAsyncPlatform.instance = previous;
    await Hive.close();
    try {
      await folder.delete(recursive: true);
    } on FileSystemException {
      // Windows may still hold the box file for a moment.
    }
  });

  test('a slow analyzer does not hold up radio ordering', () async {
    final pending = Completer<http.Response>();
    final seed = BaseItemDto(id: BaseItemId('seed'), name: 'Seed');
    final candidates = [for (var i = 0; i < 5; i++) BaseItemDto(id: BaseItemId('c$i'), name: 'C$i')];
    final clock = Stopwatch()..start();
    final ordered = await http.runWithClient(
      () => RadioTuning.order(seed, candidates),
      () => MockClient(
        (request) =>
            request.url.path.endsWith('/analysis') ? pending.future : Future.value(http.Response(jsonEncode({}), 200)),
      ),
    );
    expect(clock.elapsed, lessThan(RadioTuning.analysisWait + const Duration(milliseconds: 800)));
    expect(ordered.map((t) => t.id.raw).toSet(), candidates.map((t) => t.id.raw).toSet());
    pending.complete(http.Response(jsonEncode({}), 200));
  });

  test('harmonic Radio at 0% strength orders like harmonic mixing off, even at 100% randomness', () async {
    final box = Hive.box<FinampSettings>('FinampSettings');
    await box.put('FinampSettings', box.get('FinampSettings')!..shuffleRandomness = 100);
    final seed = BaseItemDto(id: BaseItemId('seed'), name: 'Seed');
    final candidates = [for (var i = 0; i < 12; i++) BaseItemDto(id: BaseItemId('c$i'), name: 'C$i')];
    // Every other song is in the seed's key and tempo; the rest clash.
    final analysis = {
      'seed': {'bpm': 120, 'camelot': '8A'},
      for (var i = 0; i < 12; i++) 'c$i': i.isEven ? {'bpm': 120, 'camelot': '8A'} : {'bpm': 87, 'camelot': '2B'},
    };
    Future<List<String>> order({required bool harmonic, required int strength, required int seedNumber}) async {
      HarmonicMixing.enabled = harmonic;
      HarmonicMixing.strength.value = strength;
      final ordered = await http.runWithClient(
        () => RadioTuning.order(seed, candidates, random: Random(seedNumber)),
        () => MockClient((request) async => http.Response(jsonEncode(analysis), 200)),
      );
      return [for (final track in ordered) track.id.raw];
    }

    var matchingFirst = 0;
    for (var i = 0; i < 40; i++) {
      expect(
        await order(harmonic: true, strength: 0, seedNumber: i),
        await order(harmonic: false, strength: 75, seedNumber: i),
      );
      final strict = await order(harmonic: true, strength: 100, seedNumber: i);
      if (int.parse(strict.first.substring(1)).isEven) matchingFirst++;
    }
    // A plain random order starts with a matching song about half the time.
    expect(matchingFirst, greaterThan(30));
    HarmonicMixing.strength.value = HarmonicMixing.defaultStrength;
  });

  test('the harmonic mixing setting is remembered', () async {
    expect(await HarmonicMixing.load(), false);
    await HarmonicMixing.setEnabled(true);
    HarmonicMixing.enabled = false;
    expect(await HarmonicMixing.load(), true);
  });

  test('the harmonic strength is shared, remembered and 75% until changed', () async {
    HarmonicMixing.strength.value = 10;
    await HarmonicMixing.load();
    expect(HarmonicMixing.strength.value, HarmonicMixing.defaultStrength);
    expect(HarmonicMixing.defaultStrength, 75);
    await HarmonicMixing.setStrength(140);
    expect(HarmonicMixing.strength.value, 100);
    await HarmonicMixing.setStrength(40);
    HarmonicMixing.strength.value = 0;
    await HarmonicMixing.load();
    expect(HarmonicMixing.strength.value, 40);
    HarmonicMixing.strength.value = HarmonicMixing.defaultStrength;
  });
}
