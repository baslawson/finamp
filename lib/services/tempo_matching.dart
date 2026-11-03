import 'dart:math';

/// A gentle incoming speed change, measured in seconds of the incoming song.
class TempoMatch {
  const TempoMatch({required this.initialSpeed, required this.rampLength, this.firstBeat = 0});

  final double initialSpeed;
  final double rampLength;
  final double firstBeat;
  double get rampEnd => firstBeat + rampLength;

  /// Treat half and double time as the same pulse. Only match within six percent.
  static double? ratio(double? outgoingBpm, double? incomingBpm) {
    if (outgoingBpm == null ||
        incomingBpm == null ||
        !outgoingBpm.isFinite ||
        !incomingBpm.isFinite ||
        outgoingBpm <= 0 ||
        incomingBpm <= 0) {
      return null;
    }
    final tempos = [incomingBpm / 2, incomingBpm, incomingBpm * 2]
      ..sort((a, b) => (a / outgoingBpm - 1).abs().compareTo((b / outgoingBpm - 1).abs()));
    final relative = tempos.first / outgoingBpm;
    return (relative - 1).abs() <= 0.06 + 1e-9 ? 1 / relative : null;
  }

  double speedAt(double position) =>
      initialSpeed + (1 - initialSpeed) * ((position - firstBeat) / rampLength).clamp(0.0, 1.0);

  /// Integrate 1/speed, since beat cues use song time, not elapsed wall time.
  double elapsedAt(double position) {
    final lead = position.clamp(0.0, firstBeat) / initialSpeed;
    final inside = (position - firstBeat).clamp(0.0, rampLength);
    final change = 1 - initialSpeed;
    final elapsed = change.abs() < 1e-9
        ? inside
        : rampLength / change * log(speedAt(firstBeat + inside) / initialSpeed);
    return lead + elapsed + max(0, position - rampEnd);
  }

  /// Leave time to settle at normal speed before either player's hand-over.
  static TempoMatch? plan({
    required double? outgoingBpm,
    required double? incomingBpm,
    required double availableSeconds,
    double firstBeat = 0,
  }) {
    final speed = ratio(outgoingBpm, incomingBpm);
    if (speed == null ||
        (speed - 1).abs() < 1e-9 ||
        !firstBeat.isFinite ||
        firstBeat < 0 ||
        !availableSeconds.isFinite) {
      return null;
    }
    // Four bars when possible, otherwise two. Short overlaps keep their usual fade.
    for (final beats in [16, 8]) {
      final length = beats * 60 / (outgoingBpm! / speed);
      final match = TempoMatch(initialSpeed: speed, rampLength: length, firstBeat: firstBeat);
      if (match.elapsedAt(match.rampEnd) + 0.75 <= availableSeconds) return match;
    }
    return null;
  }
}
