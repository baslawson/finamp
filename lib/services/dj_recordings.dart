import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

class DjAudioClip {
  const DjAudioClip(this.file, this.text);
  final File file;
  final String text;
}

/// Owns exactly the most recent spoken clip. Replay gets its own temporary copy
/// so a new automatic announcement cannot remove a file being replayed.
class DjReplayStore {
  final latest = ValueNotifier<String?>(null);
  File? _file;
  bool owns(File file) => _file?.path == file.path;

  void remember(DjAudioClip clip) {
    final previous = _file;
    _file = clip.file;
    latest.value = clip.text;
    if (previous != null && previous.path != clip.file.path) unawaited(discard(previous));
  }

  Future<DjAudioClip?> copyForReplay() async {
    final file = _file, text = latest.value;
    if (file == null || text == null) return null;
    try {
      final copy = await file.copy('${file.parent.path}/dj-replay-${const Uuid().v4()}.wav');
      if (_file != file) {
        unawaited(discard(copy));
        return null;
      }
      return DjAudioClip(copy, text);
    } on FileSystemException {
      return null;
    }
  }

  void clear() {
    final file = _file;
    _file = null;
    latest.value = null;
    if (file != null) unawaited(discard(file));
  }

  static Future<void> discard(File file) async {
    // Timing a freshly prepared clip can briefly hold a read handle on Windows.
    // Cancellation must still remove it once that read finishes.
    for (var attempt = 0; attempt < 6; attempt++) {
      try {
        if (await file.exists()) await file.delete();
        return;
      } on FileSystemException {
        if (attempt == 5) return;
        await Future<void>.delayed(Duration(milliseconds: 30 * (attempt + 1)));
      }
    }
  }
}
