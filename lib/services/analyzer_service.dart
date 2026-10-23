import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// What the analyzer found out about a track: tempo, key and loudness, and (from analyzer version 2 on) where in the
/// song its sound starts and ends, its beats, and how intense it is. Times are in seconds from the song's start.
class TrackAnalysis {
  const TrackAnalysis({
    this.bpm,
    this.key,
    this.camelot,
    this.energy,
    this.duration,
    this.start,
    this.end,
    this.intro,
    this.outro,
    this.hidden,
    this.firstBeat,
    this.lastBeat,
    this.beatBpm,
    this.intensity,
  });

  factory TrackAnalysis.fromJson(Map<String, dynamic> json) {
    double? number(String name) => (json[name] as num?)?.toDouble();
    return TrackAnalysis(
      bpm: number("bpm"),
      key: json["key"] as String?,
      camelot: json["camelot"] as String?,
      energy: number("energy"),
      duration: number("duration"),
      start: number("start"),
      end: number("end"),
      intro: number("intro"),
      outro: number("outro"),
      hidden: number("hidden"),
      firstBeat: number("firstBeat"),
      lastBeat: number("lastBeat"),
      beatBpm: number("beatBpm"),
      intensity: number("intensity"),
    );
  }

  final double? bpm;
  final String? key;
  final String? camelot;
  final double? energy;
  final double? duration;

  /// Where the sound starts, after any silence.
  final double? start;

  /// Where the song's sound ends: before trailing silence, and before the silence ahead of a hidden track.
  final double? end;

  /// Where the intro reaches the song's usual level, and where the outro drops below it.
  final double? intro;
  final double? outro;

  /// Where a hidden track starts, after a long silence; null when there's none.
  final double? hidden;

  /// The first and last beat of the song's sound.
  final double? firstBeat;
  final double? lastBeat;

  /// The tempo the beats above were found at, over the whole song (rather than [bpm]'s excerpt).
  final double? beatBpm;

  /// From 0 (calm) to 1 (intense), compared with the rest of the library.
  final double? intensity;
}

/// The analyzer's check-up of the library. [complete] is false when the analyzer only measures loudness: then cut-off
/// songs, silent endings and duplicates aren't looked for.
typedef LibraryHealth = ({
  List<({String id, String reason})> broken,
  List<({String id, double duration, double decoded})> cutOff,
  List<({String id, double silence, bool hidden})> silentEndings,
  List<List<String>> duplicates,
  List<({String id, List<String> missing})> missingTags,
  bool complete,
});

typedef AnalyzerStatus = ({int analyzed, int failed, int missing, int total, bool scanning});

class AnalyzerException implements Exception {
  AnalyzerException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Talks to the Finamp+ analyzer, a small service running next to Jellyfin (see /analyzer in the repo)
/// that powers vibe search, DJ transitions and song recognition.
class AnalyzerService {
  AnalyzerService._();

  static const _urlKey = "analyzerUrl";
  static const _tokenKey = "analyzerToken";

  /// The most IDs /analysis processes per request, matching analyzer/app.py.
  static const analysisBatchSize = 2000;

  static String? _url;
  static String? _token;
  static final configurationChanges = StreamController<void>.broadcast();

  static Future<({String? url, String? token})> getSettings() async {
    final prefs = SharedPreferencesAsync();
    _url = await prefs.getString(_urlKey);
    _token = await prefs.getString(_tokenKey);
    return (url: _url, token: _token);
  }

  static Future<void> saveSettings({required String url, required String token}) async {
    final prefs = SharedPreferencesAsync();
    final trimmed = url.trim().replaceAll(RegExp(r"/+$"), "");
    if (trimmed.isEmpty) {
      await prefs.remove(_urlKey);
      await prefs.remove(_tokenKey);
    } else {
      await prefs.setString(_urlKey, trimmed);
      await prefs.setString(_tokenKey, token.trim());
    }
    _url = trimmed.isEmpty ? null : trimmed;
    _token = token.trim();
    configurationChanges.add(null);
  }

  static Future<bool> isConfigured() async => (await getSettings()).url != null;

  static Future<http.Response> _send(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final settings = await getSettings();
    if (settings.url == null) throw AnalyzerException("The Finamp+ analyzer isn't set up");
    final uri = Uri.parse("${settings.url}$path").replace(queryParameters: query);
    final headers = {"X-Api-Key": settings.token ?? ""};
    final request = switch (method) {
      "GET" => http.get(uri, headers: headers),
      _ => http.post(
        uri,
        headers: {...headers, if (body is! Uint8List) "Content-Type": "application/json"},
        body: body is Uint8List ? body : jsonEncode(body),
      ),
    };
    final response = await request.timeout(timeout);
    if (response.statusCode == 401) throw AnalyzerException("The analyzer rejected the token");
    if (response.statusCode >= 300) {
      String detail = response.body;
      try {
        detail = (jsonDecode(response.body) as Map<String, dynamic>)["detail"].toString();
      } catch (_) {}
      throw AnalyzerException("Analyzer error ${response.statusCode}: $detail");
    }
    return response;
  }

