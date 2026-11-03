import 'package:finamp/services/headphone_eq_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test("parses the AutoEQ index", () {
    final index = HeadphoneEqService.parseIndex(
      "# Index\n- [1MORE Aero (ANC Off)](./HypetheSonics/GRAS%20RA0045%20in-ear/1MORE%20Aero%20(ANC%20Off)) by HypetheSonics on GRAS RA0045\n"
      "- [Sony WH-1000XM5](./oratory1990/over-ear/Sony%20WH-1000XM5) by oratory1990\n",
    );
    expect(index.map((profile) => profile.name), ["1MORE Aero (ANC Off)", "Sony WH-1000XM5"]);
    expect(index.first.path, "HypetheSonics/GRAS RA0045 in-ear/1MORE Aero (ANC Off)");
    expect(index.first.source, "HypetheSonics");
    expect(index.last.source, "oratory1990");
    expect(HeadphoneEqService.search(index, "sony xm5").single.name, "Sony WH-1000XM5");
  });

  test("parses GraphicEQ files", () {
    expect(HeadphoneEqService.parseGraphicEq("GraphicEQ: 20 -0.3; 21 1.5; 22 -2"), [(20.0, -0.3), (21.0, 1.5), (22.0, -2.0)]);
  });

  test("fits a curve to device bands around 0 dB and clamps", () {
    final gains = HeadphoneEqService.bandGains(
      [(50, 4), (100, 4), (1000, 0), (10000, -30)],
      [(30, 60, 120), (500, 1000, 2000), (5000, 10000, 20000)],
      minDecibels: -15,
      maxDecibels: 15,
    );
    // Raw band averages are 4, 0, -30 with a mean of -26/3.
    expect(gains[0], closeTo(4 + 26 / 3, 0.001));
    expect(gains[1], closeTo(26 / 3, 0.001));
    expect(gains[2], -15);
  });
}
