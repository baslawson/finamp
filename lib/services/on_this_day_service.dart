import 'dart:async';
import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/finamp_user_helper.dart';
import 'package:finamp/services/jellyfin_api_helper.dart';
import 'package:finamp/services/library_matcher.dart';
import 'package:finamp/services/listening_log_service.dart';
import 'package:finamp/services/listenbrainz_client.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:finamp/services/scrobble_service.dart';
import 'package:get_it/get_it.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

/// A song played around this date in an earlier year. [trackId] is known when the play came from this library.
typedef PastPlay = ({String title, String artist, String? trackId, int plays});

/// What was played around this date in [year].
typedef OnThisDayYear = ({int year, List<PastPlay> songs});

/// "A year ago today you were playing…": songs from this date in earlier years, from the listening log on this
/// device, ListenBrainz and Last.fm (when scrobbling is set up) and the server's Playback Reporting plugin.
class OnThisDayService {
  OnThisDayService._();

  static final _logger = Logger("OnThisDayService");
  static const sourceId = "onThisDay";
  static const _yearsBack = 15;

  /// When nothing was played on the day itself, plays this many days around it count too.
  static const widerWindowDays = 3;

  static ({String day, List<OnThisDayYear> years, bool widened})? _cache;

  static String _dayKey(DateTime now) => "${now.year}-${now.month}-${now.day}";

  /// Whether [time] is within [windowDays] of [now]'s date in [time]'s (earlier) year.
  static bool isAround(DateTime time, DateTime now, int windowDays) {
    if (time.year >= now.year) return false;
    final anniversary = DateTime(time.year, now.month, now.day);
    final day = DateTime(time.year, time.month, time.day);
    return day.difference(anniversary).inDays.abs() <= windowDays;
  }

  /// Groups [plays] by year (most recent first) and song (most played first).
  static List<OnThisDayYear> group(List<({DateTime time, String title, String artist, String? trackId})> plays) {
    final byYear = groupBy(plays, (play) => play.time.year);
    return [
      for (final year in byYear.keys.sorted((a, b) => b.compareTo(a)))
        (
          year: year,
          songs: [
            for (final same in groupBy(
              byYear[year]!,
              (play) => "${LibraryMatcher.normalizeTitle(play.title)}|${play.artist.toLowerCase()}",
            ).values)
              (
                title: same.first.title,
                artist: same.first.artist,
                trackId: same.map((play) => play.trackId).nonNulls.firstOrNull,
                plays: same.length,
              ),
          ]..sort((a, b) => b.plays.compareTo(a.plays)),
        ),
    ];
  }

  /// Everything played around today in earlier years, from all sources. Cached for the day.
  static Future<({List<OnThisDayYear> years, bool widened})> load({DateTime? now}) async {
    now ??= DateTime.now();
    final cached = _cache;
    if (cached != null && cached.day == _dayKey(now)) return (years: cached.years, widened: cached.widened);

    Future<List<({DateTime time, String title, String artist, String? trackId})>> collect(int windowDays) async {
      final sources = await Future.wait([
        _fromLog(now!, windowDays),
        _fromListenBrainz(now, windowDays),
        _fromLastFm(now, windowDays),
        _fromPlaybackReporting(now, windowDays),
      ]);
      return sources.flattened.toList();
    }

    var widened = false;
    var plays = await collect(0);
    if (plays.length < 5) {
      widened = true;
      plays = await collect(widerWindowDays);
    }
    final years = group(plays);
    _cache = (day: _dayKey(now), years: years, widened: widened);
    return (years: years, widened: widened);
  }

  static Future<List<({DateTime time, String title, String artist, String? trackId})>> _fromLog(
    DateTime now,
    int windowDays,
  ) async {
    try {
      return [
        for (final listen in await ListeningLogService.load(forLearning: true))
          if (isAround(listen.time, now, windowDays))
            (time: listen.time, title: listen.track, artist: listen.artist ?? "", trackId: listen.trackId),
      ];
    } catch (e) {
      _logger.info("Couldn't read the listening log: $e");
      return [];
    }
  }

