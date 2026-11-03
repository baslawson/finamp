/// Runs a task one at a time. Asking for it while it runs doesn't start another but has it run once more when it
/// finishes, so the last ask is always the one that counts.
class RunAgain<T> {
  RunAgain(this._task);

  final Future<T> Function() _task;
  bool _running = false;
  bool _again = false;

  /// Whether the task is running now.
  bool get running => _running;

  /// Runs the task, or with it already running, has it run again afterwards and returns [whileRunning]. The run again
  /// is skipped when [wanted] says it no longer is.
  Future<T> call({required T whileRunning, bool Function()? wanted}) async {
    if (_running) {
      _again = true;
      return whileRunning;
    }
    _running = true;
    try {
      var result = await _task();
      while (_again) {
        _again = false;
        if (wanted?.call() ?? true) result = await _task();
      }
      return result;
    } finally {
      _running = false;
      _again = false;
    }
  }
}
