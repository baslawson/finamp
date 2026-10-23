/// Temporary practice controls. Loop seeks are single-flight and speed changes
/// are serialized so leaving always restores the previous playback settings.
class KaraokePractice {
  KaraokePractice({
    required this.seek,
    required this.setSpeed,
    required this.setPitch,
    required this.originalSpeed,
    required this.originalPitch,
  }) : speed = originalSpeed;
  final Future<void> Function(Duration) seek;
  final Future<void> Function(double) setSpeed, setPitch;
  final double originalSpeed, originalPitch;
  double speed;
  Duration? a, b;
  bool enabled = false;
  bool _seeking = false, _waitingForReset = false, _closed = false;
  int _generation = 0;
  Future<void> _operations = Future.value();
  Future<void>? _closing;
  void markA(Duration value) {
    if (value.isNegative) throw ArgumentError.value(value);
    a = value;
    b = null;
    enabled = false;
    _waitingForReset = false;
    _generation++;
  }

  void markB(Duration value) {
    if (a == null || value - a! < const Duration(seconds: 1)) throw ArgumentError.value(value);
    b = value;
    enabled = true;
    _waitingForReset = false;
    _generation++;
  }

  Future<bool> tick(Duration position, {required bool playing}) async {
    if (_closed || !enabled || !playing || a == null || b == null || _seeking) return false;
    if (position < b!) {
      _waitingForReset = false;
      return false;
    }
    if (_waitingForReset) return false;
    final generation = _generation;
    _seeking = true;
    _waitingForReset = true;
    try {
      await seek(a!);
      return generation == _generation && enabled && !_closed;
    } catch (_) {
      _waitingForReset = false;
      rethrow;
    } finally {
      _seeking = false;
    }
  }

  Future<void> changeSpeed(double value) {
    if (_closed) return Future.value();
    if (!value.isFinite || value < .5 || value > 2) throw ArgumentError.value(value);
    return _operations = _operations.catchError((Object _) {}).then((_) async {
      if (_closed) return;
      await setPitch(1);
      await setSpeed(value);
      if (!_closed) speed = value;
    });
  }

  Future<void> reset() {
    a = null;
    b = null;
    enabled = false;
    _waitingForReset = false;
    _generation++;
    speed = originalSpeed;
    return _operations = _operations.catchError((Object _) {}).then((_) async {
      await setSpeed(originalSpeed);
      await setPitch(originalPitch);
    });
  }

  Future<void> close() {
    _closed = true;
    return _closing ??= reset().catchError((Object error, StackTrace stack) {
      _closing = null;
      Error.throwWithStackTrace(error, stack);
    });
  }
}