  /// The time ranges to ask the online services about, one per earlier year.
  static List<(DateTime, DateTime)> _ranges(DateTime now, int windowDays) => [
    for (var back = 1; back <= _yearsBack; back++)
      (
        DateTime(now.year - back, now.month, now.day - windowDays),
        DateTime(now.year - back, now.month, now.day + windowDays + 1),
      ),
  ];

  static Future<List<({DateTime time, String title, String artist, String? trackId})>> _fromListenBrainz(
    DateTime now,
    int windowDays,
  ) async {
    final user = (await ScrobbleService.loadSettings()).listenBrainzUser;
    if (user == null) return [];
    final results = await Future.wait([
      for (final (from, to) in _ranges(now, windowDays))
        () async {
          try {
            final uri = Uri.parse("${ScrobbleService.listenBrainzApi}/user/${Uri.encodeComponent(user)}/listens")
                .replace(
                  queryParameters: {
                    "min_ts": "${from.millisecondsSinceEpoch ~/ 1000}",
                    "max_ts": "${to.millisecondsSinceEpoch ~/ 1000}",
                    "count": "100",
                  },
                );
            final response = await ListenBrainzClient.shared.get(uri).timeout(const Duration(seconds: 30));
            if (response.statusCode != 200) {
              return const <({DateTime time, String title, String artist, String? trackId})>[];
            }
            final listens =
                ((jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>)["payload"]
                        as Map<String, dynamic>)["listens"]
                    as List<dynamic>;
            return [
              for (final listen in listens.cast<Map<String, dynamic>>())
                (
                  time: DateTime.fromMillisecondsSinceEpoch((listen["listened_at"] as int) * 1000),
                  title: (listen["track_metadata"] as Map<String, dynamic>)["track_name"] as String? ?? "",
                  artist: (listen["track_metadata"] as Map<String, dynamic>)["artist_name"] as String? ?? "",
                  trackId: null,
                ),
            ].where((play) => play.title.isNotEmpty && isAround(play.time, now, windowDays)).toList();
          } catch (e) {
            _logger.info("ListenBrainz history failed: $e");
            return const <({DateTime time, String title, String artist, String? trackId})>[];
          }
        }(),
    ]);
    return results.flattened.toList();
  }

  static Future<List<({DateTime time, String title, String artist, String? trackId})>> _fromLastFm(
    DateTime now,
    int windowDays,
  ) async {
    final reader = await ScrobbleService.lastFmReader();
    if (reader == null) return [];
    final results = await Future.wait([
      for (final (from, to) in _ranges(now, windowDays))
        () async {
          try {
            final uri = Uri.parse(ScrobbleService.lastFmApi).replace(
              queryParameters: {
                "method": "user.getrecenttracks",
                "user": reader.user,
                "api_key": reader.apiKey,
                "from": "${from.millisecondsSinceEpoch ~/ 1000}",
                "to": "${to.millisecondsSinceEpoch ~/ 1000}",
                "limit": "200",
                "format": "json",
              },
            );
            final response = await http.get(uri).timeout(const Duration(seconds: 15));
            if (response.statusCode != 200) {
              return const <({DateTime time, String title, String artist, String? trackId})>[];
            }
            final recent = (jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>)["recenttracks"];
            final tracks = recent is Map<String, dynamic> ? recent["track"] : null;
            // A single result comes as an object instead of a list.
            final list = tracks is List ? tracks : (tracks is Map ? [tracks] : const <dynamic>[]);
            return [
              for (final track in list.cast<Map<String, dynamic>>())
                if (track["date"] is Map)
                  (
                    time: DateTime.fromMillisecondsSinceEpoch(
                      int.parse((track["date"] as Map<String, dynamic>)["uts"] as String) * 1000,
                    ),
                    title: track["name"] as String? ?? "",
                    artist: (track["artist"] as Map<String, dynamic>?)?["#text"] as String? ?? "",
                    trackId: null,
                  ),
            ].where((play) => play.title.isNotEmpty && isAround(play.time, now, windowDays)).toList();
          } catch (e) {
            _logger.info("Last.fm history failed: $e");
            return const <({DateTime time, String title, String artist, String? trackId})>[];
          }
        }(),
    ]);
    return results.flattened.toList();
  }

