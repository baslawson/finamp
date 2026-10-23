import 'dart:math';

import 'package:just_audio/just_audio.dart';

/// One encoded-data budget for music, the incoming song and local DJ clips.
/// Decoded PCM and the device output buffer are separate from this budget.
class PlaybackBufferPolicy {
  static const defaultBudgetBytes = 50 * 1024 * 1024;
  static const voiceBudgetBytes = 256 * 1024;
  static int nextBudget(int totalBytes) => (totalBytes ~/ 4).clamp(128 * 1024, 12 * 1024 * 1024);
  static int mainBudget(int totalBytes) => max(128 * 1024, totalBytes - nextBudget(totalBytes) - voiceBudgetBytes);

  static AudioLoadConfiguration incoming({int totalBytes = defaultBudgetBytes}) => AudioLoadConfiguration(
    androidLoadControl: AndroidLoadControl(
      minBufferDuration: const Duration(seconds: 4),
      maxBufferDuration: const Duration(seconds: 20),
      bufferForPlaybackDuration: const Duration(seconds: 1),
      bufferForPlaybackAfterRebufferDuration: const Duration(seconds: 2),
      targetBufferBytes: nextBudget(totalBytes),
    ),
    darwinLoadControl: const DarwinLoadControl(preferredForwardBufferDuration: Duration(seconds: 20)),
  );

  static const voice = AudioLoadConfiguration(
    androidLoadControl: AndroidLoadControl(
      minBufferDuration: Duration(milliseconds: 500),
      maxBufferDuration: Duration(seconds: 5),
      bufferForPlaybackDuration: Duration(milliseconds: 100),
      bufferForPlaybackAfterRebufferDuration: Duration(milliseconds: 250),
      targetBufferBytes: voiceBudgetBytes,
    ),
    darwinLoadControl: DarwinLoadControl(preferredForwardBufferDuration: Duration(seconds: 5)),
  );
}

/// Keep one preparation per upcoming item, moving earlier after slow loads.
class PreparationLead {
  PreparationLead({this.minimum = const Duration(seconds: 10), this.maximum = const Duration(seconds: 30)});
  final Duration minimum, maximum;
  double _loadingMs = 0;
  Duration get value =>
      Duration(milliseconds: (_loadingMs * 2 + 4000).round().clamp(minimum.inMilliseconds, maximum.inMilliseconds));
  void record(Duration elapsed) {
    final measured = elapsed.inMilliseconds.toDouble();
    // React immediately to a slow load, ease down after successful fast ones.
    _loadingMs = max(measured, _loadingMs * .8 + measured * .2);
  }
}
