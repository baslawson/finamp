import 'dart:math';

enum LoudnessLevel {
  quiet(-19),
  normal(-14),
  loud(-11);

  const LoudnessLevel(this.target);
  final double target;
  static LoudnessLevel fromSetting(int value) => value >= 0 && value < values.length ? values[value] : normal;
}

class LoudnessMeasurement {
  const LoudnessMeasurement({required this.lufs, required this.truePeak, this.albumLufs, this.albumTruePeak});
  final double lufs;
  final double truePeak;
  final double? albumLufs;
  final double? albumTruePeak;

  static LoudnessMeasurement? fromJson(Map<String, dynamic> json) {
    double? finite(String key) {
      final raw = json[key];
      final value = raw is num ? raw.toDouble() : null;
      return value != null && value.isFinite ? value : null;
    }

    final lufs = finite('lufs'), peak = finite('truePeak');
    if (json['version'] != 1 || lufs == null || peak == null || lufs <= -70 || lufs > 10 || peak > 20) return null;
    return LoudnessMeasurement(
      lufs: lufs,
      truePeak: peak,
      albumLufs: finite('albumLufs'),
      albumTruePeak: finite('albumTruePeak'),
    );
  }
}

/// Gain for a single full program. Normal/Quiet never compress to meet a target.
/// Legacy gain has an unknown reference/peak, so it is only used for attenuation.
double normalizationGain({
  required LoudnessLevel level,
  LoudnessMeasurement? measurement,
  bool album = false,
  double? legacyGain,
  double headroomDb = 0,
}) {
  final reserve = headroomDb.isFinite ? max(0.0, headroomDb) : 0.0;
  // Without a peak measurement, leave one dB of sample headroom in the modes
  // that preserve dynamics. Loud's limiter can handle the original peaks.
  final fallback =
      min(level == LoudnessLevel.loud ? 0.0 : -1.0, (legacyGain?.isFinite ?? false) ? legacyGain! : 0.0) - reserve;
  if (measurement == null) {
    return fallback;
  }
  final useAlbum = album && measurement.albumLufs != null && measurement.albumTruePeak != null;
  if (album && !useAlbum) {
    // Keep the album's original balance until its complete measurement exists.
    return fallback;
  }
  final lufs = useAlbum ? measurement.albumLufs! : measurement.lufs;
  final peak = useAlbum ? measurement.albumTruePeak! : measurement.truePeak;
  if (!lufs.isFinite || !peak.isFinite || lufs <= -70) return -reserve;
  final gain = (level.target - lufs).clamp(-60.0, 24.0);
  return (level == LoudnessLevel.loud ? gain : min(gain, -1.0 - peak)) - reserve;
}
