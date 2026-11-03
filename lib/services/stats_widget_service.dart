import 'dart:async';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/services/listening_log_service.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

typedef ListeningStats = ({Duration today, Duration week, String? topArtist, int streakDays});

/// Feeds the listening stats home screen widget.
class StatsWidgetService {
  StatsWidgetService._();

  static final _logger = Logger("StatsWidgetService");
  static const _channel = MethodChannel("com.unicornsonlsd.finamp/home_widget");
  static Timer? _debounce;

  /// Today's and this week's listening time (weeks start on Monday), the week's top artist and how many days
  /// in a row ending today (or yesterday, so the streak doesn't look broken in the morning) had a listen.
  static ListeningStats compute(List<ListenEntry> listens, DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    final weekStart = today.subtract(Duration(days: now.weekday - 1));
    var todayTime = Duration.zero;
    var weekTime = Duration.zero;
    final artistTime = <String, Duration>{};
    final days = <DateTime>{};
    for (final listen in listens) {
      final day = DateTime(listen.time.year, listen.time.month, listen.time.day);
      days.add(day);
      if (!day.isBefore(weekStart)) {
        weekTime += listen.listened;
        final artist = listen.artist;
        if (artist != null && artist.isNotEmpty) {
          artistTime.update(artist, (time) => time + listen.listened, ifAbsent: () => listen.listened);
        }
      }
      if (day == today) todayTime += listen.listened;
    }
    var streak = 0;
    var day = days.contains(today) ? today : today.subtract(const Duration(days: 1));
    while (days.contains(day)) {
      streak++;
      day = DateTime(day.year, day.month, day.day - 1);
    }
    final topArtist = artistTime.entries.sortedBy<Duration>((entry) => entry.value).lastOrNull?.key;
    return (today: todayTime, week: weekTime, topArtist: topArtist, streakDays: streak);
  }

  /// Refreshes the widget a little while after listens come in, rather than after every one.
  static void scheduleRefresh() {
    if (!Platform.isAndroid) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 20), () => unawaited(refresh()));
  }

  static String _duration(Duration duration) {
    final l10n = GlobalSnackbar.requireL10n;
    return duration.inHours > 0
        ? l10n.statsWidgetHoursMinutes(duration.inHours, duration.inMinutes % 60)
        : l10n.statsWidgetMinutes(duration.inMinutes);
  }

  static Future<void> refresh() async {
    if (!Platform.isAndroid) return;
    try {
      final stats = compute(await ListeningLogService.load(), DateTime.now());
      final l10n = GlobalSnackbar.requireL10n;
      await _channel.invokeMethod("updateStats", {
        "headline": l10n.statsWidgetToday,
        "today": _duration(stats.today),
        "week": l10n.statsWidgetThisWeek(_duration(stats.week)),
        "artist": stats.topArtist == null ? "" : l10n.statsWidgetTopArtist(stats.topArtist!),
        "streak": stats.streakDays < 2 ? "" : l10n.statsWidgetStreak(stats.streakDays),
      });
    } catch (e) {
      _logger.warning("Couldn't update the stats widget", e);
    }
  }
}
