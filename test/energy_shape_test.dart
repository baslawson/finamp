import 'package:finamp/services/analyzer_service.dart';
import 'package:finamp/services/dj_transition_service.dart';
import 'package:finamp/services/dj_voice_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Songs named by their intensity, in a jumbled order.
  final songs = [0.5, 0.9, 0.1, 0.7, 0.3, 0.8, 0.2, 0.6, 0.4];
  List<double> shaped(EnergyShape shape) => DjTransitionService.shapeOrder(songs, (song) => song, shape);

  test("a build-up goes from calm to intense, a wind-down the other way", () {
    expect(shaped(EnergyShape.build), [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9]);
    expect(shaped(EnergyShape.windDown), [0.9, 0.8, 0.7, 0.6, 0.5, 0.4, 0.3, 0.2, 0.1]);
  });

  test("a peak rises to its high point about two thirds in, then eases off", () {
    final order = shaped(EnergyShape.peak);
    final top = order.indexOf(0.9);
    expect(top, inInclusiveRange(5, 6));
    for (var i = 1; i <= top; i++) {
      expect(order[i], greaterThan(order[i - 1]));
    }
    for (var i = top + 1; i < order.length; i++) {
      expect(order[i], lessThan(order[i - 1]));
    }
    // Easing off, not crashing: the end is livelier than the start.
    expect(order.last, greaterThan(order.first));
  });

  test("steady keeps neighbouring songs close in energy", () {
    final order = shaped(EnergyShape.steady);
    expect(order.toSet(), songs.toSet());
    final jumps = [for (var i = 1; i < order.length; i++) (order[i] - order[i - 1]).abs()];
    expect(jumps.reduce((a, b) => a > b ? a : b), lessThanOrEqualTo(0.2 + 1e-9));
    expect(order.first, 0.5);
  });

  test("free and short mixes keep their order; unmeasured songs count as middling", () {
    expect(shaped(EnergyShape.free), songs);
    expect(DjTransitionService.shapeOrder([0.9, 0.1], (song) => song, EnergyShape.build), [0.9, 0.1]);
    final withUnknown = DjTransitionService.shapeOrder<double?>(
      [0.9, null, 0.1, 0.4],
      (song) => song,
      EnergyShape.build,
    );
    expect(withUnknown.first, 0.1);
    expect(withUnknown.last, 0.9);
    expect(withUnknown, contains(null));
  });

  group("what the DJ may say about the change of songs", () {
    test("same or neighbouring keys", () {
      const a = TrackAnalysis(camelot: "8A", key: "A minor", bpm: 120);
      expect(
        DjVoiceService.soundNote(a, const TrackAnalysis(camelot: "8A", key: "A minor", bpm: 150)),
        contains("both songs are in A minor"),
      );
      expect(
        DjVoiceService.soundNote(a, const TrackAnalysis(camelot: "9A", key: "E minor")),
        contains("right next to"),
      );
    });

    test("big tempo changes, but not half or double time", () {
      const slow = TrackAnalysis(beatBpm: 90);
      expect(DjVoiceService.soundNote(slow, const TrackAnalysis(beatBpm: 128)), contains("jumps from about 90 to 128"));
      expect(DjVoiceService.soundNote(const TrackAnalysis(bpm: 140), slow), contains("drops from about 140 to 90"));
      expect(DjVoiceService.soundNote(slow, const TrackAnalysis(beatBpm: 180)), isNull);
    });

    test("energy changes, and nothing to say otherwise", () {
      expect(
        DjVoiceService.soundNote(const TrackAnalysis(intensity: 0.2), const TrackAnalysis(intensity: 0.8)),
        "the energy lifts a lot",
      );
      expect(
        DjVoiceService.soundNote(
          const TrackAnalysis(intensity: 0.5, bpm: 100),
          const TrackAnalysis(intensity: 0.6, bpm: 110),
        ),
        isNull,
      );
      expect(DjVoiceService.soundNote(null, const TrackAnalysis(intensity: 0.8)), isNull);
    });
  });
}
