import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:finamp/services/library_matcher.dart';
import 'package:finamp/services/listening_log_service.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// An upcoming show by an artist you listen to.
class Concert {
  Concert({
    required this.id,
    required this.artist,
    required this.name,
    required this.date,
    this.venue,
    this.city,
    this.url,
  });

  final String id;
  final String artist;
  final String name;
  final DateTime date;
  final String? venue;
  final String? city;
  final String? url;

  factory Concert.fromJson(Map<String, dynamic> json) => Concert(
    id: json["id"] as String,
    artist: json["artist"] as String,
    name: json["name"] as String,
    date: DateTime.parse(json["date"] as String),
    venue: json["venue"] as String?,
    city: json["city"] as String?,
    url: json["url"] as String?,
  );

  Map<String, dynamic> toJson() => {
    "id": id,
    "artist": artist,
    "name": name,
    "date": date.toIso8601String(),
    if (venue != null) "venue": venue,
    if (city != null) "city": city,
    if (url != null) "url": url,
  };
}

typedef ConcertSettings = ({String? apiKey, String countryCode, String? city, bool notify});

/// Concert alerts: looks up upcoming shows by the artists you play most (Ticketmaster), and sends a notification
/// when a new one is announced in your country or city. Needs a free Ticketmaster API key.
class ConcertService {
  ConcertService._();

  static final _logger = Logger("ConcertService");
  static const _channel = MethodChannel("com.unicornsonlsd.finamp/notify");
  static const _api = "https://app.ticketmaster.com/discovery/v2/events.json";
  static const _prefix = "concerts";
  static const checkEvery = Duration(hours: 12);
  static const _artistCount = 40;

  static Timer? _timer;

  static Future<ConcertSettings> loadSettings() async {
    final prefs = SharedPreferencesAsync();
    return (
      apiKey: await prefs.getString("${_prefix}ApiKey"),
      countryCode: await prefs.getString("${_prefix}Country") ?? _guessCountry(),
      city: await prefs.getString("${_prefix}City"),
      notify: await prefs.getBool("${_prefix}Notify") ?? true,
    );
  }

  static String _guessCountry() {
    final locale = Platform.localeName.split(RegExp("[_-]"));
    return locale.length > 1 ? locale[1].toUpperCase() : "US";
  }

  static Future<void> saveSettings(ConcertSettings settings) async {
    final prefs = SharedPreferencesAsync();
    final key = settings.apiKey?.trim();
    key == null || key.isEmpty ? await prefs.remove("${_prefix}ApiKey") : await prefs.setString("${_prefix}ApiKey", key);
    await prefs.setString("${_prefix}Country", settings.countryCode.trim().toUpperCase());
    final city = settings.city?.trim();
    city == null || city.isEmpty ? await prefs.remove("${_prefix}City") : await prefs.setString("${_prefix}City", city);
    await prefs.setBool("${_prefix}Notify", settings.notify);
    if (settings.notify && key != null && key.isNotEmpty) await Permission.notification.request();
  }

  static Future<File> get _file async => File("${(await getApplicationSupportDirectory()).path}/concerts.json");

  /// The concerts found by the last check, soonest first.
  static Future<List<Concert>> saved() async {
    try {
      final file = await _file;
      if (!await file.exists()) return [];
      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return [
        for (final concert in (json["concerts"] as List<dynamic>).cast<Map<String, dynamic>>())
          Concert.fromJson(concert),
      ].where((concert) => concert.date.isAfter(DateTime.now().subtract(const Duration(days: 1)))).toList();
    } catch (e) {
      return [];
    }
  }

  /// The artists you listened to most in the last half year, most first.
  static List<String> topArtists(List<ListenEntry> listens, DateTime now, {int count = _artistCount}) {
    final since = now.subtract(const Duration(days: 183));
    final time = <String, Duration>{};
    final names = <String, String>{};
    for (final listen in listens) {
      final artist = listen.artist;
      if (artist == null || artist.isEmpty || listen.time.isBefore(since)) continue;
      final key = artist.toLowerCase();
      names.putIfAbsent(key, () => artist);
      time.update(key, (total) => total + listen.listened, ifAbsent: () => listen.listened);
    }
    return time.entries.sortedBy<num>((entry) => -entry.value.inSeconds).take(count).map((e) => names[e.key]!).toList();
  }

