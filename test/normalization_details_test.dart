import 'package:finamp/components/normalization_details.dart';
import 'package:finamp/l10n/app_localizations.dart';
import 'package:finamp/services/normalization_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> show(WidgetTester tester, NormalizationSource source, {bool ready = false, bool active = true}) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: NormalizationDetailsContent(
            snapshot: NormalizationSnapshot(source: source, gainDb: -4.2, headroomDb: 0),
            active: active,
            analysisReady: ready,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('details distinguish actual track, album, fallback and next-playback analysis', (tester) async {
    await show(tester, NormalizationSource.track);
    expect(find.text('Track normalization'), findsOneWidget);
    expect(find.textContaining('-4.2'), findsOneWidget);
    await show(tester, NormalizationSource.album);
    expect(find.text('Album normalization'), findsOneWidget);
    await show(tester, NormalizationSource.fallback);
    expect(find.textContaining('Awaiting analysis'), findsOneWidget);
    await show(tester, NormalizationSource.fallback, ready: true);
    expect(find.text('Analysis ready for the next playback'), findsOneWidget);
    expect(find.textContaining('-4.2'), findsOneWidget);
    await show(tester, NormalizationSource.off);
    expect(find.text('Normalization is off'), findsOneWidget);
    expect(find.textContaining('Volume adjustment:'), findsNothing);
  });

  testWidgets('preview fits a narrow screen with large text', (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(2)),
          child: child!,
        ),
        home: const Scaffold(
          body: Center(
            child: AlertDialog(
              content: SingleChildScrollView(
                child: NormalizationDetailsContent(
                  snapshot: NormalizationSnapshot(source: NormalizationSource.fallback, gainDb: -1, headroomDb: 0),
                  active: false,
                  analysisReady: false,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Preview for your current settings'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
