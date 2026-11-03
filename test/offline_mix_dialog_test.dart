import 'package:finamp/l10n/app_localizations.dart';
import 'package:finamp/screens/offline_mixes_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('download dialog closes safely, records a fixed limit and only includes DJ when selected', (
    tester,
  ) async {
    ({String name, int limit, bool includeDj})? result;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showDialog<({String name, int limit, bool includeDj})>(
                  context: context,
                  builder: (_) => const OfflineMixDownloadDialog(initialName: 'My mix'),
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value, isFalse);
    await tester.enterText(find.byType(TextField), 'Saved mix');
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Up to 50 songs').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Download mix'));
    await tester.pumpAndSettle();
    expect(result, (name: 'Saved mix', limit: 50, includeDj: true));
    expect(tester.takeException(), isNull);
  });
}
