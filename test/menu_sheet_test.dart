import 'package:finamp/components/menu_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A phone (Pixel 7 Pro sized) with a status bar, where a menu taller than the screen used to cover it whole.
Future<void> _open(
  WidgetTester tester, {
  int rows = 60,
  ScrollController? controller,
  double statusBar = 40,
  Widget? first,
  Widget Function(Widget menu)? around,
}) async {
  tester.view.physicalSize = const Size(412, 892);
  tester.view.devicePixelRatio = 1;
  tester.view.padding = FakeViewPadding(top: statusBar);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showMenuSheet<void>(
              context: context,
              builder: (_) => (around ?? (menu) => menu)(
                SingleChildScrollView(
                  controller: controller,
                  child: Column(
                    children: [
                      ?first,
                      for (var i = 0; i < rows; i++) ListTile(title: Text('Row $i')),
                    ],
                  ),
                ),
              ),
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
  expect(find.text('Row 0'), findsOneWidget);
}

bool _shown(WidgetTester tester) => find.byType(BottomSheet).evaluate().isNotEmpty;

/// Scrolling that stops at the top (Android) and that bounces past it (iOS).
final _scrolling = TargetPlatformVariant(const {TargetPlatform.android, TargetPlatform.iOS});

void main() {
  testWidgets('a tall menu stays below the status bar and leaves room above it', (tester) async {
    await _open(tester);
    final top = tester.getTopLeft(find.byType(BottomSheet)).dy;
    expect(top, greaterThanOrEqualTo(892 * (1 - menuSheetMaxHeight) - 0.5));
  });

  testWidgets('a tall status bar is never covered', (tester) async {
    await _open(tester, statusBar: 150);
    expect(tester.getTopLeft(find.byType(BottomSheet)).dy, greaterThanOrEqualTo(150));
  });

  testWidgets('a short menu is as tall as its content', (tester) async {
    await _open(tester, rows: 2);
    expect(tester.getSize(find.byType(BottomSheet)).height, lessThan(892 / 2));
  });

  testWidgets('a tap above a tall menu closes it', (tester) async {
    await _open(tester);
    final top = tester.getTopLeft(find.byType(BottomSheet)).dy;
    await tester.tapAt(Offset(200, (top + 40) / 2));
    await tester.pumpAndSettle();
    expect(_shown(tester), false);
  });

  testWidgets('dragging the handle of a tall menu down closes it', (tester) async {
    await _open(tester);
    final sheet = find.byType(BottomSheet);
    await tester.dragFrom(Offset(tester.getCenter(sheet).dx, tester.getTopLeft(sheet).dy + 12), const Offset(0, 500));
    await tester.pumpAndSettle();
    expect(_shown(tester), false);
  });

  testWidgets('pulling the content down from the top closes a tall menu', (tester) async {
    await _open(tester);
    await tester.drag(find.text('Row 3'), const Offset(0, 200));
    await tester.pumpAndSettle();
    expect(_shown(tester), false);
  }, variant: _scrolling);

  testWidgets('two short pulls past the top in one drag, with scrolling between, leave it open', (tester) async {
    await _open(tester);
    final finger = await tester.startGesture(tester.getCenter(find.text('Row 3')));
    for (final step in [40.0, 40.0, -200.0, 40.0, 40.0, 40.0, 40.0, 40.0, 40.0]) {
      await finger.moveBy(Offset(0, step));
      await tester.pump();
    }
    await finger.up();
    await tester.pumpAndSettle();
    expect(_shown(tester), true);
  });

  testWidgets('a pull turned down while the menu may not close closes it once it may', (tester) async {
    final canClose = ValueNotifier(false);
    await _open(
      tester,
      around: (menu) => ValueListenableBuilder(
        valueListenable: canClose,
        builder: (_, can, _) => PopScope(canPop: can, child: menu),
      ),
    );
    await tester.drag(find.text('Row 3'), const Offset(0, 200));
    await tester.pumpAndSettle();
    expect(_shown(tester), true);
    canClose.value = true;
    await tester.pump();
    await tester.drag(find.text('Row 3'), const Offset(0, 200));
    await tester.pumpAndSettle();
    expect(_shown(tester), false);
  });

  testWidgets('room is left above a tall menu when the window gets smaller', (tester) async {
    await _open(tester);
    tester.view.physicalSize = const Size(412, 412);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.byType(BottomSheet)).dy, greaterThanOrEqualTo(412 * (1 - menuSheetMaxHeight) - 0.5));
  });

  testWidgets('a short pull, or scrolling back up to the top, leaves it open', (tester) async {
    final controller = ScrollController();
    await _open(tester, controller: controller);
    await tester.drag(find.text('Row 3'), const Offset(0, 30));
    await tester.pumpAndSettle();
    expect(_shown(tester), true);
    controller.jumpTo(300);
    await tester.pump();
    // Scrolls 250 of the 300 back: never past the top.
    await tester.drag(find.text('Row 8'), const Offset(0, 250));
    await tester.pumpAndSettle();
    expect(_shown(tester), true);
    expect(controller.offset, greaterThan(0));
    // Short pulls past the top don't add up with earlier ones.
    controller.jumpTo(0);
    await tester.pump();
    for (var pull = 0; pull < 3; pull++) {
      await tester.drag(find.text('Row 3'), const Offset(0, 50));
      await tester.pumpAndSettle();
    }
    expect(_shown(tester), true);
  }, variant: _scrolling);

  testWidgets('a fling that runs into the top, or a pull up at the bottom, leaves it open', (tester) async {
    final controller = ScrollController();
    await _open(tester, controller: controller);
    controller.jumpTo(300);
    await tester.pump();
    await tester.fling(find.text('Row 8'), const Offset(0, 200), 3000);
    await tester.pumpAndSettle();
    expect(controller.offset, 0);
    expect(_shown(tester), true);
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pump();
    await tester.drag(find.text('Row 55'), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(_shown(tester), true);
  }, variant: _scrolling);

  testWidgets('pulling a list inside the menu, down or sideways, leaves it open', (tester) async {
    await _open(
      tester,
      first: Column(
        children: [
          SizedBox(
            height: 150,
            child: ListView(children: [for (var i = 0; i < 20; i++) ListTile(title: Text('Inner $i'))]),
          ),
          SizedBox(
            height: 60,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [for (var i = 0; i < 20; i++) SizedBox(width: 120, child: Text('Side $i'))],
            ),
          ),
        ],
      ),
    );
    await tester.drag(find.text('Inner 1'), const Offset(0, 200));
    await tester.pumpAndSettle();
    expect(_shown(tester), true);
    await tester.drag(find.text('Side 0'), const Offset(300, 0));
    await tester.pumpAndSettle();
    expect(_shown(tester), true);
  });
}
