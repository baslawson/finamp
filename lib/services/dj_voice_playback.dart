import 'dart:async';

import 'package:just_audio/just_audio.dart';

/// Always restores music even if loading, playing, cancelling or stopping the separate voice player fails.
/// This deliberately owns no song queue, seek or skip operations.
Future<void> withDjDucking({
  required Future<void> Function() duck,
  required Future<void> Function() speak,
  required Future<void> Function() stopVoice,
  required Future<void> Function() restore,
}) async {
  try {
    await duck();
    await speak();
  } finally {
    try {
      await stopVoice();
    } finally {
      await restore();
    }
  }
}

/// Observe every way the voice player can finish, releasing both listeners even on failure.
Future<ProcessingState> waitForDjPlayback({
  required Stream<ProcessingState> states,
  required Stream<Object> errors,
  required Future<void> Function() play,
  required ProcessingState Function() currentState,
  required Duration timeout,
  Future<void>? cancelled,
}) async {
  final result = Completer<ProcessingState>();
  void complete(ProcessingState state) {
    if (!result.isCompleted) result.complete(state);
  }

  void fail(Object error, StackTrace stack) {
    if (!result.isCompleted) result.completeError(error, stack);
  }

  final stateSubscription = states.listen((state) {
    if (state == ProcessingState.completed || state == ProcessingState.idle) complete(state);
  }, onError: fail);
  final errorSubscription = errors.listen((error) => fail(error, StackTrace.current), onError: fail);
  try {
    if (cancelled != null) unawaited(cancelled.then((_) => complete(ProcessingState.idle), onError: fail));
    unawaited(play().then((_) => complete(currentState()), onError: fail));
    return await result.future.timeout(timeout);
  } finally {
    await stateSubscription.cancel();
    await errorSubscription.cancel();
  }
}
