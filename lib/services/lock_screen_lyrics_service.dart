import 'dart:async';
import 'dart:io';

import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/screens/karaoke_screen.dart';
import 'package:finamp/services/current_track_metadata_provider.dart';
import 'package:finamp/services/metadata_provider.dart';
import 'package:finamp/services/music_player_background_task.dart';
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
  static StreamSubscription<bool>? _playingSubscription;
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
    _playingSubscription = player.playbackState.map((state) => state.playing).distinct().listen((playing) {
      _timer?.cancel();
      if (playing) {
        _timer = Timer.periodic(const Duration(milliseconds: 250), (_) => _update());
      } else {
        _clear();
      }
    });
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
    final player = GetIt.instance<MusicPlayerBackgroundTask>();
    if (_lines.isEmpty || !player.playbackState.value.playing) {
      _clear();
      return;
    }
    final index = KaraokeTiming.lineAt(_lines, player.playbackPosition.inMicroseconds * 10);
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

  static void _clear() {
    if (_shownIndex == -3) return;
    _shownIndex = -3;
    unawaited(_channel.invokeMethod("clearLyric").catchError((Object e) => null));
  }
}
