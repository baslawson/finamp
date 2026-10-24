import 'package:finamp/components/harmonic_mixing_switch.dart';
import 'package:finamp/l10n/app_localizations.dart';
import 'package:finamp/services/radio_tuning.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  late SharedPreferencesAsyncPlatform? previous;
  setUp(() {
    previous = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    HarmonicMixing.strength.value = HarmonicMixing.defaultStrength;
  });
  tearDown(() {
    SharedPreferencesAsyncPlatform.instance = previous;
    HarmonicMixing.strength.value = HarmonicMixing.defaultStrength;
  });

  Widget app(Widget child) => MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: child),
  );

  testWidgets('shows the strength as a badge and saves it when let go', (tester) async {
    int? ended;
    await tester.pumpWidget(app(HarmonicStrengthSlider(onChangeEnd: (value) => ended = value)));
    expect(find.text('Harmonic strength'), findsOneWidget);
    expect(find.text('75%'), findsOneWidget);

    await tester.drag(find.byType(Slider), const Offset(2000, 0));
    await tester.pumpAndSettle();
    expect(HarmonicMixing.strength.value, 100);
    expect(find.text('100%'), findsWidgets);
    expect(ended, 100);
    expect(await SharedPreferencesAsync().getInt('harmonicMixingStrength'), 100);
  });

  testWidgets('every slider follows a change made in another', (tester) async {
    await tester.pumpWidget(app(const Column(children: [HarmonicStrengthSlider(), HarmonicStrengthSlider()])));
    HarmonicMixing.strength.value = 30;
    await tester.pump();
    expect(find.text('30%'), findsNWidgets(2));
  });
}
