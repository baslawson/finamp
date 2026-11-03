import 'package:finamp/services/loudness_normalization.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Normal attenuates loud songs to -14 LUFS', () {
    expect(
      normalizationGain(level: LoudnessLevel.normal, measurement: const LoudnessMeasurement(lufs: -8, truePeak: -0.2)),
      -6,
    );
  });
  test('Normal and Quiet cap boosts by true peak headroom', () {
    const measurement = LoudnessMeasurement(lufs: -26, truePeak: -5);
    expect(normalizationGain(level: LoudnessLevel.normal, measurement: measurement), 4);
    expect(normalizationGain(level: LoudnessLevel.quiet, measurement: measurement), 4);
    expect(normalizationGain(level: LoudnessLevel.loud, measurement: measurement), 15);
  });
  test('quiet mode preserves dynamics at its lower target', () {
    expect(
      normalizationGain(level: LoudnessLevel.quiet, measurement: const LoudnessMeasurement(lufs: -12, truePeak: -2)),
      -7,
    );
  });
  test('album selection keeps a shared gain while playlists use the track', () {
    const measurement = LoudnessMeasurement(lufs: -22, truePeak: -12, albumLufs: -16, albumTruePeak: -2);
    expect(normalizationGain(level: LoudnessLevel.normal, measurement: measurement, album: true), 1);
    expect(normalizationGain(level: LoudnessLevel.normal, measurement: measurement), 8);
  });
  test('missing album measurement preserves album balance with a common fallback', () {
    const measurement = LoudnessMeasurement(lufs: -18, truePeak: -8);
    expect(normalizationGain(level: LoudnessLevel.normal, measurement: measurement, album: true), -1);
    expect(normalizationGain(level: LoudnessLevel.normal, measurement: measurement, album: true, legacyGain: -3), -3);
  });
  test('unknown ReplayGain reference never invents LUFS or boosts', () {
    expect(normalizationGain(level: LoudnessLevel.loud, legacyGain: 9), 0);
    expect(normalizationGain(level: LoudnessLevel.normal, legacyGain: -6), -6);
    expect(normalizationGain(level: LoudnessLevel.normal), -1);
    expect(normalizationGain(level: LoudnessLevel.loud, legacyGain: double.nan), 0);
  });
  test('EQ headroom applies to both measured and fallback gain', () {
    expect(
      normalizationGain(
        level: LoudnessLevel.normal,
        headroomDb: 5,
        measurement: const LoudnessMeasurement(lufs: -18, truePeak: -9),
      ),
      -1,
    );
    expect(normalizationGain(level: LoudnessLevel.normal, legacyGain: -2, headroomDb: 5), -7);
  });
  test('silence, invalid numbers and incompatible analysis versions are rejected', () {
    expect(LoudnessMeasurement.fromJson({'version': 1, 'lufs': 'bad data', 'truePeak': -1}), isNull);
    expect(LoudnessMeasurement.fromJson({'version': 1, 'lufs': double.negativeInfinity, 'truePeak': -10}), isNull);
    expect(LoudnessMeasurement.fromJson({'version': 1, 'lufs': -70.0, 'truePeak': -10}), isNull);
    expect(LoudnessMeasurement.fromJson({'version': 2, 'lufs': -12.0, 'truePeak': -1}), isNull);
    expect(
      normalizationGain(
        level: LoudnessLevel.loud,
        measurement: const LoudnessMeasurement(lufs: double.nan, truePeak: 0),
      ),
      0,
    );
    expect(LoudnessLevel.fromSetting(99), LoudnessLevel.normal);
    expect(LoudnessLevel.fromSetting(-1), LoudnessLevel.normal);
  });
}
