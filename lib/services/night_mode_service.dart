import 'dart:async';
import 'dart:io';

import 'package:finamp/services/music_player_background_task.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

typedef NightModeSettings = ({bool enabled, int startMinute, int endMinute});

/// Night mode volume: between the chosen times, a compressor lifts quiet passages and tames loud ones,
/// so nothing has to be turned up or down at night. Android 9 and later.
class NightModeService {
  NightModeService._();

  static final _logger = Logger("NightModeService");
  static const _channel = MethodChannel("com.unicornsonlsd.finamp/night_mode");
  static const _enabledKey = "nightModeEnabled";
  static const _startKey = "nightModeStartMinute";
  static const _endKey = "nightModeEndMinute";

  static NightModeSettings _settings = (enabled: false, startMinute: 22 * 60, endMinute: 7 * 60);
  static int? _sessionId;
  static bool? _applied;
  static Timer? _timer;
  static StreamSubscription<int?>? _sessionSubscription;

  /// Whether the compressor is on right now.
  static final active = StreamController<bool>.broadcast();
  static bool get isActive => _applied ?? false;

  static Future<NightModeSettings> loadSettings() async {
    final prefs = SharedPreferencesAsync();
    return (
      enabled: await prefs.getBool(_enabledKey) ?? false,
      startMinute: await prefs.getInt(_startKey) ?? 22 * 60,
      endMinute: await prefs.getInt(_endKey) ?? 7 * 60,
    );
  }

  static Future<void> saveSettings(NightModeSettings settings) async {
    final prefs = SharedPreferencesAsync();
    await prefs.setBool(_enabledKey, settings.enabled);
    await prefs.setInt(_startKey, settings.startMinute);
    await prefs.setInt(_endKey, settings.endMinute);
    _settings = settings;
    await _update();
    _updateTimer();
  }

  /// Whether [minute] of the day falls in the window, which may wrap past midnight.
  static bool inWindow(int minute, int start, int end) =>
      start <= end ? minute >= start && minute < end : minute >= start || minute < end;

  static Future<void> initialize() async {
    if (!Platform.isAndroid) return;
    _settings = await loadSettings();
    _sessionSubscription = GetIt.instance<MusicPlayerBackgroundTask>().androidAudioSessionIdStream.listen((id) {
      _sessionId = id;
      _applied = null;
      unawaited(_update());
    });
    _updateTimer();
  }

  static Future<void> dispose() async {
    _timer?.cancel();
    await _sessionSubscription?.cancel();
    _timer = null;
    _sessionSubscription = null;
  }

  static void _updateTimer() {
    _timer?.cancel();
    _timer = _settings.enabled && _sessionSubscription != null
        ? Timer.periodic(const Duration(minutes: 1), (_) => _update())
        : null;
  }

  static Future<void> _update() async {
    final now = DateTime.now();
    final shouldBeOn =
        _settings.enabled && inWindow(now.hour * 60 + now.minute, _settings.startMinute, _settings.endMinute);
    if (shouldBeOn == _applied || _sessionId == null) return;
    try {
      await _channel.invokeMethod<bool>("set", {"sessionId": _sessionId, "enabled": shouldBeOn});
      _applied = shouldBeOn;
      active.add(shouldBeOn);
      _logger.info("Night mode ${shouldBeOn ? "on" : "off"}");
    } catch (e) {
      _logger.warning("Couldn't switch night mode", e);
    }
  }
}
