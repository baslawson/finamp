import 'dart:io';

import 'package:finamp/components/fun_heading.dart';
import 'package:finamp/hive_registrar.g.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/locale_adapter.dart';
import 'package:finamp/models/theme_mode_adapter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/adapters.dart';

void main() {
  test("headings get the display font and body text keeps the normal one", () {
    final theme = withBoldHeadings(ThemeData(brightness: Brightness.dark));
    expect(theme.textTheme.headlineSmall?.fontFamily, headingFontFamily);
    expect(theme.textTheme.titleLarge?.fontFamily, headingFontFamily);
    expect(theme.textTheme.titleLarge?.fontWeight, FontWeight.w800);
    expect(theme.textTheme.bodyMedium?.fontFamily, isNot(headingFontFamily));
    expect(theme.textTheme.titleMedium?.fontFamily, isNot(headingFontFamily));
    // Colours still come from the theme.
    expect(theme.textTheme.titleLarge?.color, ThemeData(brightness: Brightness.dark).textTheme.titleLarge?.color);
  });

  Widget app(Widget child, {bool highContrast = false, double textScale = 1.0}) => MaterialApp(
    theme: withBoldHeadings(ThemeData()),
    home: MediaQuery(
      data: MediaQueryData(highContrast: highContrast, textScaler: TextScaler.linear(textScale)),
      child: Scaffold(body: SizedBox(width: 280, child: child)),
    ),
  );

  testWidgets("a title uses the accent gradient, and plain colours in high contrast", (tester) async {
    await tester.pumpWidget(app(const GradientTitle("Smart Shuffle", icon: Icons.shuffle)));
    await tester.pumpAndSettle();
    expect(find.text("Smart Shuffle"), findsOneWidget);
    expect(find.byType(ShaderMask), findsOneWidget);

    await tester.pumpWidget(app(const GradientTitle("Smart Shuffle", icon: Icons.shuffle), highContrast: true));
    await tester.pumpAndSettle();
    expect(find.byType(ShaderMask), findsNothing);
  });

  testWidgets("a long title fits a narrow screen with larger text", (tester) async {
    await tester.pumpWidget(
      app(const GradientTitle("A very long playlist name that will not fit", icon: Icons.headphones), textScale: 2.0),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets("the entrance is skipped with reduced motion", (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: const HeadingEntrance(child: Text("Title")),
        ),
      ),
    );
    expect(find.byType(TweenAnimationBuilder<double>), findsNothing);
  });

  group("with the app's settings", () {
    late Directory directory;
    setUpAll(() {
      Hive.registerAdapters();
      Hive.registerAdapter(ThemeModeAdapter());
      Hive.registerAdapter(ColorAdapter());
      Hive.registerAdapter(LocaleAdapter());
    });
    setUp(() async {
      directory = await Directory.systemTemp.createTemp('finamp-heading-');
      Hive.init(directory.path);
    });
    tearDown(() async {
      await Hive.close();
      await directory.delete(recursive: true);
    });

    testWidgets("titles already on screen follow the high contrast setting as it changes", (tester) async {
      final settings = FinampSettings(
        downloadLocations: [],
        downloadLocationsMap: {},
        tabSortBy: {},
        tabSortOrder: {},
        homeScreenConfiguration: const FinampHomeScreenConfiguration(actions: [], sections: []),
        gridImageSize: 130,
        homeScreenImageSize: 90,
        deviceId: 'test',
      );
      final box = (await tester.runAsync(() => Hive.openBox<FinampSettings>('FinampSettings')))!;
      await tester.runAsync(() => box.put('FinampSettings', settings));

      await tester.pumpWidget(app(const GradientTitle("Ai DJ", icon: Icons.headphones)));
      await tester.pumpAndSettle();
      expect(find.byType(ShaderMask), findsOneWidget);

      await tester.runAsync(() => box.put('FinampSettings', settings..useHighContrastColors = true));
      await tester.pumpAndSettle();
      expect(find.byType(ShaderMask), findsNothing);

      await tester.runAsync(() => box.put('FinampSettings', settings..useHighContrastColors = false));
      await tester.pumpAndSettle();
      expect(find.byType(ShaderMask), findsOneWidget);
    });
  });
}
