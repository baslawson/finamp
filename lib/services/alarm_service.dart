import 'dart:async';
import 'dart:io';

import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/screens/alarm_ringing_screen.dart';
import 'package:finamp/services/ai_dj_service.dart';
import 'package:finamp/services/finamp_user_helper.dart';
import 'package:finamp/services/jellyfin_api_helper.dart';
import 'package:finamp/services/music_player_background_task.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What the alarm wakes the user up to.
enum AlarmSource { favorites, shuffleAll, playlist, aiDj }

/// When the alarm rings. [days] is a bit mask with Monday as bit 0; 0 rings once.
typedef AlarmTime = ({bool enabled, int hour, int minute, int days});

typedef AlarmMusic = ({AlarmSource source, String? playlistId, String? playlistName, String aiPrompt, int fadeMinutes});

/// Wakes the user with music that fades in. The time is scheduled natively (see MusicAlarm.kt); when it rings,
/// Android opens finamp://alarm and [ring] starts the music.
class AlarmService {
  AlarmService._();

  static final _logger = Logger("AlarmService");
  static const _channel = MethodChannel("com.unicornsonlsd.finamp/alarm");
  static const _sourceKey = "alarmSource";
  static const _playlistIdKey = "alarmPlaylistId";
  static const _playlistNameKey = "alarmPlaylistName";
  static const _promptKey = "alarmAiPrompt";
  static const _fadeKey = "alarmFadeMinutes";
  static const snoozeMinutes = 10;

  static Timer? _fadeTimer;

  static bool get supported => Platform.isAndroid;

  static Future<AlarmTime> loadTime() async {
    final map = await _channel.invokeMapMethod<String, dynamic>("get") ?? {};
    return (
      enabled: map["enabled"] as bool? ?? false,
      hour: map["hour"] as int? ?? 7,
      minute: map["minute"] as int? ?? 0,
      days: map["days"] as int? ?? 0,
    );
  }

  /// Saves and schedules the alarm. Returns when it rings next, or null when it's off.
  static Future<DateTime?> saveTime(AlarmTime time) async {
    final next = await _channel.invokeMethod<int>("save", {
      "enabled": time.enabled,
      "hour": time.hour,
      "minute": time.minute,
      "days": time.days,
    });
    return next == null ? null : DateTime.fromMillisecondsSinceEpoch(next);
  }

  static Future<AlarmMusic> loadMusic() async {
    final prefs = SharedPreferencesAsync();
    final source = await prefs.getString(_sourceKey);
    return (
      source: AlarmSource.values.where((value) => value.name == source).firstOrNull ?? AlarmSource.favorites,
      playlistId: await prefs.getString(_playlistIdKey),
      playlistName: await prefs.getString(_playlistNameKey),
      aiPrompt: await prefs.getString(_promptKey) ?? "",
      fadeMinutes: await prefs.getInt(_fadeKey) ?? 5,
    );
  }

  static Future<void> saveMusic(AlarmMusic music) async {
    final prefs = SharedPreferencesAsync();
    await prefs.setString(_sourceKey, music.source.name);
    if (music.playlistId == null) {
      await prefs.remove(_playlistIdKey);
      await prefs.remove(_playlistNameKey);
    } else {
      await prefs.setString(_playlistIdKey, music.playlistId!);
      await prefs.setString(_playlistNameKey, music.playlistName ?? "");
    }
    await prefs.setString(_promptKey, music.aiPrompt);
    await prefs.setInt(_fadeKey, music.fadeMinutes);
  }

  /// Whether Android lets the alarm open the app over the lock screen (Android 14 asks the user).
  static Future<bool> canUseFullScreenIntent() async =>
      await _channel.invokeMethod<bool>("canUseFullScreenIntent") ?? true;

  static Future<void> openFullScreenIntentSettings() => _channel.invokeMethod("openFullScreenIntentSettings");

  /// Volume during the fade: slow at first, since hearing is logarithmic.
  static double fadeCurve(double progress) {
    final clamped = progress.clamp(0.0, 1.0);
    return 0.03 + 0.97 * clamped * clamped;
  }

