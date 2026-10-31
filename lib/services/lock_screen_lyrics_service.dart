import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/screens/karaoke_screen.dart';
import 'package:finamp/services/current_track_metadata_provider.dart';
import 'package:finamp/services/metadata_provider.dart';
import 'package:finamp/services/music_player_background_task.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Shows the lyric line being sung in a silent notification, so it can be read on the lock screen without unlocking.
/// Only for synced lyrics; it disappears when the music pauses.
class LockScreenLyricsService {
  LockScreenLyricsService._();

  static final _logger = Logger("LockScreenLyricsService");
  static const _channel = MethodChannel("com.unicornsonlsd.finamp/notify");
  static const _enabledKey = "lockScreenLyrics";

  static bool _enabled = false;
  static bool get enabled => _enabled;

  static ProviderSubscription<AsyncValue<MetadataProvider?>>? _lyricsSubscription;
  static StreamSubscription<PlaybackState>? _playingSubscription;
  static Timer? _timer;
  static List<LyricLine> _lines = const [];
  static String _title = "";
  static int _shownIndex = -2;

  static Future<void> initialize() async {
    if (!Platform.isAndroid) return;
    _enabled = await SharedPreferencesAsync().getBool(_enabledKey) ?? false;
    if (_enabled) _start();
  }

  /// Turns it on or off. Returns false when notifications aren't allowed.
  static Future<bool> setEnabled(bool enabled) async {
    if (enabled && !(await Permission.notification.request()).isGranted) return false;
    await SharedPreferencesAsync().setBool(_enabledKey, enabled);
    _enabled = enabled;
    enabled ? _start() : _stop();
    return true;
  }

  static void _start() {
    if (_lyricsSubscription != null) return;
    final container = GetIt.instance<ProviderContainer>();
    // Listening keeps the lyrics loaded for the current track, also while the player screen is closed.
    _lyricsSubscription = container.listen<AsyncValue<MetadataProvider?>>(currentTrackMetadataProvider, (_, metadata) {
      final value = metadata.valueOrNull;
      final lines = value?.lyrics?.lyrics ?? const <LyricLine>[];
      _lines = lines.isNotEmpty && lines.first.start != null ? lines : const [];
      _title = [value?.item.name, value?.item.albumArtist ?? value?.item.artists?.firstOrNull].nonNulls.join(" · ");
      _shownIndex = -2;
      _update();
    }, fireImmediately: true);
    final player = GetIt.instance<MusicPlayerBackgroundTask>();
    // Every state: a seek or a change of speed moves the next line's time.
    _playingSubscription = player.playbackState.listen((_) => _update());
  }

  static void _stop() {
    _lyricsSubscription?.close();
    _lyricsSubscription = null;
    unawaited(_playingSubscription?.cancel());
    _playingSubscription = null;
    _timer?.cancel();
    _timer = null;
    _clear();
  }

  static void _update() {
    _timer?.cancel();
    _timer = null;
    final player = GetIt.instance<MusicPlayerBackgroundTask>();
    final state = player.playbackState.value;
    if (_lines.isEmpty || !state.playing) {
      _clear();
      return;
    }
    final position = player.playbackPosition.inMicroseconds * 10;
    // Woken once for the next line, rather than checking a few times a second.
    final wait = untilNextLine(_lines, position, state.speed);
    if (wait != null) _timer = Timer(wait, _update);
    final index = KaraokeTiming.lineAt(_lines, position);
    if (index == _shownIndex) return;
    _shownIndex = index;
    // Before the first line, show what's coming.
    final line = index < 0 ? "♪" : (_lines[index].text ?? "").trim();
    final next = index + 1 < _lines.length ? _lines[index + 1].text?.trim() : null;
    unawaited(
      _channel
          .invokeMethod("lyric", {"title": _title, "line": line.isEmpty ? "♪" : line, "next": next})
          .catchError((Object e) => _logger.warning("Couldn't show lyrics", e)),
    );
  }

  /// How long until a line after [position] (in ticks) begins, playing at [speed]; null when none does, or it stands
  /// still. A little late rather than early, so the line has begun when it's looked up.
  @visibleForTesting
  static Duration? untilNextLine(List<LyricLine> lines, int position, double speed) {
    if (speed <= 0) return null;
    int? next;
    for (final line in lines) {
      final start = line.start;
      if (start != null && start > position && (next == null || start < next)) next = start;
    }
    if (next == null) return null;
    return Duration(microseconds: ((next - position) / 10 / speed).ceil()) + const Duration(milliseconds: 20);
  }

  static void _clear() {
    if (_shownIndex == -3) return;
    _shownIndex = -3;
    unawaited(_channel.invokeMethod("clearLyric").catchError((Object e) => null));
  }
}
