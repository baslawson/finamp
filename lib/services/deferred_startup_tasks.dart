import 'dart:async';

import 'package:flutter/widgets.dart';

/// Optional maintenance starts after the first frame, yielding between tasks.
/// A background launch without a frame still starts it after a short delay.
class DeferredStartupTasks {
  DeferredStartupTasks({required this.onError});
  final void Function(String name, Object error, StackTrace stack) onError;
  final _tasks = <(String, Future<void> Function())>[];
  bool _scheduled = false, _started = false;

  void add(String name, Future<void> Function() task) {
    assert(!_started);
    _tasks.add((name, task));
  }

  void schedule({void Function(VoidCallback)? afterFrame}) {
    if (_scheduled) return;
    _scheduled = true;
    Timer? fallback;
    void begin() {
      if (_started) return;
      _started = true;
      fallback?.cancel();
      unawaited(_run());
    }

    fallback = Timer(const Duration(seconds: 2), begin);
    if (afterFrame != null) {
      afterFrame(begin);
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => begin());
    }
  }

  Future<void> _run() async {
    final tasks = List.of(_tasks);
    _tasks.clear();
    for (final (name, task) in tasks) {
      await Future<void>.delayed(Duration.zero);
      try {
        await task();
      } catch (error, stack) {
        onError(name, error, stack);
      }
    }
  }
}
