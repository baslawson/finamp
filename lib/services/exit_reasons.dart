import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Logs why the app's process last ended, as Android keeps a record of it and the app itself never gets to say.
class ExitReasons {
  ExitReasons._();

  static const _lastKey = "exitReasonsLastLogged";
  static const _channel = MethodChannel("com.unicornsonlsd.finamp/diagnostics");
  static final _logger = Logger("ExitReasons");

  /// Android's ApplicationExitInfo.REASON_ values.
  static const _reasons = {
    1: "it exited by itself",
    2: "a system signal",
    3: "low memory",
    4: "a crash",
    5: "a native crash",
    6: "not responding",
    7: "failing to start",
    8: "a permission change",
    9: "using too many resources",
    10: "the user asking (swiped away or cleared)",
    11: "the user stopping it in settings",
    12: "a process it depends on ending",
    13: "the system, for another reason",
    14: "being frozen",
    15: "the app being disabled or enabled",
    16: "an app update",
  };

  /// Android's RunningAppProcessInfo.IMPORTANCE_ values, for how much the app was doing when it ended.
  static const _importance = {
    100: "on screen",
    125: "foreground service",
    200: "visible",
    230: "visible",
    300: "background service",
    325: "top sleeping",
    350: "can't save state",
    400: "cached",
    1000: "gone",
  };

  /// Reasons that mean something went wrong in the app, so its logs are worth uploading.
  static const _failures = {4, 5, 6, 7};

  @visibleForTesting
  static Future<List<Map<Object?, Object?>>> Function() read = () async {
    if (!Platform.isAndroid) return const [];
    return await _channel.invokeListMethod<Map<Object?, Object?>>("exitReasons") ?? const [];
  };

  @visibleForTesting
  static String describe(Map<Object?, Object?> exit) {
    final reason = exit["reason"] as int? ?? 0;
    final importance = exit["importance"] as int? ?? 0;
    final at = DateTime.fromMillisecondsSinceEpoch(exit["timestamp"] as int? ?? 0);
    final memory = (exit["pss"] as int? ?? 0) ~/ 1024;
    final description = exit["description"] as String?;
    return "The app ended at $at because of ${_reasons[reason] ?? "reason $reason"} "
        "while ${_importance[importance] ?? "importance $importance"}, using $memory MB"
        "${description == null || description.isEmpty ? "" : " ($description)"}";
  }

  /// Logs the endings not logged yet, oldest first. Never throws: this is only for the logs.
  static Future<void> logNew() async {
    try {
      final prefs = SharedPreferencesAsync();
      final last = await prefs.getInt(_lastKey) ?? 0;
      final exits = (await read()).where((exit) => (exit["timestamp"] as int? ?? 0) > last).toList()
        ..sort((a, b) => (a["timestamp"] as int? ?? 0).compareTo(b["timestamp"] as int? ?? 0));
      if (exits.isEmpty) return;
      // Noted first, so that a failure while logging can't report the same ending at every start.
      await prefs.setInt(_lastKey, exits.last["timestamp"] as int? ?? last);
      for (final exit in exits) {
        final text = describe(exit);
        if (_failures.contains(exit["reason"])) {
          _logger.severe(text);
        } else {
          _logger.info(text);
        }
      }
    } catch (e) {
      _logger.info("Couldn't read why the app last ended: $e");
    }
  }
}