  /// The Playback Reporting plugin keeps a play history on the server; its query endpoint needs an admin user,
  /// so this quietly gives nothing when the plugin is missing or not allowed.
  static Future<List<({DateTime time, String title, String artist, String? trackId})>> _fromPlaybackReporting(
    DateTime now,
    int windowDays,
  ) async {
    final user = GetIt.instance<FinampUserHelper>().currentUser;
    if (user == null) return [];
    try {
      final days = [
        for (var offset = -windowDays; offset <= windowDays; offset++)
          () {
            final day = DateTime(2000, now.month, now.day + offset);
            return "'${day.month.toString().padLeft(2, "0")}-${day.day.toString().padLeft(2, "0")}'";
          }(),
      ];
      final query =
          "SELECT ItemId, DateCreated FROM PlaybackActivity WHERE ItemType = 'Audio' "
          "AND UserId = '${user.id.replaceAll("-", "")}' "
          "AND strftime('%m-%d', DateCreated) IN (${days.join(",")}) "
          "AND DateCreated < '${now.year}-01-01' ORDER BY DateCreated DESC LIMIT 2000";
      final base = user.baseURL.endsWith("/") ? user.baseURL : "${user.baseURL}/";
      final response = await http
          .post(
            Uri.parse("${base}user_usage_stats/submit_custom_query"),
            headers: {"Content-Type": "application/json", "Authorization": 'MediaBrowser Token="${user.accessToken}"'},
            body: jsonEncode({"CustomQueryString": query, "ReplaceUserId": false}),
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) return [];
      final rows = ((jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>)["results"] as List<dynamic>)
          .cast<List<dynamic>>();
      final played = [
        for (final row in rows)
          if (DateTime.tryParse(row[1] as String) case final time?) (id: row[0] as String, time: time),
      ];
      if (played.isEmpty) return [];
      final items =
          await GetIt.instance<JellyfinApiHelper>().getItems(
            itemIds: played.map((play) => BaseItemId(play.id)).toSet().toList(),
          ) ??
          [];
      final byId = {for (final item in items) item.id.raw: item};
      return [
        for (final play in played)
          if (byId[play.id] case final item?)
            (
              time: play.time,
              title: item.name ?? "",
              artist: item.albumArtist ?? item.artists?.firstOrNull ?? "",
              trackId: item.id.raw,
            ),
      ];
    } catch (e) {
      _logger.info("Playback Reporting history unavailable: $e");
      return [];
    }
  }

  /// Library tracks for [songs] (most played first), looking up the ones that came from other services.
  static Future<List<BaseItemDto>> resolve(List<PastPlay> songs, {int limit = 50}) async {
    final api = GetIt.instance<JellyfinApiHelper>();
    final chosen = songs.take(limit * 2).toList();
    final known = {
      for (final item
          in await api.getItems(
                itemIds: [
                  for (final song in chosen)
                    if (song.trackId != null) BaseItemId(song.trackId!),
                ],
              ) ??
              <BaseItemDto>[])
        item.id.raw: item,
    };
    final unknown = [
      for (final song in chosen)
        if (song.trackId == null || !known.containsKey(song.trackId)) song,
    ];
    final found = await LibraryMatcher.findAll([
      for (final song in unknown) SongRef(title: song.title, artist: song.artist),
    ]);
    final foundBySong = {for (final (index, song) in unknown.indexed) song: found[index]};
    final seen = <String>{};
    return [
      for (final song in chosen)
        if ((known[song.trackId] ?? foundBySong[song]) case final track? when seen.add(track.id.raw)) track,
    ].take(limit).toList();
  }

  /// Plays [songs] (or everything from today in earlier years). Returns false when there's nothing to play.
  static Future<bool> play({List<PastPlay>? songs, required String name}) async {
    final all = songs ?? [for (final year in (await load()).years) ...year.songs]
      ..sort((a, b) => b.plays.compareTo(a.plays));
    if (all.isEmpty) return false;
    final tracks = await resolve(all);
    if (tracks.isEmpty) return false;
    await GetIt.instance<QueueService>().startPlayback(
      items: tracks,
      source: QueueItemSource.rawId(
        type: QueueItemSourceType.unknown,
        name: QueueItemSourceName(type: QueueItemSourceNameType.preTranslated, pretranslatedName: name),
        id: sourceId,
      ),
      order: FinampPlaybackOrder.linear,
    );
    return true;
  }
}
