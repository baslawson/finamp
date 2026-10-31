import 'package:finamp/services/lrclib_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test("parses plain LRC lines in time order", () {
    final lines = LrclibService.parseLrc("[00:12.50]Second\n[00:01.00]First\n[ar:Someone]\n");
    expect(lines.map((line) => line.text), ["First", "Second"]);
    expect(lines.first.start, 10000000);
    expect(lines.last.start, 125000000);
    expect(lines.first.cues, isNull);
  });

  test("repeats lines with several timestamps", () {
    final lines = LrclibService.parseLrc("[00:01.00][00:05.00]Chorus");
    expect(lines.map((line) => line.start), [10000000, 50000000]);
  });

  test("parses enhanced LRC word timings into cues", () {
    final lines = LrclibService.parseLrc("[00:01.00] <00:01.00>Hello <00:01.50>world");
    final line = lines.single;
    expect(line.text, "Hello world");
    expect(line.cues!.map((cue) => cue.position), [0, 6]);
    expect(line.cues!.first.endPosition, 6);
    expect(line.cues!.last.start, 15000000);
  });
}
