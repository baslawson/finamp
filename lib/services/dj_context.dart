import 'dart:async';
import 'dart:convert';

import 'package:finamp/services/car_mode_service.dart';
import 'package:finamp/services/night_mode_service.dart';
import 'package:finamp/services/right_now_service.dart';
import 'package:finamp/services/running_service.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Current weather, in words a DJ can use.
typedef DjWeather = ({String place, int temperature, String sky, bool day});

/// What the DJ may know about the moment: the time of day, what the listener is doing according to the app (driving,
/// running, winding down at night) and, when a city is set, the weather there. All optional, and only what the app
/// already knows: the weather lookup sends just the city name to Open-Meteo, which needs no account.
class DjContext {
  DjContext._();

  static final _logger = Logger('DjContext');
  static const _enabledKey = 'djContextAware';
  static const _cityKey = 'djWeatherCity';
  static const _weatherLife = Duration(minutes: 30);

  /// How soon to try again after the weather couldn't be fetched.
  static const _retryAfter = Duration(minutes: 5);

  static bool? _enabled;
  static String? _city;
  static ({String city, DjWeather? weather, DateTime at})? _weather;
  static ({String city, double latitude, double longitude, String name})? _place;
  static Future<DjWeather?>? _fetching;

  @visibleForTesting
  static ({bool running, double? pace, bool car, bool night})? activityOverride;

  @visibleForTesting
  static DateTime Function() now = DateTime.now;

  static Future<bool> isEnabled() async {
    try {
      return _enabled ??= await SharedPreferencesAsync().getBool(_enabledKey) ?? true;
    } catch (_) {
      return true;
    }
  }

  static Future<void> setEnabled(bool enabled) async {
    _enabled = enabled;
    await SharedPreferencesAsync().setBool(_enabledKey, enabled);
  }

  /// The city for the weather, or an empty string when the weather is off.
  static Future<String> city() async {
    try {
      return _city ??= await SharedPreferencesAsync().getString(_cityKey) ?? '';
    } catch (_) {
      return '';
    }
  }

  static Future<void> setCity(String city) async {
    _city = city.trim();
    _weather = null;
    _place = null;
    await SharedPreferencesAsync().setString(_cityKey, _city!);
  }

  static String dayPart(DateTime time) => switch (RightNowService.dayPart(time)) {
    DayPart.morning => time.weekday >= DateTime.saturday ? 'weekend morning' : 'weekday morning',
    DayPart.afternoon => 'afternoon',
    DayPart.evening => time.weekday == DateTime.friday ? 'Friday evening' : 'evening',
    DayPart.night => 'late night',
  };

  /// One line for the DJ's prompt, or null when context is turned off. Never throws; the weather is skipped when it
  /// can't be fetched within [timeout].
  static Future<String?> describe(DateTime now, {Duration timeout = const Duration(seconds: 3)}) async {
    if (!await isEnabled()) return null;
    final activity =
        activityOverride ??
        (
          running: RunningService.active.value,
          pace: RunningService.pace.value,
          car: CarModeService.inCar,
          night: NightModeService.isActive,
        );
    final parts = <String>['It is ${dayPart(now)}'];
    if (activity.running) {
      parts.add(
        'the listener is out running${activity.pace == null ? '' : ' at about ${activity.pace!.round()} steps a minute'}',
      );
    } else if (activity.car) {
      parts.add('the listener is driving');
    }
    if (activity.night) parts.add('night mode is on, so the listener is winding down');
    try {
      final current = await weather().timeout(timeout, onTimeout: () => null);
      if (current != null) {
        parts.add(
          'in ${current.place} it is ${current.temperature} degrees and ${current.sky}${current.day ? '' : ' tonight'}',
        );
      }
    } catch (_) {
      // Weather is a nice extra only.
    }
    return '${parts.join('; ')}.';
  }

