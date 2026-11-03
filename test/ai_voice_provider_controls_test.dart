import 'package:finamp/components/ai_voice_provider_controls.dart';
import 'package:finamp/l10n/app_localizations.dart';
import 'package:finamp/services/ai_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

Widget app({bool compact = false, double scale = 1}) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(scale)),
    child: Scaffold(
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: AiVoiceProviderControls(compact: compact),
        ),
      ),
    ),
  ),
);

void main() {
  late SharedPreferencesAsyncPlatform? original;
  setUp(() async {
    original = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    await AiService.setProvider(AiProvider.claude);
    await AiService.setApiKey(AiProvider.gemini, 'saved-secret');
    await AiService.setSpeechSettings(AiSpeechSettings(primary: AiProvider.gemini, fallbacks: [AiProvider.openai]));
  });
  tearDown(() => SharedPreferencesAsyncPlatform.instance = original);

  testWidgets('primary and fallback save independently of the text AI', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<AiProvider>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OpenAI').last);
    await tester.pumpAndSettle();
    expect((await AiService.getSpeechSettings()).order, [AiProvider.openai, AiProvider.gemini]);
    expect(await AiService.getProvider(), AiProvider.claude);
    final fallback = find.byKey(const ValueKey('voiceApiFallback-gemini'));
    await tester.ensureVisible(fallback);
    await tester.tap(fallback);
    await tester.pumpAndSettle();
    expect((await AiService.getSpeechSettings()).order, [AiProvider.openai]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('voice keys can be added without changing text AI or exposing stored secrets', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    final button = find.byKey(const ValueKey('voiceApiKey-openai'));
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.obscureText, isTrue);
    expect(field.controller!.text, isEmpty);
    await tester.enterText(find.byType(TextField), '  openai-voice-key  ');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(await AiService.getApiKey(AiProvider.openai), 'openai-voice-key');
    expect(await AiService.getProvider(), AiProvider.claude);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('openai-voice-key'), findsNothing);
  });

  testWidgets('removing a key preserves provider choices and never fills in the saved secret', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('voiceApiKey-gemini')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
    expect(find.text('saved-secret'), findsNothing);
    await tester.tap(find.text('Remove key'));
    await tester.pumpAndSettle();
    expect(await AiService.getApiKey(AiProvider.gemini), isNull);
    expect((await AiService.getSpeechSettings()).order, [AiProvider.gemini, AiProvider.openai]);
  });

  testWidgets('the boost switch persists and changing APIs preserves it', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    final boost = find.byKey(const ValueKey('voiceBoost'));
    expect(tester.widget<SwitchListTile>(boost).value, isTrue);
    await tester.tap(boost);
    await tester.pumpAndSettle();
    expect((await AiService.getSpeechSettings()).boost, isFalse);
    await tester.ensureVisible(find.byType(DropdownButtonFormField<AiProvider>));
    await tester.tap(find.byType(DropdownButtonFormField<AiProvider>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OpenAI').last);
    await tester.pumpAndSettle();
    expect((await AiService.getSpeechSettings()).boost, isFalse);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(boost).value, isFalse);
  });

  testWidgets('the quick panel supports large text on a narrow phone and shows the last voice API', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(app(compact: true, scale: 1.6));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Voice API'));
    await tester.pumpAndSettle();
    expect(find.byType(DropdownButtonFormField<AiProvider>), findsOneWidget);
    AiService.lastSpeechProvider.value = AiProvider.openai;
    await tester.pumpAndSettle();
    expect(find.text('Last voice API: OpenAI'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
