import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

final _screenWakelockLogger = Logger("ScreenWakelock");

/// Keeps the screen on, or lets it turn off again. Keeping the screen on is a convenience, so a refusal isn't an
/// error: Android refuses once the app's screen has gone, for example when a pause from the lock screen arrives just as
/// the app is swiped away.
Future<void> keepScreenOn(bool on, {@visibleForTesting Future<void> Function({required bool enable})? toggle}) async {
  try {
    await (toggle ?? WakelockPlus.toggle)(enable: on);
  } catch (e) {
    _screenWakelockLogger.info("Couldn't ${on ? "keep the screen on" : "let the screen turn off"}: $e");
  }
}
