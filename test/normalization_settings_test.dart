import 'dart:io';
import 'package:finamp/screens/volume_normalization_settings_screen.dart';

import 'package:finamp/hive_registrar.g.dart';
import 'package:finamp/l10n/app_localizations.dart';
import 'package:finamp/models/finamp_models.dart';
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
      ..writeByte(2)
      ..writeByte(29)
      ..write(false)
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

  test('normalization migration preserves Off and defaults to Normal; level persists', () async {
    Hive.registerAdapter(_LegacySettingsAdapter(), override: true);
    var box = await Hive.openBox<FinampSettings>('FinampSettings');
    await box.put('FinampSettings', _settings());
    await box.close();
    Hive.registerAdapter(FinampSettingsAdapter(), override: true);
    box = await Hive.openBox<FinampSettings>('FinampSettings');
    expect(FinampSettingsHelper.finampSettings.volumeNormalizationActive, false);
    expect(FinampSettingsHelper.finampSettings.normalizationLevel, 1);
    FinampSetters.setNormalizationLevel(2);
    await box.flush();
    await box.close();
    box = await Hive.openBox<FinampSettings>('FinampSettings');
    expect(FinampSettingsHelper.finampSettings.normalizationLevel, 2);
    expect(FinampSettingsHelper.finampSettings.volumeNormalizationActive, false);
    FinampSettingsHelper.resetNormalizationSettings();
    await box.flush();
    expect(FinampSettingsHelper.finampSettings.normalizationLevel, 1);
  });

  testWidgets('replacement controls show saved state and persist Quiet without overflow', (tester) async {
    await tester.runAsync(() async {
      final box = await Hive.openBox<FinampSettings>('FinampSettings');
      await box.put('FinampSettings', _settings());
    });
    tester.view.physicalSize = const Size(320, 950);
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
          home: const VolumeNormalizationSettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Normal (-14 LUFS)'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.text('Quiet (-19 LUFS)'));
      await Hive.box<FinampSettings>('FinampSettings').flush();
    });
    await tester.pumpAndSettle();
    expect(FinampSettingsHelper.finampSettings.normalizationLevel, 0);
    expect(tester.takeException(), isNull);
    await tester.runAsync(() async {
      await tester.tap(find.byType(SwitchListTile));
      await Hive.box<FinampSettings>('FinampSettings').flush();
    });
    await tester.pumpAndSettle();
    expect(FinampSettingsHelper.finampSettings.volumeNormalizationActive, false);
    expect(tester.widget<RadioListTile<int>>(find.byType(RadioListTile<int>).first).enabled, false);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