  /// The weather for the chosen city, cached for half an hour; null when no city is set or it's unavailable. Once
  /// known, older weather is answered straight away while it's refreshed in the background, so a DJ line never waits
  /// on the network for it.
  static Future<DjWeather?> weather() async {
    final place = await city();
    if (place.isEmpty) return null;
    final cached = _weather?.city == place ? _weather : null;
    if (cached != null) {
      final age = now().difference(cached.at);
      if (age < (cached.weather == null ? _retryAfter : _weatherLife)) return cached.weather;
      if (cached.weather != null) {
        unawaited(_refresh(place));
        return cached.weather;
      }
    }
    return _refresh(place);
  }

  /// Starts fetching the weather if it's due, e.g. when the DJ starts, so the first line already has it.
  static void prefetch() {
    unawaited(isEnabled().then((enabled) => enabled ? weather() : null).then<void>((_) {}, onError: (Object _) {}));
  }

  static Future<DjWeather?> _refresh(String place) => _fetching ??= _fetch(place).whenComplete(() => _fetching = null);

  static Future<DjWeather?> _fetch(String place) async {
    DjWeather? result;
    try {
      // The city's position doesn't change: it's looked up once, then only the forecast is fetched.
      var location = _place?.city == place ? _place : null;
      if (location == null) {
        final geo = await http
            .get(
              Uri.https('geocoding-api.open-meteo.com', '/v1/search', {'name': place, 'count': '1', 'format': 'json'}),
            )
            .timeout(const Duration(seconds: 5));
        final found = (jsonDecode(geo.body) as Map<String, dynamic>)['results'];
        if (geo.statusCode == 200 && found is List && found.isNotEmpty) {
          final first = found.first as Map<String, dynamic>;
          location = _place = (
            city: place,
            latitude: (first['latitude'] as num).toDouble(),
            longitude: (first['longitude'] as num).toDouble(),
            name: first['name'] as String? ?? place,
          );
        }
      }
      if (location != null) {
        final forecast = await http
            .get(
              Uri.https('api.open-meteo.com', '/v1/forecast', {
                'latitude': '${location.latitude}',
                'longitude': '${location.longitude}',
                'current': 'temperature_2m,weather_code,is_day',
              }),
            )
            .timeout(const Duration(seconds: 5));
        final current = (jsonDecode(forecast.body) as Map<String, dynamic>)['current'];
        if (forecast.statusCode == 200 && current is Map<String, dynamic>) {
          result = (
            place: location.name,
            temperature: (current['temperature_2m'] as num).round(),
            sky: sky(current['weather_code'] as int? ?? 0),
            day: current['is_day'] != 0,
          );
        }
      }
    } catch (e) {
      _logger.info("Couldn't get the weather (${e.runtimeType})");
    }
    if (_city == place) {
      // A failed refresh keeps the last good weather until it's too old to be true.
      final previous = _weather;
      final keep =
          result == null &&
          previous != null &&
          previous.city == place &&
          previous.weather != null &&
          now().difference(previous.at) < const Duration(hours: 2);
      if (!keep) _weather = (city: place, weather: result, at: now());
    }
    return result ?? (_weather?.city == place ? _weather?.weather : null);
  }

  /// WMO weather codes, as Open-Meteo reports them, in plain words.
  static String sky(int code) => switch (code) {
    0 => 'clear',
    1 || 2 => 'partly cloudy',
    3 => 'overcast',
    45 || 48 => 'foggy',
    >= 51 && <= 57 => 'drizzly',
    >= 61 && <= 67 || >= 80 && <= 82 => 'raining',
    >= 71 && <= 77 || 85 || 86 => 'snowing',
    >= 95 => 'stormy',
    _ => 'mild',
  };

  @visibleForTesting
  static void reset() {
    _enabled = null;
    _city = null;
    _weather = null;
    _place = null;
    _fetching = null;
    activityOverride = null;
    now = DateTime.now;
  }
}
