import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:finamp/services/listening_log_service.dart';
import 'package:finamp/services/listenbrainz_client.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ScrobbleException implements Exception {
  ScrobbleException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A listen waiting to be sent, with the services it still has to reach.
class PendingScrobble {
  PendingScrobble({
    required this.time,
    required this.track,
    required this.artist,
    this.album,
    this.duration,
    required this.listenBrainz,
    required this.lastFm,
  });

  final DateTime time;
  final String track;
  final String artist;
  final String? album;
  final Duration? duration;
  bool listenBrainz;
  bool lastFm;

  factory PendingScrobble.fromJson(Map<String, dynamic> json) => PendingScrobble(
    time: DateTime.fromMillisecondsSinceEpoch(json["t"] as int),
    track: json["n"] as String,
    artist: json["ar"] as String,
    album: json["al"] as String?,
    duration: json["ms"] == null ? null : Duration(milliseconds: json["ms"] as int),
    listenBrainz: json["lb"] as bool? ?? false,
    lastFm: json["lf"] as bool? ?? false,
  );

  Map<String, dynamic> toJson() => {
    "t": time.millisecondsSinceEpoch,
    "n": track,
    "ar": artist,
    if (album != null) "al": album,
    if (duration != null) "ms": duration!.inMilliseconds,
    "lb": listenBrainz,
    "lf": lastFm,
  };
}

typedef ScrobbleSettings = ({
  String? listenBrainzToken,
  String? listenBrainzUser,
  String? lastFmUser,
  bool lastFmReady,
});

/// Sends listens to ListenBrainz and Last.fm. Listens are queued on the device first, so nothing is lost offline.
class ScrobbleService {
  ScrobbleService._();

  static final _logger = Logger("ScrobbleService");
  static const _lbTokenKey = "scrobbleListenBrainzToken";
  static const _lbUserKey = "scrobbleListenBrainzUser";
  static const _lfApiKeyKey = "scrobbleLastFmApiKey";
  static const _lfSecretKey = "scrobbleLastFmSecret";
  static const _lfSessionKey = "scrobbleLastFmSession";
  static const _lfUserKey = "scrobbleLastFmUser";
  static const _lastFmApi = "https://ws.audioscrobbler.com/2.0/";
  static const _listenBrainzApi = "https://api.listenbrainz.org/1";

  /// Serializes queue changes and flushes.
  static Future<void> _pending = Future.value();

  static Future<File> get _queueFile async =>
      File("${(await getApplicationSupportDirectory()).path}/scrobble_queue.jsonl");

  static Future<ScrobbleSettings> loadSettings() async {
    final prefs = SharedPreferencesAsync();
    return (
      listenBrainzToken: await prefs.getString(_lbTokenKey),
      listenBrainzUser: await prefs.getString(_lbUserKey),
      lastFmUser: await prefs.getString(_lfUserKey),
      lastFmReady: await prefs.getString(_lfSessionKey) != null,
    );
  }

  /// The Last.fm API key and user name, for reading listening history.
  static Future<({String apiKey, String user})?> lastFmReader() async {
    final prefs = SharedPreferencesAsync();
    final apiKey = await prefs.getString(_lfApiKeyKey);
    final user = await prefs.getString(_lfUserKey);
    return apiKey == null || user == null ? null : (apiKey: apiKey, user: user);
  }

  static String get lastFmApi => _lastFmApi;
  static String get listenBrainzApi => _listenBrainzApi;

  /// Whether a listen counts as a scrobble: half the track or four minutes, for tracks over 30 seconds.
  static bool qualifies(Duration listened, Duration? length) {
    if (length == null) return listened >= const Duration(minutes: 4);
    if (length <= const Duration(seconds: 30)) return false;
    final needed = length ~/ 2 < const Duration(minutes: 4) ? length ~/ 2 : const Duration(minutes: 4);
    return listened >= needed;
  }

