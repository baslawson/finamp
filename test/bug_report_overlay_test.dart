import 'package:finamp/components/bug_report_overlay.dart';
import 'package:finamp/services/report_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() => ReportService.bugButton.value = true);
  tearDown(() => ReportService.bugButton.value = false);

  testWidgets("the bug button stays under the finger while it's dragged", (tester) async {
    await tester.pumpWidget(const MaterialApp(home: BugReportOverlay(child: SizedBox.expand())));
    final button = find.byIcon(TablerIcons.bug);
    final start = tester.getCenter(button);
    final finger = await tester.startGesture(start);
    for (var step = 0; step < 10; step++) {
      await finger.moveBy(const Offset(-12, -8));
      await tester.pump();
    }
    expect(tester.getCenter(button), start + const Offset(-120, -80));
    await finger.up();
  });

  testWidgets("the bug button stops at the edge of the screen", (tester) async {
    await tester.pumpWidget(const MaterialApp(home: BugReportOverlay(child: SizedBox.expand())));
    final button = find.byIcon(TablerIcons.bug);
    await tester.drag(button, const Offset(400, 400));
    await tester.pump();
    final screen = tester.getSize(find.byType(MaterialApp));
    final box = tester.getRect(find.byType(Material).last);
    expect(box.right, lessThanOrEqualTo(screen.width));
    expect(box.bottom, lessThanOrEqualTo(screen.height));
  });
}