  /// Shows the alarm screen and starts the music, fading in.
  static Future<void> ring(NavigatorState navigator) async {
    _logger.info("Alarm ringing");
    unawaited(navigator.pushNamed(AlarmRingingScreen.routeName));
    final player = GetIt.instance<MusicPlayerBackgroundTask>();
    final music = await loadMusic();
    await player.setAlarmVolume(music.fadeMinutes > 0 ? fadeCurve(0) : 1.0);
    try {
      await _startMusic(music);
    } catch (e) {
      // Offline, the server is down or the AI failed: still wake the user with whatever was playing last.
      _logger.warning("Couldn't start the alarm music, resuming the last queue", e);
      await player.play();
    }
    _startFade(music.fadeMinutes);
  }

  static Future<void> _startMusic(AlarmMusic music) async {
    final api = GetIt.instance<JellyfinApiHelper>();
    final library = GetIt.instance<FinampUserHelper>().currentUser?.currentView;
    final source = QueueItemSource.rawId(
      type: QueueItemSourceType.unknown,
      name: const QueueItemSourceName(type: QueueItemSourceNameType.preTranslated, pretranslatedName: "Alarm"),
      id: "alarm",
    );
    Future<void> play(List<BaseItemDto>? tracks, {bool shuffle = true}) async {
      if (tracks == null || tracks.isEmpty) throw Exception("No tracks for the alarm");
      await GetIt.instance<QueueService>().startPlayback(
        items: tracks,
        source: source,
        order: shuffle ? FinampPlaybackOrder.shuffled : FinampPlaybackOrder.linear,
      );
    }

    switch (music.source) {
      case AlarmSource.favorites:
        await play(
          await api.getItems(
            parentItem: library,
            includeItemTypes: BaseItemDtoType.track.jellyfinName,
            filters: "IsFavorite",
            sortBy: "Random",
            recursive: true,
            limit: 100,
          ),
        );
      case AlarmSource.shuffleAll:
        await play(
          await api.getItems(
            parentItem: library,
            includeItemTypes: BaseItemDtoType.track.jellyfinName,
            sortBy: "Random",
            recursive: true,
            limit: 100,
          ),
        );
      case AlarmSource.playlist when music.playlistId != null:
        final playlist = await api.getItemById(BaseItemId(music.playlistId!));
        await play(await api.getItems(parentItem: playlist), shuffle: false);
      case AlarmSource.aiDj when music.aiPrompt.trim().isNotEmpty:
        await AiDjService.playMix(music.aiPrompt, trackCount: 20);
      case AlarmSource.playlist || AlarmSource.aiDj:
        throw Exception("The alarm has no playlist or Ai DJ request set");
    }
  }

  static void _startFade(int minutes) {
    _fadeTimer?.cancel();
    if (minutes <= 0) return;
    final player = GetIt.instance<MusicPlayerBackgroundTask>();
    final started = DateTime.now();
    final length = Duration(minutes: minutes);
    _fadeTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      final progress = DateTime.now().difference(started).inMilliseconds / length.inMilliseconds;
      unawaited(player.setAlarmVolume(fadeCurve(progress)));
      if (progress >= 1) timer.cancel();
    });
  }

  static Future<void> _finish() async {
    _fadeTimer?.cancel();
    await GetIt.instance<MusicPlayerBackgroundTask>().setAlarmVolume(1.0);
    await _channel.invokeMethod("finish");
  }

  /// "I'm up": keeps the music playing at full volume.
  static Future<void> wakeUp() => _finish();

  static Future<void> stop() async {
    await GetIt.instance<MusicPlayerBackgroundTask>().pause();
    await _finish();
  }

  /// Pauses and rings again in [snoozeMinutes]. Returns when.
  static Future<DateTime> snooze() async {
    await GetIt.instance<MusicPlayerBackgroundTask>().pause();
    await _finish();
    final time = await _channel.invokeMethod<int>("snooze", {"minutes": snoozeMinutes});
    return DateTime.fromMillisecondsSinceEpoch(time!);
  }
}
