import 'package:finamp/components/dj_show_controls.dart';
import 'package:finamp/components/dj_voice_studio_controls.dart';
import 'package:finamp/l10n/app_localizations.dart';
import 'package:finamp/services/ai_service.dart';
import 'package:finamp/services/dj_voice_service.dart';
import 'package:finamp/services/dj_voice_studio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

Widget app(Widget child, {double scale = 1}) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(scale)),
    child: Scaffold(
      body: SingleChildScrollView(
        child: Padding(padding: const EdgeInsets.all(16), child: child),
      ),
    ),
  ),
);
void main() {
  late SharedPreferencesAsyncPlatform? oldPrefs;
  setUp(() async {
    oldPrefs = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    await AiService.setSpeechSettings(AiSpeechSettings(primary: AiProvider.gemini, fallbacks: [AiProvider.openai]));
  });
  tearDown(() => SharedPreferencesAsyncPlatform.instance = oldPrefs);
  const profile = DjVoiceProfile(
    settings: (mode: DjVoiceMode.always, every: 4, character: DjVoiceCharacter.aussieMale, aiVoice: true, volume: .7),
  );
  testWidgets('saving one character override leaves global routing and other characters alone', (tester) async {
    await tester.pumpWidget(app(DjVoiceStudioControls(profile: profile, characterName: (v) => v.name)));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('OpenAI').last);
    await tester.pumpAndSettle();
    final studio = await DjVoiceStudioSettings.load();
    expect(studio.routes[DjVoiceCharacter.aussieMale]!.primary, AiProvider.openai);
    expect(studio.routes[DjVoiceCharacter.aussieMale]!.backup, AiProvider.gemini);
    expect((await AiService.getSpeechSettings()).primary, AiProvider.gemini);
    final settings = profile.settings;
    await tester.pumpWidget(
      app(
        DjVoiceStudioControls(
          characterName: (v) => v.name,
          profile: profile.copyWith(
            settings: (
              mode: settings.mode,
              every: settings.every,
              character: DjVoiceCharacter.aussieFemale,
              aiVoice: true,
              volume: settings.volume,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Use default'), findsOneWidget);
    expect((await DjVoiceStudioSettings.load()).routes.length, 1);
    expect(tester.takeException(), isNull);
  });
  testWidgets('a pronunciation can be added and removed without changing the provider', (tester) async {
    await tester.pumpWidget(app(DjVoiceStudioControls(profile: profile, characterName: (v) => v.name)));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('djAddPronunciation')));
    await tester.tap(find.byKey(const ValueKey('djAddPronunciation')));
    await tester.pumpAndSettle();
    final fields = find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField));
    await tester.enterText(fields.first, 'AC/DC');
    await tester.enterText(fields.last, 'ay see dee see');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect((await DjVoiceStudioSettings.load()).spokenText('AC/DC'), 'ay see dee see');
    final remove = find.byIcon(Icons.delete_outline);
    await tester.ensureVisible(remove);
    await tester.tap(remove);
    await tester.pumpAndSettle();
    expect((await DjVoiceStudioSettings.load()).pronunciations, isEmpty);
    expect((await AiService.getSpeechSettings()).primary, AiProvider.gemini);
    expect(tester.takeException(), isNull);
  });
  testWidgets('show switches and frequency preserve existing playback controls and save on release', (tester) async {
    var current = profile;
    Widget controls() => StatefulBuilder(
      builder: (context, setState) => DjShowControls(
        profile: current,
        characterName: (v) => v.name,
        onChanged: (value) async {
          setState(() => current = value);
        },
      ),
    );
    await tester.pumpWidget(app(controls()));
    await tester.tap(find.text('Two-host mode'));
    await tester.pumpAndSettle();
    expect(current.show.duoChance, 25);
    final slider = tester.widget<Slider>(find.byKey(const ValueKey('djDuoChance')));
    slider.onChanged!(55);
    await tester.pump();
    expect(current.show.duoChance, 25);
    slider.onChangeEnd!(55);
    await tester.pumpAndSettle();
    expect(current.show.duoChance, 55);
    expect(current.settings, profile.settings);
    await tester.ensureVisible(find.text('Station identity'));
    await tester.tap(find.text('Station identity'));
    await tester.pumpAndSettle();
    final name = find.widgetWithText(TextField, 'Station name');
    await tester.enterText(name, 'Bas FM');
    final save = find.text('Save station identity');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(current.show.stationName, 'Bas FM');
    expect(current.show.duoChance, 55);
    expect(current.settings, profile.settings);
    expect(tester.takeException(), isNull);
  });
  testWidgets('studio and show controls fit narrow phones with large text', (tester) async {
    tester.view.physicalSize = const Size(320, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      app(
        Column(
          children: [
            DjVoiceStudioControls(profile: profile, characterName: (v) => 'Australian radio host ${v.name}'),
            DjShowControls(
              profile: profile.copyWith(show: const DjShowSettings(duoChance: 25, identityEnabled: true)),
              characterName: (v) => v.name,
              onChanged: (_) async {},
            ),
          ],
        ),
        scale: 1.6,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('djAudition-gemini')), findsOneWidget);
    expect(find.byKey(const ValueKey('djAudition-openai')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
