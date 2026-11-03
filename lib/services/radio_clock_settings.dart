import 'package:finamp/services/radio_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Stored per server and user, like the other Radio preferences.
class RadioClockSettings {
  static String get _key => 'radio.matchTimeOfDay.${RadioPreferencesStore.scope}';

  static Future<bool> load() async {
    try {
      return cached = await SharedPreferencesAsync().getBool(_key) ?? true;
    } catch (_) {
      return cached = true;
    }
  }

  static Future<void> save(bool enabled) {
    cached = enabled;
    return SharedPreferencesAsync().setBool(_key, enabled);
  }

  /// The setting as last loaded or saved, for checks that can't wait; on, its default, until then.
  static bool cached = true;
}