  static dynamic _json(http.Response response) => jsonDecode(utf8.decode(response.bodyBytes));

  static Future<AnalyzerStatus> status() async {
    final json = _json(await _send("GET", "/status", timeout: const Duration(seconds: 10))) as Map<String, dynamic>;
    return (
      analyzed: json["analyzed"] as int,
      failed: json["failed"] as int,
      missing: json["missing"] as int? ?? 0,
      total: json["total"] as int,
      scanning: json["scanning"] as bool,
    );
  }

  /// Track ids that sound like [description], best first.
  static Future<List<String>> vibe(String description, {int limit = 50}) async {
    // The first search loads the model, which can take a while.
    final response = await _send(
      "GET",
      "/vibe",
      query: {"q": description, "limit": "$limit"},
      timeout: const Duration(minutes: 2),
    );
    return [for (final result in (_json(response) as List).cast<Map<String, dynamic>>()) result["id"] as String];
  }

  /// Analysis for each of [ids] the analyzer knows.
  static Future<Map<String, TrackAnalysis>> analysis(List<String> ids) async {
    final result = <String, TrackAnalysis>{};
    for (final batch in ids.slices(analysisBatchSize)) {
      final json = _json(await _send("POST", "/analysis", body: {"ids": batch})) as Map<String, dynamic>;
      final found = {
        for (final MapEntry(:key, :value) in json.entries) key: TrackAnalysis.fromJson(value as Map<String, dynamic>),
      };
      result.addAll(found);
      final now = DateTime.now();
      // Only a successful batch tells us which of its tracks the analyzer doesn't know.
      for (final id in batch) {
        _cache[id] = (found[id], now);
      }
    }
    return result;
  }

  // Analysis asked for lately, including tracks the analyzer doesn't know (null), so playback can look it up for free.
  static final Map<String, (TrackAnalysis?, DateTime)> _cache = {};
  static const _cacheFor = Duration(hours: 1);

  /// Analysis for [ids] from the last hour's answers where possible, asking the analyzer for the rest. Never throws:
  /// tracks it can't get analysis for are left out.
  static Future<Map<String, TrackAnalysis>> cachedAnalysis(List<String> ids) async {
    final now = DateTime.now();
    final missing = [
      for (final id in ids)
        if (_cache[id] == null || now.difference(_cache[id]!.$2) > _cacheFor) id,
    ];
    if (missing.isNotEmpty && await isConfigured()) {
      try {
        await analysis(missing);
      } catch (_) {}
    }
    return {for (final id in ids) id: ?_cache[id]?.$1};
  }

  /// The analysis for [id] if it has been looked up lately, without asking the analyzer.
  static TrackAnalysis? cached(String id) => _cache[id]?.$1;

  /// Track ids that sound like the track [id], most alike first.
  static Future<List<String>> similar(String id, {int limit = 50}) async {
    final response = await _send("GET", "/similar", query: {"id": id, "limit": "$limit"});
    return [for (final result in (_json(response) as List).cast<Map<String, dynamic>>()) result["id"] as String];
  }

  /// A check-up of the library: files that can't be played or are cut off, songs with long silent endings or hidden
  /// tracks, the same recording on several albums, and missing tags.
  static Future<LibraryHealth> health() async {
    final json = _json(await _send("GET", "/health", timeout: const Duration(minutes: 3))) as Map<String, dynamic>;
    List<Map<String, dynamic>> list(String name) => (json[name] as List? ?? []).cast<Map<String, dynamic>>();
    return (
      broken: [for (final item in list("broken")) (id: item["id"] as String, reason: item["reason"] as String)],
      cutOff: [
        for (final item in list("cutOff"))
          (
            id: item["id"] as String,
            duration: (item["duration"] as num).toDouble(),
            decoded: (item["decoded"] as num).toDouble(),
          ),
      ],
      silentEndings: [
        for (final item in list("silentEndings"))
          (
            id: item["id"] as String,
            silence: (item["silence"] as num).toDouble(),
            hidden: item["hidden"] as bool? ?? false,
          ),
      ],
      duplicates: [for (final pair in (json["duplicates"] as List? ?? []).cast<List<dynamic>>()) pair.cast<String>()],
      missingTags: [
        for (final item in list("missingTags"))
          (id: item["id"] as String, missing: (item["missing"] as List).cast<String>()),
      ],
      complete: json["advancedAnalysis"] as bool? ?? false,
    );
  }

  static Future<Map<String, Map<String, dynamic>>> loudness(List<String> ids) async {
    final json =
        _json(await _send('POST', '/loudness', body: {'ids': ids}, timeout: const Duration(seconds: 5)))
            as Map<String, dynamic>;
    return json.map((key, value) => MapEntry(key, Map<String, dynamic>.from(value as Map)));
  }

  /// Identifies a recording of a song playing nearby. Returns the track id, or null if nothing matched.
  static Future<String?> identify(Uint8List recording) async {
    final json = _json(await _send("POST", "/identify", body: recording)) as Map<String, dynamic>;
    return json["id"] as String?;
  }
}
