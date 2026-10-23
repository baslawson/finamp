import 'dart:async';
import 'dart:io';

import 'package:finamp/screens/dj_voice_settings_screen.dart';
import 'package:finamp/l10n/app_localizations.dart';
import 'package:finamp/main.dart' show FinampScrollBehavior;
import 'package:finamp/services/ai_service.dart';
import 'package:finamp/services/dj_voice_preferences.dart';
import 'package:finamp/services/dj_voice_settings.dart';
import 'package:finamp/services/dj_voice_studio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

class _PendingPaths extends PathProviderPlatform {
  final started = Completer<void>();
  final path = Completer<String?>();
  @override
  Future<String?> getTemporaryPath() {
    if (!started.isCompleted) started.complete();
    return path.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferencesAsyncPlatform? oldPrefs;
  late PathProviderPlatform oldPaths;
  late _PendingPaths paths;
  setUp(() async {
    oldPrefs = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    oldPaths = PathProviderPlatform.instance;
    paths = _PendingPaths();
    PathProviderPlatform.instance = paths;
    await AiService.setApiKey(AiProvider.gemini, 'display-test-key');
    await AiService.setApiKey(AiProvider.openai, 'display-test-key');
    await AiService.setSpeechSettings(AiSpeechSettings(primary: AiProvider.gemini, fallbacks: [AiProvider.openai]));
    await const DjVoiceStudioSettings(
      routes: {DjVoiceCharacter.aussieMale: DjVoiceRoute(AiProvider.gemini, backup: AiProvider.openai)},
    ).save();
    await DjVoicePreferences.saveGlobal(
      const DjVoiceProfile(
        settings: (
          mode: DjVoiceMode.always,
          every: 2,
          character: DjVoiceCharacter.aussieMale,
          aiVoice: true,
          volume: .7,
        ),
      ),
    );
  });
  tearDown(() {
    if (!paths.path.isCompleted) paths.path.complete(Directory.systemTemp.path);
    PathProviderPlatform.instance = oldPaths;
    SharedPreferencesAsyncPlatform.instance = oldPrefs;
  });
  testWidgets('studio restores its expanded state and comparison field after a provider change and remount', (
    tester,
  ) async {
    await const DjVoiceStudioSettings().save();
    final bucket = PageStorageBucket();
    Widget app(bool show) => MaterialApp(
      scrollBehavior: const FinampScrollBehavior(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: PageStorage(bucket: bucket, child: show ? const DjVoiceSettingsScreen() : const SizedBox.shrink()),
    );
    await tester.pumpWidget(app(true));
    await tester.pumpAndSettle();
    final section = find.byKey(const ValueKey('djSettingsStudio'));
    await tester.scrollUntilVisible(section, 350, scrollable: find.byType(Scrollable).first);
    final header = find.descendant(of: section, matching: find.byType(ListTile)).first;
    await tester.ensureVisible(header);
    await tester.tap(header);
    await tester.pumpAndSettle();
    final preferred = find.descendant(of: section, matching: find.byType(DropdownButtonFormField<String>)).first;
    await tester.ensureVisible(preferred);
    await tester.tap(preferred);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Gemini').last);
    await tester.pumpAndSettle();
    await tester.pumpWidget(app(false));
    await tester.pumpAndSettle();
    await tester.pumpWidget(app(true));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(section, 350, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final field = find.widgetWithText(TextField, 'Comparison text');
    expect(tester.getSize(field).height, lessThan(350));
    expect(find.byType(ErrorWidget), findsNothing);
  });
  testWidgets('station identity fields can be enabled inside the expanded settings section', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        scrollBehavior: const FinampScrollBehavior(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const DjVoiceSettingsScreen(),
      ),
    );
    await tester.pumpAndSettle();
    final section = find.byKey(const ValueKey('djSettingsShow'));
    await tester.scrollUntilVisible(section, 350);
    final header = find.descendant(of: section, matching: find.byType(ListTile)).first;
    await tester.ensureVisible(header);
    await tester.tap(header);
    await tester.pumpAndSettle();
    final identity = find.text('Station identity');
    await tester.ensureVisible(identity);
    await tester.pumpAndSettle();
    await tester.tap(identity);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    for (final label in [
      'Station name',
      'Opening line (optional)',
      'Jingle words (optional for an imported recording)',
    ]) {
      final field = find.widgetWithText(TextField, label);
      expect(tester.getSize(field).height, lessThan(350));
    }
    expect(find.byType(ErrorWidget), findsNothing);
  });
  for (final brightness in Brightness.values) {
    for (final provider in AiSpeechSettings.supported) {
      testWidgets('comparison stays bounded during a ${provider.displayName} audition in ${brightness.name} mode', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(412, 892);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetViewInsets);
        await tester.pumpWidget(
          MaterialApp(
            scrollBehavior: const FinampScrollBehavior(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: ThemeData(
              brightness: brightness,
              colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff876a1c), brightness: brightness),
            ),
            home: const DjVoiceSettingsScreen(),
          ),
        );
        await tester.pumpAndSettle();
        final section = find.byKey(const ValueKey('djSettingsStudio'));
        await tester.scrollUntilVisible(section, 350);
        final header = find.descendant(of: section, matching: find.byType(ListTile)).first;
        await tester.ensureVisible(header);
        await tester.tap(header);
        await tester.pumpAndSettle();
        final field = find.widgetWithText(TextField, 'Comparison text');
        await tester.ensureVisible(field);
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(field).controller!.text, isNotEmpty);
        expect(tester.getSize(field).height, lessThan(350));
        await tester.tap(field);
        await tester.enterText(field, 'Here is AC/DC with another great song.');
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        await tester.pumpAndSettle();
        final button = find.byKey(ValueKey('djAudition-${provider.name}'));
        await tester.ensureVisible(button);
        await tester.pumpAndSettle();
        await tester.tap(button);
        await tester.pump(const Duration(milliseconds: 100));
        expect(paths.started.isCompleted, isTrue);
        expect(tester.widget<TextField>(field).enabled, isFalse);
        expect(tester.getSize(field).height, lessThan(350));
        expect(find.byType(ErrorWidget), findsNothing);
        expect(tester.takeException(), isNull);
        // Cancel the pending audition before any API request or native playback.
        await tester.pumpWidget(const SizedBox.shrink());
        paths.path.complete(Directory.systemTemp.path);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.takeException(), isNull);
      });
    }
  }
}
