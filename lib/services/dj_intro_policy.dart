/// Opening lines belong to a track's beginning, never to resumed playback.
/// Short tracks get a proportionately smaller opening window.
class DjIntroPolicy {
  static const latestStart = Duration(seconds: 30);

  static bool allows({required Duration position, Duration? duration, Duration resumedAt = Duration.zero}) =>
      resumedAt <= Duration.zero &&
      position >= Duration.zero &&
      position < latestStart &&
      (duration == null || duration <= Duration.zero || position.inMicroseconds * 4 < duration.inMicroseconds);
}
