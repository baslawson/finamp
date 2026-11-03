/// A single elapsed-time budget shared by discovery, attempts and retries.
class OperationDeadline {
  OperationDeadline(this.timeout) : _clock = Stopwatch()..start();
  final Duration timeout;
  final Stopwatch _clock;
  Duration get remaining {
    final value = timeout - _clock.elapsed;
    return value.isNegative ? Duration.zero : value;
  }

  bool get expired => remaining == Duration.zero;
  Duration cap(Duration maximum) {
    final left = remaining;
    return left < maximum ? left : maximum;
  }
}