  /// Queues [entry] for each connected service and tries to send it.
  static void onListen(ListenEntry entry, Duration? length) {
    final artist = entry.artist;
    if (artist == null || entry.track.isEmpty || !qualifies(entry.listened, length)) return;
    _pending = _pending.then((_) async {
      try {
        final settings = await loadSettings();
        if (settings.listenBrainzToken == null && !settings.lastFmReady) return;
        final scrobble = PendingScrobble(
          time: entry.time,
          track: entry.track,
          artist: artist,
          album: entry.album,
          duration: length,
          listenBrainz: settings.listenBrainzToken != null,
          lastFm: settings.lastFmReady,
        );
        await (await _queueFile).writeAsString(
          "${jsonEncode(scrobble.toJson())}\n",
          mode: FileMode.append,
          flush: true,
        );
        await _flush();
      } catch (e) {
        _logger.warning("Failed to queue scrobble of '${entry.track}'", e);
      }
    });
  }

  /// Sends queued listens, e.g. after the app was offline.
  static Future<void> flush() => _pending = _pending.then((_) => _flush());

  static Future<int> pendingCount() async {
    final file = await _queueFile;
    if (!await file.exists()) return 0;
    return (await file.readAsLines()).where((line) => line.trim().isNotEmpty).length;
  }

  static Future<void> _flush() async {
    final file = await _queueFile;
    if (!await file.exists()) return;
    final queue = <PendingScrobble>[];
    for (final line in await file.readAsLines()) {
      if (line.trim().isEmpty) continue;
      try {
        queue.add(PendingScrobble.fromJson(jsonDecode(line) as Map<String, dynamic>));
      } catch (_) {
        // Skip a line cut short by the app being killed mid-write.
      }
    }
    final prefs = SharedPreferencesAsync();
    final lbToken = await prefs.getString(_lbTokenKey);
    final lfSession = await prefs.getString(_lfSessionKey);

    // A service that was disconnected drops its part of the queue.
    for (final scrobble in queue) {
      scrobble.listenBrainz &= lbToken != null;
      scrobble.lastFm &= lfSession != null;
    }
    // Each service is tried on its own, so one being down doesn't hold up the other.
    if (lbToken != null) {
      final batch = queue.where((scrobble) => scrobble.listenBrainz).take(100).toList();
      try {
        if (batch.isNotEmpty) await _submitListenBrainz(lbToken, batch);
        for (final scrobble in batch) {
          scrobble.listenBrainz = false;
        }
      } catch (e) {
        _logger.info("ListenBrainz submit failed, will retry later: $e");
      }
    }
    if (lfSession != null) {
      final batch = queue.where((scrobble) => scrobble.lastFm).take(50).toList();
      try {
        if (batch.isNotEmpty) await _submitLastFm(lfSession, batch);
        for (final scrobble in batch) {
          scrobble.lastFm = false;
        }
      } catch (e) {
        _logger.info("Last.fm submit failed, will retry later: $e");
      }
    }
    final remaining = queue.where((scrobble) => scrobble.listenBrainz || scrobble.lastFm);
    await file.writeAsString(remaining.map((scrobble) => "${jsonEncode(scrobble.toJson())}\n").join(), flush: true);
  }

  // ListenBrainz