  /// Turns a Ticketmaster search result into concerts actually by [artist] (searches also match other words).
  static List<Concert> parse(Map<String, dynamic> json, String artist) {
    final events = (json["_embedded"] as Map<String, dynamic>?)?["events"] as List<dynamic>? ?? const [];
    final wanted = LibraryMatcher.splitArtists(artist).map((name) => name.toLowerCase()).toSet();
    return [
      for (final event in events.cast<Map<String, dynamic>>())
        if (() {
          final attractions =
              (event["_embedded"] as Map<String, dynamic>?)?["attractions"] as List<dynamic>? ?? const [];
          return attractions.any(
            (attraction) =>
                wanted.contains(((attraction as Map<String, dynamic>)["name"] as String? ?? "").toLowerCase()),
          );
        }())
          if (DateTime.tryParse(
                ((event["dates"] as Map<String, dynamic>?)?["start"] as Map<String, dynamic>?)?["localDate"]
                        as String? ??
                    "",
              )
              case final date?)
            Concert(
              id: event["id"] as String,
              artist: artist,
              name: event["name"] as String? ?? artist,
              date: date,
              venue: (((event["_embedded"] as Map<String, dynamic>?)?["venues"] as List<dynamic>?)?.firstOrNull
                      as Map<String, dynamic>?)?["name"]
                  as String?,
              city: ((((event["_embedded"] as Map<String, dynamic>?)?["venues"] as List<dynamic>?)?.firstOrNull
                          as Map<String, dynamic>?)?["city"]
                      as Map<String, dynamic>?)?["name"]
                  as String?,
              url: event["url"] as String?,
            ),
    ];
  }

  /// Looks for shows by your top artists. New ones get a notification (if enabled). Returns all found, soonest first.
  static Future<List<Concert>> check({bool notify = true}) async {
    final settings = await loadSettings();
    final key = settings.apiKey;
    if (key == null) return [];
    final artists = topArtists(await ListeningLogService.load(forLearning: true), DateTime.now());
    final found = <Concert>[];
    for (final artist in artists) {
      final uri = Uri.parse(_api).replace(
        queryParameters: {
          "apikey": key,
          "keyword": artist,
          "classificationName": "music",
          "countryCode": settings.countryCode,
          if (settings.city != null) "city": settings.city!,
          "sort": "date,asc",
          "size": "20",
        },
      );
      final response = await http.get(uri).timeout(const Duration(seconds: 15));
      if (response.statusCode == 401) throw Exception("Ticketmaster didn't accept the API key");
      if (response.statusCode == 429) {
        // Over the rate limit: try again a bit slower.
        await Future<void>.delayed(const Duration(seconds: 2));
        continue;
      }
      if (response.statusCode != 200) continue;
      found.addAll(parse(jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>, artist));
      // Ticketmaster allows 5 requests a second.
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    final concerts = {for (final concert in found) concert.id: concert}.values.sortedBy((concert) => concert.date);

    final known = {for (final concert in await saved()) concert.id};
    final file = await _file;
    final firstCheck = !await file.exists();
    await file.writeAsString(
      jsonEncode({
        "checked": DateTime.now().millisecondsSinceEpoch,
        "concerts": [for (final concert in concerts) concert.toJson()],
      }),
    );
    // The very first check would announce everything at once; only later announcements are news.
    if (notify && settings.notify && !firstCheck) {
      for (final concert in concerts.where((concert) => !known.contains(concert.id)).take(5)) {
        await _notify(concert);
      }
    }
    return concerts;
  }

  static Future<void> _notify(Concert concert) async {
    try {
      await _channel.invokeMethod("concert", {
        "id": concert.id.hashCode & 0x7fffffff,
        "title": concert.artist,
        "text": [
          concert.name,
          [concert.venue, concert.city].nonNulls.join(", "),
          "${concert.date.day}-${concert.date.month}-${concert.date.year}",
        ].where((part) => part.isNotEmpty).join(" · "),
        "url": concert.url,
      });
    } catch (e) {
      _logger.warning("Couldn't announce ${concert.name}", e);
    }
  }

  static Future<DateTime?> lastCheck() async {
    try {
      final file = await _file;
      if (!await file.exists()) return null;
      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return DateTime.fromMillisecondsSinceEpoch(json["checked"] as int);
    } catch (e) {
      return null;
    }
  }

  /// Checks now if it's been a while, and then every [checkEvery] while the app runs.
  static Future<void> initialize() async {
    Future<void> checkIfDue() async {
      final last = await lastCheck();
      if (last != null && DateTime.now().difference(last) < checkEvery) return;
      if ((await loadSettings()).apiKey == null) return;
      try {
        await check();
      } catch (e) {
        _logger.info("Concert check failed: $e");
      }
    }

    _timer?.cancel();
    _timer = Timer.periodic(const Duration(hours: 1), (_) => unawaited(checkIfDue()));
    await checkIfDue();
  }
}
