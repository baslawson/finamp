import 'dart:math';

/// Select one interval for each announcement, rather than rerolling on playback
/// ticks. The fixed preference stays available when random timing is switched off.
class DjAnnouncementCadence {
  DjAnnouncementCadence({Random? random}) : _random = random ?? Random();
  final Random _random;
  bool _randomTiming = false;
  int _fixedEvery = 2;
  int? _target;

  void configure({required bool randomTiming, required int fixedEvery, bool reset = false}) {
    if (reset || randomTiming != _randomTiming) _target = null;
    _randomTiming = randomTiming;
    _fixedEvery = fixedEvery.clamp(1, 10);
  }

  int get every => _randomTiming ? _target ??= 2 + _random.nextInt(4) : _fixedEvery;

  void announced() => _target = null;
}
