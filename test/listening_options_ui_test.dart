import 'package:finamp/components/block_artist_dialog.dart';
import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/l10n/app_localizations.dart';
import 'package:finamp/menus/components/menuEntries/listening_choices_menu_entry.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/listening_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('song listening controls fit a narrow screen, save gapless, and show a temporary rest', (tester) async {
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    ListeningPreferences.reset();
    await ListeningPreferences.ensureLoaded();
    tester.view.physicalSize = const Size(320, 950);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final item = BaseItemDto(
      id: const BaseItemId('song'),
      name: 'Song with a long title to wrap',
      type: 'Audio',
      artists: ['Artist'],
    );
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(1.5)),
          child: child!,
        ),
        home: Scaffold(body: ListeningChoicesDialog(item: item)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byType(DropdownButton<SongTransition>));
    await tester.tap(find.byType(DropdownButton<SongTransition>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Gapless (no overlap)').last);
    await tester.pumpAndSettle();
    expect(ListeningPreferences.transition('song'), SongTransition.gapless);
    await tester.ensureVisible(find.text('7 days').first);
    await tester.tap(find.text('7 days').first);
    await tester.pumpAndSettle();
    expect(ListeningPreferences.rests.single.name, item.name);
    expect(tester.takeException(), isNull);
  });

  testWidgets('blocking: pick which artists, then how long; then unblock', (tester) async {
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    ListeningPreferences.reset();
    await tester.runAsync(ListeningPreferences.ensureLoaded);
    var artists = <BlockableArtist>[(name: 'Rihanna', id: 'r'), (name: 'Jay-Z', id: 'j')];
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        scaffoldMessengerKey: GlobalSnackbar.rawMaterialAppScaffoldKey,
        navigatorKey: GlobalSnackbar.rawMaterialAppNavigatorKey,
        home: Scaffold(
          body: Builder(
            builder: (context) =>
                TextButton(onPressed: () => showBlockArtistDialog(context, artists), child: const Text('open')),
          ),
        ),
      ),
    );
    Future<void> open() async {
      await tester.tap(find.text('open'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
    }

    Future<void> choose(String label) async {
      await tester.tap(find.text(label));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
    }

    await open();
    expect(find.text('Block artists'), findsOneWidget);
    await choose('Jay-Z');
    await choose('1 week');
    expect(find.text('Block artists'), findsNothing, reason: 'closed');
    expect(ListeningPreferences.rests.map((rest) => rest.name).toSet(), {'Rihanna', 'Jay-Z'});
    artists = [(name: 'Jay-Z', id: 'j')];
    await open();
    expect(find.textContaining('Blocked until'), findsOneWidget);
    await choose('Forever');
    expect(ListeningPreferences.blockOf((name: 'Jay-Z', id: 'j'))!.isForever, true);
    await open();
    expect(find.text('Blocked for good'), findsOneWidget);
    await choose('Unblock');
    expect(ListeningPreferences.blockOf((name: 'Jay-Z', id: 'j')), isNull);
    await tester.pumpAndSettle(const Duration(seconds: 10));
  });
}
