import 'dart:convert';

import 'package:finamp/models/jellyfin_models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

/// LRCLIB lyrics for a track. Kept separate from the metadata so a slow LRCLIB never holds up playback info.
final lrclibLyricsProvider = FutureProvider.autoDispose.family<LyricDto?, BaseItemDto>((ref, item) async {
  final lyrics = await LrclibService.getLyrics(item);
  ref.keepAlive();
  return lyrics;
});

/// Fetches lyrics from LRCLIB (https://lrclib.net) for tracks the server has none for.
class LrclibService {
  LrclibService._();

  static final _logger = Logger("LrclibService");
  static const _headers = {"User-Agent": "Finamp+ (https://github.com/baslawson/finamp)"};

  /// Returns lyrics for [item], preferring synced ones, or null if LRCLIB has none.
  static Future<LyricDto?> getLyrics(BaseItemDto item) async {
    final title = item.name;
    final artist = item.albumArtist ?? item.artists?.firstOrNull;
    if (title == null || artist == null) return null;

    try {
      final seconds = item.runTimeTicks == null ? null : item.runTimeTicks! ~/ 10000000;
      var result = await _get("/api/get", {
        "track_name": title,
        "artist_name": artist,
        if (item.album != null) "album_name": item.album!,
        if (seconds != null) "duration": "$seconds",
      });
      if (result == null) {
        // The exact match needs the duration to be within a few seconds, so fall back to a search.
        final matches = await _get("/api/search", {"track_name": title, "artist_name": artist});
        if (matches is List && matches.isNotEmpty) {
          result = matches.cast<Map<String, dynamic>>().firstWhere(
            (match) => match["syncedLyrics"] != null,
            orElse: () => matches.first as Map<String, dynamic>,
          );
        }
      }
      if (result is! Map<String, dynamic> || result["instrumental"] == true) return null;

      final synced = result["syncedLyrics"] as String?;
      final plain = result["plainLyrics"] as String?;
      final lines = synced != null && synced.trim().isNotEmpty
          ? parseLrc(synced)
          : plain?.split("\n").map((line) => LyricLine(text: line.trim())).toList();
      if (lines == null || lines.isEmpty) return null;
      _logger.fine("Got ${synced != null ? "synced" : "plain"} LRCLIB lyrics for '$title'");
      return LyricDto(
        metadata: LyricMetadata(title: title, artist: artist, isSynced: synced != null),
        lyrics: lines,
      );
    } catch (e) {
      _logger.warning("Failed to fetch LRCLIB lyrics for '$title'", e);
      return null;
    }
  }

  /// The plain lyrics LRCLIB has for a song, or null.
  static Future<String?> plainLyrics(String title, String artist) async {
    try {
      final matches = await _get("/api/search", {"track_name": title, "artist_name": artist});
      if (matches is! List) return null;
      return matches.cast<Map<String, dynamic>>().map((match) => match["plainLyrics"] as String?).nonNulls.firstOrNull;
    } catch (e) {
      _logger.info("LRCLIB lookup of '$title' failed: $e");
      return null;
    }
  }

  static Future<dynamic> _get(String path, Map<String, String> query, {bool retry = true}) async {
    final response = await http
        .get(Uri.https("lrclib.net", path, query), headers: _headers)
        .timeout(const Duration(seconds: 8));
    if (response.statusCode == 404) return null;
    if (response.statusCode == 503 && retry) {
      // LRCLIB sheds load with 503s now and then; one delayed retry usually gets through.
      await Future<void>.delayed(const Duration(seconds: 2));
      return _get(path, query, retry: false);
    }
    if (response.statusCode != 200) throw Exception("LRCLIB returned ${response.statusCode}");
    return jsonDecode(utf8.decode(response.bodyBytes));
  }

  static final _lineTag = RegExp(r"\[(\d+):(\d+(?:\.\d+)?)\]");
  static final _wordTag = RegExp(r"<(\d+):(\d+(?:\.\d+)?)>");

  static int _ticks(String minutes, String seconds) =>
      ((int.parse(minutes) * 60 + double.parse(seconds)) * 10000000).round();

  /// Parses LRC, including enhanced LRC word timings (`<mm:ss.xx>`), into lyric lines with cues.
  static List<LyricLine> parseLrc(String lrc) {
    final lines = <LyricLine>[];
    for (final raw in lrc.split("\n")) {
      final tags = _lineTag.allMatches(raw).toList();
      if (tags.isEmpty) continue;
      final body = raw.substring(tags.last.end);

      final text = StringBuffer();
      final cues = <LyricLineCue>[];
      var position = 0;
      for (final word in _wordTag.allMatches(body)) {
        text.write(body.substring(position, word.start));
        if (cues.isNotEmpty) cues.last.endPosition = text.length;
        cues.add(LyricLineCue(position: text.length, start: _ticks(word.group(1)!, word.group(2)!)));
        position = word.end;
      }
      text.write(body.substring(position));
      final line = text.toString().trim();
      final leading = text.toString().length - text.toString().trimLeft().length;
      final shifted = [
        for (final cue in cues)
          if (cue.position - leading < line.length)
            LyricLineCue(
              position: (cue.position - leading).clamp(0, line.length),
              start: cue.start,
              endPosition: cue.endPosition == null ? null : (cue.endPosition! - leading).clamp(0, line.length),
            ),
      ];

      // A line can carry several timestamps when it repeats.
      for (final tag in tags) {
        lines.add(
          LyricLine(text: line, start: _ticks(tag.group(1)!, tag.group(2)!), cues: shifted.isEmpty ? null : shifted),
        );
      }
    }
    return lines..sort((a, b) => a.start!.compareTo(b.start!));
  }
}
