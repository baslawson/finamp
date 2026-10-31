import 'dart:async';
import 'dart:convert';

import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/services/car_mode_service.dart';
import 'package:finamp/services/dj_voice_service.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:finamp/services/headphone_eq_service.dart';
import 'package:finamp/services/genre_eq_service.dart';
import 'package:finamp/services/music_player_background_task.dart';
import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hive_ce/hive.dart';

/// Connection presets deliberately use the existing Bluetooth device stream;
/// this is not a claim that a connected device is Android's selected route.
class DeviceSoundProfiles {
  static final changed = ValueNotifier<int>(0);
  static final _log = Logger('DeviceSoundProfiles');
  static final _profiles = <String, Map<String, dynamic>>{};
  static Map<String, dynamic>? _baseline;
  static String? active;
  static bool enabled = false;
  static bool _initialized = false;
  static Future<void> _tail = Future.value();
  static List<String> get devices => List.unmodifiable(_profiles.keys);

  static Future<void> _run(Future<void> Function() action) {
    final result = _tail.catchError((Object _) {}).then((_) => action());
    _tail = result;
    return result;
  }

  static Future<void> initialize() => _run(() async {
    if (_initialized) return;
    final prefs = SharedPreferencesAsync();
    enabled = await prefs.getBool('deviceSoundEnabled') ?? false;
    try {
      final json = jsonDecode(await prefs.getString('deviceSoundProfiles') ?? '{}') as Map;
      for (final entry in json.entries) {
        if (entry.key is String && entry.value is Map) {
          _profiles[entry.key as String] = Map<String, dynamic>.from(entry.value as Map);
        }
      }
      // A process can die while a connection preset is active. Restore the
      // user's baseline before handling this launch's device connections.
      final saved = await prefs.getString('deviceSoundBaseline');
      if (saved != null) {
        _baseline = Map<String, dynamic>.from(jsonDecode(saved) as Map);
        await _apply(_baseline!);
        await prefs.remove('deviceSoundBaseline');
        _baseline = null;
      }
    } on Object catch (error) {
      _log.warning('Could not restore a sound profile', error);
    }
    _initialized = true;
    CarModeService.connectedChanges.stream.listen((devices) {
      unawaited(_run(() => _connect(devices)).catchError((Object e) => _log.warning('Sound profile change failed', e)));
    });
    await _connect(CarModeService.connectedDevices);
  });

  static Future<Map<String, dynamic>> capture() async {
    final settings = FinampSettingsHelper.finampSettings;
    final prefs = SharedPreferencesAsync();
    return {
      'enabled': settings.volumeNormalizationActive,
      'level': settings.normalizationLevel,
      'mode': settings.volumeNormalizationMode.name,
      'eq': await prefs.getString('headphoneEqCorrection'),
      'tone': await prefs.getString('headphoneTone'),
      'genreEq': await prefs.getBool('genreEqEnabled') ?? false,
      'dj': DjVoiceService.effectiveProfile.toJson(),
    };
  }

  static Future<void> saveFor(String device) => _run(() async {
    _profiles[device] = await capture();
    await _save();
    await _connect(CarModeService.connectedDevices);
  });
  static Future<void> remove(String device) => _run(() async {
    _profiles.remove(device);
    await _save();
    await _connect(CarModeService.connectedDevices);
  });
  static Future<void> setEnabled(bool value) => _run(() async {
    enabled = value;
    await SharedPreferencesAsync().setBool('deviceSoundEnabled', value);
    await _connect(CarModeService.connectedDevices);
    changed.value++;
  });
  static Future<void> _save() async {
    await SharedPreferencesAsync().setString('deviceSoundProfiles', jsonEncode(_profiles));
    changed.value++;
  }

  static String? choose(List<String> connected, Iterable<String> saved, String? current) {
    final matches = connected.where(saved.contains).toList();
    if (current != null && matches.contains(current)) return current;
    return matches.lastOrNull;
  }

  @visibleForTesting
  static Future<void> updateConnections(List<String> connected) => _run(() => _connect(connected));

  static Future<void> _connect(List<String> connected) async {
    final next = enabled ? choose(connected, _profiles.keys, active) : null;
    if (next == active && (next != null || _baseline == null)) return;
    final prefs = SharedPreferencesAsync();
    if (next != null) {
      if (_baseline == null) {
        _baseline = await capture();
        await prefs.setString('deviceSoundBaseline', jsonEncode(_baseline));
      }
      await _apply(_profiles[next]!, device: true);
    } else if (_baseline != null) {
      await _apply(_baseline!);
      _baseline = null;
      await prefs.remove('deviceSoundBaseline');
    }
    active = next;
    changed.value++;
  }

  static Future<void> _apply(Map<String, dynamic> snapshot, {bool device = false}) async {
    final settings = FinampSettingsHelper.finampSettings;
    settings.volumeNormalizationActive = snapshot['enabled'] as bool? ?? true;
    settings.normalizationLevel = ((snapshot['level'] as num?)?.toInt() ?? 1).clamp(0, 2);
    settings.volumeNormalizationMode =
        VolumeNormalizationMode.values.where((v) => v.name == snapshot['mode']).firstOrNull ??
        VolumeNormalizationMode.hybrid;
    await Hive.box<FinampSettings>('FinampSettings').put('FinampSettings', settings);
    final prefs = SharedPreferencesAsync();
    for (final pair in [('eq', 'headphoneEqCorrection'), ('tone', 'headphoneTone')]) {
      final value = snapshot[pair.$1];
      if (value is String) {
        await prefs.setString(pair.$2, value);
      } else {
        await prefs.remove(pair.$2);
      }
    }
    final dj = snapshot['dj'];
    await DjVoiceService.setDeviceProfile(
      device && dj is Map ? DjVoiceProfile.fromJson(Map<String, dynamic>.from(dj)) : null,
    );
    await GenreEqService.setEnabled(snapshot['genreEq'] == true);
    final equalizer = GetIt.instance<MusicPlayerBackgroundTask>().equalizer;
    if (equalizer != null) {
      unawaited(
        HeadphoneEqService.refresh(equalizer).catchError((Object e) => _log.warning('Could not apply device EQ', e)),
      );
    }
  }
}
