import 'package:finamp/components/dj_voice_controls.dart';
import 'package:finamp/components/dj_voice_session_controls.dart';
import 'package:finamp/l10n/app_localizations.dart';
import 'package:finamp/menus/dj_voice_menu.dart';
import 'package:finamp/screens/dj_voice_settings_screen.dart';
import 'package:finamp/services/dj_voice_preferences.dart';
import 'package:finamp/services/dj_voice_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

Widget app(Widget home) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: home,
);

void main() {
  Future<void> toggleSection(WidgetTester tester, String id) async {
    tester.state<ScrollableState>(find.byType(Scrollable).first).position.jumpTo(0);
    await tester.pumpAndSettle();
    final section = find.byKey(ValueKey(id));
    await tester.scrollUntilVisible(section, 300, scrollable: find.byType(Scrollable).first);
    final header = find.descendant(of: section, matching: find.byType(ListTile)).first;
    await tester.ensureVisible(header);
    await tester.pumpAndSettle();
    await tester.tap(header);
    await tester.pumpAndSettle();
  }

  late SharedPreferencesAsyncPlatform? original;
  setUp(() async {
    original = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    await DjVoicePreferences.saveGlobal(
      const DjVoiceProfile(
        settings: (mode: DjVoiceMode.off, every: 4, character: DjVoiceCharacter.energetic, aiVoice: true, volume: .6),
      ),
    );
    await DjVoiceService.initialize();
  });
  tearDown(() async {
    await DjVoiceService.resumeDj();
    SharedPreferencesAsyncPlatform.instance = original;
  });

  testWidgets('a station can customise its DJ and return to the main defaults', (tester) async {
    await tester.pumpWidget(app(const DjVoiceSettingsScreen(stationId: 'station-a', stationName: 'Evening')));
    await tester.pumpAndSettle();
    expect(find.byType(DjVoiceProfileControls), findsNothing);
    await tester.tap(find.text('Use station DJ settings'));
    await tester.pumpAndSettle();
    await toggleSection(tester, 'djSettingsTiming');
    expect(find.byType(DjVoiceProfileControls), findsOneWidget);
    expect(find.text('Ai DJ mixes'), findsNothing);
    expect(find.text('On'), findsOneWidget);
    expect((await DjVoiceService.loadProfile(stationId: 'station-a')).settings.mode, DjVoiceMode.always);
    expect((await DjVoiceService.loadProfile()).settings.mode, DjVoiceMode.off);
    final length = find.byType(DropdownButtonFormField<DjAnnouncementLength>);
    await tester.ensureVisible(length);
    await tester.pumpAndSettle();
    await tester.tap(length);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Brief').last);
    await tester.pumpAndSettle();
    expect((await DjVoiceService.loadProfile(stationId: 'station-a')).length, DjAnnouncementLength.brief);
    await tester.scrollUntilVisible(
      find.text('Use station DJ settings'),
      -400,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Use station DJ settings'));
    await tester.pumpAndSettle();
    expect(await DjVoiceService.hasStationProfile('station-a'), isFalse);
    expect((await DjVoiceService.loadProfile(stationId: 'station-a')).length, DjAnnouncementLength.normal);
  });

  testWidgets('Random hides fixed frequency and switching it off restores the saved value', (tester) async {
    final profile = await DjVoiceService.loadProfile();
    final settings = profile.settings;
    await DjVoiceService.saveProfile(
      profile.copyWith(
        settings: (
          mode: settings.mode,
          every: 7,
          character: settings.character,
          aiVoice: settings.aiVoice,
          volume: settings.volume,
        ),
      ),
    );
    await tester.pumpWidget(app(const DjVoiceSettingsScreen()));
    await tester.pumpAndSettle();
    await toggleSection(tester, 'djSettingsTiming');
    final toggle = find.byKey(const ValueKey('djRandomTiming'));
    await tester.scrollUntilVisible(toggle, 300, scrollable: find.byType(Scrollable).first);
    expect(find.text('Talks every 7 songs'), findsOneWidget);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect((await DjVoiceService.loadProfile()).randomTiming, isTrue);
    expect((await DjVoiceService.loadProfile()).settings.every, 7);
    expect(find.byKey(const ValueKey('djVoiceEvery')), findsNothing);
    expect(find.text('Talks every 7 songs'), findsNothing);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect((await DjVoiceService.loadProfile()).randomTiming, isFalse);
    expect(find.text('Talks every 7 songs'), findsOneWidget);
    expect((await DjVoiceService.loadProfile()).settings.mode, settings.mode);
    expect(tester.takeException(), isNull);
  });

  testWidgets('music-under-DJ saves on release and car preset applies without changing the DJ', (tester) async {
    await tester.pumpWidget(app(const DjVoiceSettingsScreen()));
    await tester.pumpAndSettle();
    await toggleSection(tester, 'djSettingsLevels');
    final slider = find.byKey(const ValueKey('djMusicUnderVoice'));
    await tester.scrollUntilVisible(slider, 400, scrollable: find.byType(Scrollable).first);
    final control = tester.widget<Slider>(slider);
    control.onChanged!(.47);
    await tester.pump();
    expect((await DjVoiceService.loadProfile()).musicUnderVoice, .22);
    control.onChangeEnd!(.47);
    await tester.pumpAndSettle();
    expect((await DjVoiceService.loadProfile()).musicUnderVoice, .47);
    final original = (await DjVoiceService.loadProfile()).settings;
    await toggleSection(tester, 'djSettingsPresets');
    await tester.scrollUntilVisible(find.text('Car'), 200, scrollable: find.byType(Scrollable).first);
    await Scrollable.ensureVisible(tester.element(find.text('Car')), alignment: .5);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Car'));
    await tester.pumpAndSettle();
    final car = await DjVoiceService.loadProfile();
    expect(car.settings.volume, .9);
    expect(car.musicUnderVoice, .12);
    expect(car.length, DjAnnouncementLength.brief);
    expect(car.settings.mode, original.mode);
    expect(car.settings.character, original.character);
    expect(car.settings.every, original.every);
    expect(tester.takeException(), isNull);
  });

  testWidgets('favourite selection enables rotation and is saved with the selected voices', (tester) async {
    await tester.pumpWidget(app(const DjVoiceSettingsScreen()));
    await tester.pumpAndSettle();
    await toggleSection(tester, 'djSettingsFavorites');
    for (final name in ['Pirate captain', 'Movie trailer']) {
      final chip = find.widgetWithText(FilterChip, name);
      await tester.ensureVisible(chip);
      await tester.pumpAndSettle();
      await tester.tap(chip);
      await tester.pumpAndSettle();
    }
    await tester.scrollUntilVisible(find.text('Rotate favourite DJs'), -400, scrollable: find.byType(Scrollable).first);
    await Scrollable.ensureVisible(tester.element(find.text('Rotate favourite DJs')), alignment: .5);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rotate favourite DJs'));
    await tester.pumpAndSettle();
    final profile = await DjVoiceService.loadProfile();
    expect(profile.rotates, isTrue);
    expect(profile.favourites.toSet(), {DjVoiceCharacter.pirate, DjVoiceCharacter.trailer});
    await toggleSection(tester, 'djSettingsVoice');
    final single = find.widgetWithText(ChoiceChip, 'Chill');
    await tester.scrollUntilVisible(single, -400, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    await tester.tap(single);
    await tester.pumpAndSettle();
    final selected = await DjVoiceService.loadProfile();
    expect(selected.rotates, isFalse);
    expect(selected.settings.character, DjVoiceCharacter.chill);
    expect(selected.favourites.toSet(), profile.favourites.toSet());
  });

  testWidgets('co-host favourites are disabled and restored when co-host mode or character changes', (tester) async {
    final original = (await DjVoiceService.loadProfile()).copyWith(
      rotate: true,
      favourites: [DjVoiceCharacter.pirate, DjVoiceCharacter.trailer],
      show: const DjShowSettings(duoChance: 25, coHost: DjVoiceCharacter.pirate),
    );
    await DjVoiceService.saveProfile(original);
    await tester.pumpWidget(app(const DjVoiceSettingsScreen()));
    await tester.pumpAndSettle();
    await toggleSection(tester, 'djSettingsFavorites');
    FilterChip favourite(DjVoiceCharacter voice) =>
        tester.widget<FilterChip>(find.byKey(ValueKey('djFavourite-${voice.name}')));
    SwitchListTile rotation() =>
        tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, 'Rotate favourite DJs'));
    expect(favourite(DjVoiceCharacter.pirate).onSelected, isNull);
    expect(favourite(DjVoiceCharacter.pirate).selected, isFalse);
    expect(find.text('Pirate captain (co-host)'), findsOneWidget);
    expect(favourite(DjVoiceCharacter.trailer).onSelected, isNotNull);
    expect(favourite(DjVoiceCharacter.trailer).selected, isTrue);
    expect(rotation().onChanged, isNull);
    expect(rotation().value, isFalse);
    await tester.ensureVisible(find.byKey(const ValueKey('djFavourite-pirate')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('djFavourite-pirate')));
    await tester.pumpAndSettle();
    expect((await DjVoiceService.loadProfile()).favourites, original.favourites);
    await toggleSection(tester, 'djSettingsVoice');
    expect(tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Movie trailer')).selected, isTrue);
    await toggleSection(tester, 'djSettingsShow');
    final coHostMode = find.widgetWithText(SwitchListTile, 'Two-host mode');
    tester.widget<SwitchListTile>(coHostMode).onChanged!(false);
    await tester.pumpAndSettle();
    expect(favourite(DjVoiceCharacter.pirate).onSelected, isNotNull);
    expect(favourite(DjVoiceCharacter.pirate).selected, isTrue);
    expect(rotation().value, isTrue);
    expect(rotation().onChanged, isNotNull);
    tester.widget<SwitchListTile>(coHostMode).onChanged!(true);
    await tester.pumpAndSettle();
    expect(favourite(DjVoiceCharacter.pirate).onSelected, isNull);
    tester
        .widget<DropdownButtonFormField<DjVoiceCharacter>>(find.byType(DropdownButtonFormField<DjVoiceCharacter>))
        .onChanged!(DjVoiceCharacter.trailer);
    await tester.pumpAndSettle();
    expect(favourite(DjVoiceCharacter.pirate).onSelected, isNotNull);
    expect(favourite(DjVoiceCharacter.pirate).selected, isTrue);
    expect(favourite(DjVoiceCharacter.trailer).onSelected, isNull);
    expect(favourite(DjVoiceCharacter.trailer).selected, isFalse);
    final saved = await DjVoiceService.loadProfile();
    expect(saved.favourites, original.favourites);
    expect(saved.rotate, isTrue);
    expect(saved.show.coHost, DjVoiceCharacter.trailer);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a saved station reserves its own co-host and accepts other favourites', (tester) async {
    final global = await DjVoiceService.loadProfile();
    final station = global.copyWith(
      favourites: [DjVoiceCharacter.pirate, DjVoiceCharacter.trailer],
      show: const DjShowSettings(duoChance: 25, coHost: DjVoiceCharacter.pirate),
    );
    await DjVoiceService.saveProfile(station, stationId: 'station-duo');
    await tester.pumpWidget(app(const DjVoiceSettingsScreen(stationId: 'station-duo', stationName: 'Duo')));
    await tester.pumpAndSettle();
    await toggleSection(tester, 'djSettingsFavorites');
    expect(tester.widget<FilterChip>(find.byKey(const ValueKey('djFavourite-pirate'))).onSelected, isNull);
    final meditation = find.byKey(const ValueKey('djFavourite-meditation'));
    await tester.ensureVisible(meditation);
    await tester.pumpAndSettle();
    await tester.tap(meditation);
    await tester.pumpAndSettle();
    final saved = await DjVoiceService.loadProfile(stationId: 'station-duo');
    expect(saved.rotationFavourites, {DjVoiceCharacter.trailer, DjVoiceCharacter.meditation});
    expect(saved.favourites, contains(DjVoiceCharacter.pirate));
    expect((await DjVoiceService.loadProfile()).toJson(), global.toJson());
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings separate timing, voice APIs and volume without changing saved choices', (tester) async {
    final original = await DjVoiceService.loadProfile();
    await DjVoiceService.saveProfile(
      original.copyWith(
        settings: (
          mode: DjVoiceMode.always,
          every: 4,
          character: DjVoiceCharacter.energetic,
          aiVoice: true,
          volume: .6,
        ),
      ),
    );
    await tester.pumpWidget(app(const DjVoiceSettingsScreen()));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('djVoiceEvery')), findsNothing);
    await toggleSection(tester, 'djSettingsTiming');
    expect(find.byKey(const ValueKey('djVoiceEvery')), findsOneWidget);
    expect(find.byKey(const ValueKey('djVoiceVolume')), findsNothing);
    await toggleSection(tester, 'djSettingsTiming');
    await toggleSection(tester, 'djSettingsLevels');
    expect(find.byKey(const ValueKey('djVoiceEvery')), findsNothing);
    final volume = find.byKey(const ValueKey('djVoiceVolume'));
    await tester.ensureVisible(volume);
    tester.widget<Slider>(volume).onChangeEnd!(.8);
    await tester.pumpAndSettle();
    final edited = await DjVoiceService.loadProfile();
    expect(edited.settings.volume, .8);
    expect(edited.settings.every, 4);
    expect(edited.settings.character, DjVoiceCharacter.energetic);
    await toggleSection(tester, 'djSettingsApi');
    expect(find.byKey(const ValueKey('voiceBoost')), findsOneWidget);
    await toggleSection(tester, 'djSettingsLevels');
    expect(find.byKey(const ValueKey('djVoiceVolume')), findsNothing);
    await toggleSection(tester, 'djSettingsLevels');
    expect(tester.widget<Slider>(find.byKey(const ValueKey('djVoiceVolume'))).value, .8);
    expect(tester.takeException(), isNull);
  });

  testWidgets('quiet can be selected and resumed without editing the configured mode', (tester) async {
    await tester.pumpWidget(app(const Scaffold(body: DjVoiceSessionControls())));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Temporary quiet'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('15 minutes'));
    await tester.pumpAndSettle();
    expect(DjVoiceService.isQuiet, isTrue);
    expect(find.textContaining('DJ quiet until'), findsOneWidget);
    await tester.tap(find.text('Resume DJ'));
    await tester.pumpAndSettle();
    expect(DjVoiceService.isQuiet, isFalse);
    expect((await DjVoiceService.loadSettings()).mode, DjVoiceMode.off);
  });

  testWidgets('quick controls remain scrollable on a narrow phone with large text', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      app(
        Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.6)),
            child: Scaffold(
              body: TextButton(onPressed: () => showDjVoiceMenu(context), child: const Text('Open DJ')),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open DJ'));
    await tester.pumpAndSettle();
    expect(find.byType(DjVoiceProfileControls), findsOneWidget);
    expect(find.byType(SingleChildScrollView), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('grouped settings and voice API controls fit a narrow phone with large text', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.6)),
          child: child!,
        ),
        home: const DjVoiceSettingsScreen(),
      ),
    );
    await tester.pumpAndSettle();
    await toggleSection(tester, 'djSettingsApi');
    expect(find.byKey(const ValueKey('voiceBoost')), findsOneWidget);
    await toggleSection(tester, 'djSettingsTiming');
    expect(find.byKey(const ValueKey('djRandomTiming')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
