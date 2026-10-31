/// Who asked the player to pause, read from the calls that led to it, for the log.
String pauseCause(StackTrace trace) {
  final frames = trace.toString().split('\n');
  // The system's calls come in through audio_service; the app calls the player directly.
  if (frames.any((frame) => frame.contains('package:audio_service/'))) {
    return frames.any((frame) => frame.contains('.click '))
        ? 'a media button (headset, Bluetooth device or car)'
        : 'the media controls (lock screen, notification, Bluetooth device, car or watch)';
  }
  for (final frame in frames) {
    final call = RegExp(r'^#\d+\s+(.+?) \(package:finamp/').firstMatch(frame)?.group(1);
    if (call == null || _passesOn.contains(call)) continue;
    return 'the app ($call)';
  }
  return 'unknown';
}

/// The player's own ways in to a pause, which only pass on someone else's request.
const _passesOn = {'MusicPlayerBackgroundTask.pause', 'MusicPlayerBackgroundTask.togglePlayback', 'pauseCause'};
