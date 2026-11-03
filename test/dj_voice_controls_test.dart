import 'package:finamp/components/dj_voice_controls.dart';
import 'package:finamp/l10n/app_localizations.dart';
import 'package:finamp/services/dj_voice_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const settings = (mode: DjVoiceMode.aiDjOnly, every: 2, character: DjVoiceCharacter.pirate, aiVoice: true, volume: 0.7);

Widget app(DjVoiceSettings settings, Future<void> Function(DjVoiceSettings) save, {double scale = 1}) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(scale)),
    child: Scaffold(
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: DjVoiceControls(settings: settings, onChanged: save),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('sliders save on release, retaining the character and AI voice selection', (tester) async {
    final saved = <DjVoiceSettings>[];
    await tester.pumpWidget(
      app(settings, (value) async {
        saved.add(value);
      }),
    );
    await tester.pumpAndSettle();
    final volume = find.byType(Slider).last;
    final rect = tester.getRect(volume);
    final gesture = await tester.startGesture(Offset(rect.left + 24 + (rect.width - 48) * 2 / 3, rect.center.dy));
    await gesture.moveBy(const Offset(-160, 0));
    await tester.pump();
    expect(saved, isEmpty);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(saved, hasLength(1));
    expect(saved.single.character, DjVoiceCharacter.pirate);
    expect(saved.single.aiVoice, isTrue);
    expect(saved.single.every, 2);
    expect(saved.single.volume, isNot(0.7));
  });

  testWidgets('turning the DJ off disables the frequency and volume sliders', (tester) async {
    final saved = <DjVoiceSettings>[];
    await tester.pumpWidget(
      app(settings, (value) async {
        saved.add(value);
      }),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Off'));
    await tester.pumpAndSettle();
    expect(saved.single.mode, DjVoiceMode.off);
    expect(tester.widgetList<Slider>(find.byType(Slider)).every((slider) => slider.onChanged == null), isTrue);
  });

  testWidgets('saved ten-song frequency and large text work on a narrow phone', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final lessOften = (mode: settings.mode, every: 10, character: settings.character, aiVoice: true, volume: 0.7);
    await tester.pumpWidget(app(lessOften, (_) async {}, scale: 1.6));
    await tester.pumpAndSettle();
    expect(find.byType(DropdownButtonFormField<DjVoiceMode>), findsOneWidget);
    expect(find.text('Talks every 10 songs'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
