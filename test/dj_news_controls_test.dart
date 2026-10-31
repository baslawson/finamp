import 'package:finamp/components/dj_news_controls.dart';
import 'package:finamp/l10n/app_localizations.dart';
import 'package:finamp/services/dj_news.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

/// Lets loading and saving finish; the controls never settle, as a chime preview may animate.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  late SharedPreferencesAsyncPlatform? previous;
  setUp(() async {
    previous = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    final prefs = SharedPreferencesAsync();
    await prefs.setString('djNewsMode', DjNewsMode.onTheHour.name);
    await prefs.setString('djNewsFeed', DjNewsFeed.custom.name);
    await prefs.setString('djNewsSecondFeed', DjNewsFeed.custom.name);
  });
  tearDown(() {
    DjNews.reset();
    SharedPreferencesAsyncPlatform.instance = previous;
  });

  for (final localFirst in [true, false]) {
    testWidgets('both feed addresses are kept, edited in either order (local first: $localFirst)', (tester) async {
      // Within the test's own time, so the saves the controls make aren't queued behind one made outside it.
      DjNews.reset();
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(body: SingleChildScrollView(child: DjNewsControls())),
        ),
      );
      await settle(tester);
      final main = find.widgetWithText(TextField, 'Feed address (RSS or Atom)');
      final local = find.widgetWithText(TextField, 'Local feed address (RSS or Atom)');
      final fields = localFirst
          ? [(local, 'https://local.example/rss'), (main, 'https://world.example/rss')]
          : [(main, 'https://world.example/rss'), (local, 'https://local.example/rss')];
      for (final (field, address) in fields) {
        await tester.ensureVisible(field);
        await tester.tap(field);
        await tester.pump();
        await tester.enterText(field, address);
      }
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester);
      final settings = await DjNews.settings();
      expect((settings.custom, settings.secondCustom), ('https://world.example/rss', 'https://local.example/rss'));
    });
  }
}
