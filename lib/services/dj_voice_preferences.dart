import 'dart:convert';

import 'package:finamp/services/dj_voice_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Keeps station overrides apart from the main defaults and from synced radio
/// song preferences. A server that doesn't know DJ options cannot erase them.
class DjVoicePreferences {
  static Future<Map<DjListeningEnvironment, DjListeningPreset>> loadListeningPresets() async {
    final presets = {
      DjListeningEnvironment.car: DjListeningPreset.car,
      DjListeningEnvironment.headphones: DjListeningPreset.headphones,
    };
    try {
      final values = jsonDecode(await SharedPreferencesAsync().getString('djListeningPresets') ?? '{}') as Map;
      for (final environment in DjListeningEnvironment.values) {
        if (values[environment.name] case final Map<dynamic, dynamic> value) {
          presets[environment] = DjListeningPreset.fromJson(Map<String, dynamic>.from(value));
        }
      }
    } catch (_) {
      /* Preset damage leaves the built-in choices usable. */
    }
    return presets;
  }

  static Future<void> saveListeningPresets(Map<DjListeningEnvironment, DjListeningPreset> presets) =>
      SharedPreferencesAsync().setString(
        'djListeningPresets',
        jsonEncode({for (final entry in presets.entries) entry.key.name: entry.value.toJson()}),
      );

  static Future<DjVoiceProfile> loadGlobal() async {
    final prefs = SharedPreferencesAsync();
    Map<String, dynamic> options = {};
    try {
      options = Map<String, dynamic>.from(jsonDecode(await prefs.getString('djVoiceProfile') ?? '{}') as Map);
    } catch (_) {
      /* Keep legacy defaults. */
    }
    return DjVoiceProfile.fromJson({
      ...options,
      'mode': await prefs.getString('djVoiceMode'),
      'every': await prefs.getInt('djVoiceEvery'),
      'character': await prefs.getString('djVoiceCharacter'),
      'aiVoice': await prefs.getBool('djVoiceAiVoice'),
      'volume': await prefs.getDouble('djVoiceVolume'),
    });
  }

  static Future<void> saveGlobal(DjVoiceProfile profile) async {
    final prefs = SharedPreferencesAsync(), settings = profile.settings;
    await prefs.setString('djVoiceMode', settings.mode.name);
    await prefs.setInt('djVoiceEvery', settings.every);
    await prefs.setString('djVoiceCharacter', settings.character.name);
    await prefs.setBool('djVoiceAiVoice', settings.aiVoice);
    await prefs.setDouble('djVoiceVolume', settings.volume);
    await prefs.setString('djVoiceProfile', jsonEncode(profile.toJson()));
  }

  static Future<Map<String, DjVoiceProfile>> loadStations(String scope) async {
    final profiles = <String, DjVoiceProfile>{};
    try {
      final values = jsonDecode(await SharedPreferencesAsync().getString('djVoiceStations.$scope') ?? '{}') as Map;
      for (final entry in values.entries) {
        if (entry.key is String && entry.value is Map) {
          profiles[entry.key as String] = DjVoiceProfile.fromJson(Map<String, dynamic>.from(entry.value as Map));
        }
      }
    } catch (_) {
      /* Damaged options never prevent music playback. */
    }
    return profiles;
  }

  static Future<void> saveStations(String scope, Map<String, DjVoiceProfile> profiles) =>
      SharedPreferencesAsync().setString(
        'djVoiceStations.$scope',
        jsonEncode({for (final entry in profiles.entries) entry.key: entry.value.toJson()}),
      );

  static Future<DateTime?> loadQuietUntil(DateTime now) async {
    final value = await SharedPreferencesAsync().getInt('djVoiceQuietUntil');
    if (value == null) return null;
    try {
      final until = DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
      if (until.isAfter(now)) return until;
    } on ArgumentError {
      // An invalid saved timestamp must not interrupt DJ initialization.
    }
    await saveQuietUntil(null);
    return null;
  }

  static Future<void> saveQuietUntil(DateTime? until) => until == null
      ? SharedPreferencesAsync().remove('djVoiceQuietUntil')
      : SharedPreferencesAsync().setInt('djVoiceQuietUntil', until.millisecondsSinceEpoch);
}
