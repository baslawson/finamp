import 'dart:async';

import 'package:finamp/l10n/app_localizations.dart';
import 'package:finamp/menus/ai_dj_menu.dart';
import 'package:finamp/services/ai_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

final class _DelayedPrefs extends InMemorySharedPreferencesAsync {
  _DelayedPrefs() : super.empty();
  Completer<String?>? geminiRead;
  @override
  Future<String?> getString(String key, SharedPreferencesOptions options) {
    if (key == 'aiApiKey_gemini' && geminiRead != null) return geminiRead!.future;
    return super.getString(key, options);
  }
}

Widget _app({double scale = 1}) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: Scaffold(
    body: Builder(
      builder: (context) => TextButton(
        onPressed: () => showAiDjMenu(context: context),
        child: const Text('Open AI DJ'),
      ),
    ),
  ),
);

void main() {
  late SharedPreferencesAsyncPlatform? previous;
  late _DelayedPrefs prefs;
  setUp(() async {
    previous = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance = prefs = _DelayedPrefs();
    await SharedPreferencesAsync().setString('aiProvider', 'claude');
    await AiService.setApiKey(AiProvider.gemini, 'gemini-secret');
    await AiService.setSpeechSettings(AiSpeechSettings(primary: AiProvider.gemini));
  });
  tearDown(() => SharedPreferencesAsyncPlatform.instance = previous);

  Future<void> open(WidgetTester tester, {bool settings = false, double scale = 1}) async {
    await tester.pumpWidget(_app(scale: scale));
    await tester.tap(find.text('Open AI DJ'));
    await tester.pumpAndSettle();
    if (settings) {
      await tester.tap(find.byTooltip('AI settings'));
      await tester.pumpAndSettle();
    }
  }

  testWidgets('the mix menu shows Gemini and OpenAI even with a legacy Claude selection', (tester) async {
    await open(tester);
    expect(find.text('Requests and mixes: Gemini'), findsOneWidget);
    expect(find.text('Backup: OpenAI'), findsOneWidget);
    expect(await AiService.getProvider(), AiProvider.gemini);
  });

  testWidgets('backup controls save without changing voice settings', (tester) async {
    await open(tester, settings: true);
    final openai = find.byKey(const ValueKey('aiRequestFallback-openai'));
    expect(tester.widget<CheckboxListTile>(openai).value, true);
    expect(tester.widget<CheckboxListTile>(find.byKey(const ValueKey('aiRequestFallback-claude'))).value, false);
    await tester.ensureVisible(openai);
    await tester.tap(openai);
    final save = find.widgetWithText(FilledButton, 'Save');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect((await AiService.getTextSettings()).order, [AiProvider.gemini]);
    expect((await AiService.getSpeechSettings()).primary, AiProvider.gemini);
    expect(find.text('Backup: OpenAI'), findsNothing);
  });

  testWidgets('an OpenAI backup key can be saved without selecting OpenAI as primary', (tester) async {
    await open(tester, settings: true);
    final manage = find.byKey(const ValueKey('aiRequestKey-openai'));
    await tester.ensureVisible(manage);
    await tester.tap(manage);
    await tester.pumpAndSettle();
    final dialog = find.byType(AlertDialog);
    final field = find.descendant(of: dialog, matching: find.byType(TextField));
    expect(tester.widget<TextField>(field).obscureText, true);
    expect(tester.widget<TextField>(field).controller!.text, isEmpty);
    await tester.enterText(field, '  openai-secret  ');
    await tester.pump();
    await tester.tap(find.descendant(of: dialog, matching: find.widgetWithText(FilledButton, 'Save')));
    await tester.pumpAndSettle();
    expect(await AiService.getApiKey(AiProvider.openai), 'openai-secret');
    expect((await AiService.getTextSettings()).order, [AiProvider.gemini, AiProvider.openai]);
    expect(find.text('openai-secret'), findsNothing);
    expect(find.text('gemini-secret'), findsNothing);
  });

  testWidgets('a delayed key lookup cannot save the previously selected provider', (tester) async {
    await AiService.setProvider(AiProvider.claude);
    await AiService.setApiKey(AiProvider.claude, 'claude-secret');
    await open(tester, settings: true);
    final pending = Completer<String?>();
    prefs.geminiRead = pending;
    await tester.ensureVisible(find.text('Gemini'));
    await tester.tap(find.text('Gemini'));
    await tester.pump();
    expect(tester.widget<SegmentedButton<AiProvider>>(find.byType(SegmentedButton<AiProvider>)).selected, {
      AiProvider.gemini,
    });
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save')).onPressed, isNull);
    // A later selection must also win over a stale Gemini lookup.
    await tester.ensureVisible(find.text('OpenAI'));
    await tester.tap(find.text('OpenAI'));
    await tester.pumpAndSettle();
    pending.complete('gemini-secret');
    prefs.geminiRead = null;
    await tester.pumpAndSettle();
    expect(tester.widget<SegmentedButton<AiProvider>>(find.byType(SegmentedButton<AiProvider>)).selected, {
      AiProvider.openai,
    });
    await tester.ensureVisible(find.text('Gemini'));
    await tester.tap(find.text('Gemini'));
    await tester.pumpAndSettle();
    final save = find.widgetWithText(FilledButton, 'Save');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(await AiService.getProvider(), AiProvider.gemini);
    expect(tester.takeException(), isNull);
  });

  testWidgets('request settings fit a narrow screen with larger text', (tester) async {
    tester.view.physicalSize = const Size(360, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await open(tester, settings: true, scale: 1.5);
    expect(find.byKey(const ValueKey('aiRequestFallback-openai')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