  /// Checks [token] and saves it. Returns the ListenBrainz user name.
  static Future<String> connectListenBrainz(String token) async {
    final response = await ListenBrainzClient.shared
        .get(Uri.parse("$_listenBrainzApi/validate-token"), token: token)
        .timeout(const Duration(seconds: 15));
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode != 200 || json["valid"] != true) {
      throw ScrobbleException("ListenBrainz didn't accept this token");
    }
    final user = json["user_name"] as String;
    final prefs = SharedPreferencesAsync();
    await prefs.setString(_lbTokenKey, token.trim());
    await prefs.setString(_lbUserKey, user);
    return user;
  }

  static Future<void> disconnectListenBrainz() async {
    final prefs = SharedPreferencesAsync();
    await prefs.remove(_lbTokenKey);
    await prefs.remove(_lbUserKey);
  }

  static Future<void> _submitListenBrainz(String token, List<PendingScrobble> batch) async {
    final body = {
      "listen_type": batch.length == 1 ? "single" : "import",
      "payload": [
        for (final scrobble in batch)
          {
            "listened_at": scrobble.time.millisecondsSinceEpoch ~/ 1000,
            "track_metadata": {
              "artist_name": scrobble.artist,
              "track_name": scrobble.track,
              if (scrobble.album != null) "release_name": scrobble.album,
              "additional_info": {
                "media_player": "Finamp+",
                "submission_client": "Finamp+",
                if (scrobble.duration != null) "duration_ms": scrobble.duration!.inMilliseconds,
              },
            },
          },
      ],
    };
    final response = await ListenBrainzClient.shared
        .post(Uri.parse("$_listenBrainzApi/submit-listens"), token: token, body: jsonEncode(body))
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw ScrobbleException("ListenBrainz error ${response.statusCode}");
    }
    _logger.info("Sent ${batch.length} listens to ListenBrainz");
  }

  // Last.fm

  /// Signs Last.fm API parameters as described in https://www.last.fm/api/authspec.
  static String lastFmSignature(Map<String, String> params, String secret) {
    final keys = params.keys.where((key) => key != "format" && key != "callback").toList()..sort();
    final text = "${keys.map((key) => "$key${params[key]}").join()}$secret";
    return md5.convert(utf8.encode(text)).toString();
  }

  static Future<Map<String, dynamic>> _callLastFm(Map<String, String> params, String secret) async {
    final signed = {...params, "api_sig": lastFmSignature(params, secret), "format": "json"};
    final response = await http.post(Uri.parse(_lastFmApi), body: signed).timeout(const Duration(seconds: 20));
    final json = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    if (json["error"] != null) throw ScrobbleException("Last.fm: ${json["message"]}");
    if (response.statusCode != 200) throw ScrobbleException("Last.fm error ${response.statusCode}");
    return json;
  }

  /// Logs in to Last.fm with the user's own API account, keeping only the session, never the password.
  static Future<void> connectLastFm({
    required String apiKey,
    required String secret,
    required String username,
    required String password,
  }) async {
    final json = await _callLastFm({
      "method": "auth.getMobileSession",
      "api_key": apiKey.trim(),
      "username": username.trim(),
      "password": password,
    }, secret.trim());
    final session = (json["session"] as Map<String, dynamic>)["key"] as String;
    final prefs = SharedPreferencesAsync();
    await prefs.setString(_lfApiKeyKey, apiKey.trim());
    await prefs.setString(_lfSecretKey, secret.trim());
    await prefs.setString(_lfSessionKey, session);
    await prefs.setString(_lfUserKey, (json["session"] as Map<String, dynamic>)["name"] as String? ?? username.trim());
  }

  static Future<void> disconnectLastFm() async {
    final prefs = SharedPreferencesAsync();
    for (final key in [_lfApiKeyKey, _lfSecretKey, _lfSessionKey, _lfUserKey]) {
      await prefs.remove(key);
    }
  }

  static Future<void> _submitLastFm(String session, List<PendingScrobble> batch) async {
    final prefs = SharedPreferencesAsync();
    final apiKey = await prefs.getString(_lfApiKeyKey);
    final secret = await prefs.getString(_lfSecretKey);
    if (apiKey == null || secret == null) throw ScrobbleException("Last.fm isn't set up");
    final params = {"method": "track.scrobble", "api_key": apiKey, "sk": session};
    for (final (index, scrobble) in batch.indexed) {
      params["artist[$index]"] = scrobble.artist;
      params["track[$index]"] = scrobble.track;
      params["timestamp[$index]"] = "${scrobble.time.millisecondsSinceEpoch ~/ 1000}";
      if (scrobble.album != null) params["album[$index]"] = scrobble.album!;
      if (scrobble.duration != null) params["duration[$index]"] = "${scrobble.duration!.inSeconds}";
    }
    await _callLastFm(params, secret);
    _logger.info("Sent ${batch.length} scrobbles to Last.fm");
  }
}
