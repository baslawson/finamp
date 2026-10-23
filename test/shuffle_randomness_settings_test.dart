import 'dart:io';

import 'package:finamp/components/AudioServiceSettingsScreen/shuffle_randomness_slider.dart';
import 'package:finamp/hive_registrar.g.dart';
import 'package:finamp/l10n/app_localizations.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/models/music_slices.dart';
import 'package:finamp/models/locale_adapter.dart';
import 'package:finamp/models/theme_mode_adapter.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/adapters.dart';

class _LegacySettingsAdapter extends TypeAdapter<FinampSettings> {
  @override
  int get typeId => 28;
  @override
  FinampSettings read(BinaryReader reader) => throw UnimplementedError();
  @override
  void write(BinaryWriter writer, FinampSettings settings) {
    writer
      ..writeByte(1)
      ..writeByte(3)
      ..write(<DownloadLocation>[]);
  }
}

FinampSettings _settings() => FinampSettings(
  downloadLocations: [],
  downloadLocationsMap: {},
  tabSortBy: {},
  tabSortOrder: {},
  homeScreenConfiguration: const FinampHomeScreenConfiguration(actions: [], sections: []),
  gridImageSize: 130,
  homeScreenImageSize: 90,
  deviceId: 'test',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUpAll(() {
    Hive.registerAdapters();
    Hive.registerAdapter(ThemeModeAdapter());
    Hive.registerAdapter(ColorAdapter());
    Hive.registerAdapter(LocaleAdapter());
  });
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('finamp-randomness-');
    Hive.init(directory.path);
    Hive.registerAdapter(FinampSettingsAdapter(), override: true);
  });
  tearDown(() async {
    await Hive.close();
    for (final file in await directory.list().toList()) {
      if (file is File) await file.delete();
    }
    await directory.delete();
  });

  test('old settings default to 50%, and the new setting persists across reopening', () async {
    expect(_settings().shuffleRandomness, 50);
    Hive.registerAdapter(_LegacySettingsAdapter(), override: true);
    var box = await Hive.openBox<FinampSettings>('FinampSettings');
    await box.put('FinampSettings', _settings());
    await box.close();
    Hive.registerAdapter(FinampSettingsAdapter(), override: true);
    box = await Hive.openBox<FinampSettings>('FinampSettings');
    expect(FinampSettingsHelper.finampSettings.shuffleRandomness, 50);
    FinampSetters.setShuffleRandomness(73);
    await box.flush();
    await box.close();
    box = await Hive.openBox<FinampSettings>('FinampSettings');
    expect(FinampSettingsHelper.finampSettings.shuffleRandomness, 73);
    FinampSettingsHelper.resetAudioServiceSettings();
    await box.flush();
    expect(FinampSettingsHelper.finampSettings.shuffleRandomness, 50);
  });

  testWidgets('both slider copies show and save the same percentage without overflow', (tester) async {
    await tester.runAsync(() async {
      final box = await Hive.openBox<FinampSettings>('FinampSettings');
      await box.put('FinampSettings', _settings());
    });
    tester.view.physicalSize = const Size(320, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(1.5)),
            child: child!,
          ),
          home: const Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: [
                  ShuffleRandomnessSlider(),
                  ShuffleRandomnessSlider(padding: EdgeInsets.zero),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Randomness: 50%'), findsNWidgets(2));
    final slider = tester.widget<Slider>(find.byType(Slider).first);
    await tester.runAsync(() async {
      slider.onChanged!(73);
      await Hive.box<FinampSettings>('FinampSettings').flush();
    });
    await tester.pumpAndSettle();
    expect(find.text('Randomness: 73%'), findsNWidgets(2));
    expect(FinampSettingsHelper.finampSettings.shuffleRandomness, 73);
    await tester.runAsync(() async {
      slider.onChanged!(0);
      await Hive.box<FinampSettings>('FinampSettings').flush();
    });
    await tester.pumpAndSettle();
    expect(find.text('Randomness: 0%'), findsNWidgets(2));
    await tester.runAsync(() async {
      slider.onChanged!(100);
      await Hive.box<FinampSettings>('FinampSettings').flush();
    });
    await tester.pumpAndSettle();
    expect(find.text('Randomness: 100%'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  test('slice shuffles use the saved percentage and prepared lists keep their order', () async {
    final box = await Hive.openBox<FinampSettings>('FinampSettings');
    await box.put('FinampSettings', _settings()..shuffleRandomness = 0);
    const source = QueueItemSource.rawId(
      type: QueueItemSourceType.allTracks,
      name: QueueItemSourceName(type: QueueItemSourceNameType.preTranslated, pretranslatedName: 'Shuffle'),
      id: 'all',
    );
    final tracks = [
      for (final id in ['c', 'a', 'b']) BaseItemDto(id: BaseItemId(id), name: id, type: 'Audio'),
    ];
    final slice = PlayableSlice.simple(tracks, source).shuffle();
    final resolved = await slice.resolve(preShuffle: true);
    expect(resolved.items.map((track) => track.id.raw), ['a', 'b', 'c']);
    expect(resolved.shuffleState, SliceShuffleState.preShuffled);
    FinampSetters.setShuffleRandomness(100);
    expect((await resolved.resolve(preShuffle: true)).items, resolved.items);
    expect((await PlayableSlice.simple(tracks, source).markPreshuffled().resolve(preShuffle: true)).items, tracks);
    await box.flush();
  });

  test('album shuffles apply the percentage once and keep the songs within each album in order', () async {
    final box = await Hive.openBox<FinampSettings>('FinampSettings');
    await box.put('FinampSettings', _settings()..shuffleRandomness = 0);
    const source = QueueItemSource.rawId(
      type: QueueItemSourceType.artist,
      name: QueueItemSourceName(type: QueueItemSourceNameType.preTranslated, pretranslatedName: 'Artist'),
      id: 'artist',
    );
    final tracks = [
      for (final id in ['b1', 'b2', 'a1', 'a2'])
        BaseItemDto(id: BaseItemId(id), name: id, album: id[0], albumId: BaseItemId(id[0]), type: 'Audio'),
    ];
    final slice = GroupedPlayableSlice(
      parent: PlayableSlice.simple(tracks, source).shuffle(),
      groupBy: (track) => track.albumId?.raw,
    );
    final resolved = await slice.resolve(preShuffle: true);
    expect(resolved.items.map((track) => track.id.raw), ['a1', 'a2', 'b1', 'b2']);
    expect(tracks.map((track) => track.id.raw), ['b1', 'b2', 'a1', 'a2']);
  });
}
