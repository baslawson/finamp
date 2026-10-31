import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/ai_service.dart';
import 'package:finamp/services/library_matcher.dart';
import 'package:finamp/services/lrclib_service.dart';
import 'package:logging/logging.dart';

/// A song that has the lyrics the user remembered.
class LyricsMatch {
  LyricsMatch({required this.song, this.line, required this.verified, this.track});

  final SongRef song;

  /// The actual lyric line, as the AI remembers it.
  final String? line;

  /// Whether LRCLIB's lyrics for the song contain the words searched for.
  final bool verified;

  /// The song in the library, if it's there.
  final BaseItemDto? track;
}

/// Finds songs from a remembered line of lyrics: the AI names the likely songs, LRCLIB confirms the line is in
/// them, and the library matcher finds them in the user's library.
class LyricsSearchService {
  LyricsSearchService._();

  static final _logger = Logger("LyricsSearchService");

  /// The words of [text] that are worth comparing, lower-cased and without punctuation.
  static List<String> words(String text) => text
      .toLowerCase()
      .replaceAll(RegExp(r"[’']"), "")
      .split(RegExp(r"[^\p{L}\p{N}]+", unicode: true))
      .where((word) => word.length > 1)
      .toList();

  /// Whether [lyrics] contain most of the words of [query] close together, so a slightly misremembered
  /// line still counts.
  static bool containsLine(String lyrics, String query) {
    final wanted = words(query);
    if (wanted.isEmpty) return false;
    final text = words(lyrics);
    final window = wanted.length + 4;
    for (var start = 0; start < text.length; start++) {
      final slice = text.sublist(start, (start + window).clamp(0, text.length)).toSet();
      final hits = wanted.where(slice.contains).length;
      if (hits >= (wanted.length * 0.75).ceil()) return true;
    }
    return false;
  }

  static Future<List<LyricsMatch>> search(String lyrics) async {
    final result = await AiService.generateJson(
      prompt:
          '''
Someone remembers these song lyrics, possibly slightly wrong or incomplete:

"${lyrics.replaceAll('"', "'")}"

Which songs contain them? Give up to 5 candidates, most likely first. For each, give the song title, the main artist of the best-known recording, and the actual lyric line. Only list real songs you're confident contain these or very similar lyrics.''',
      schemaName: "songs",
      schema: {
        "type": "object",
        "properties": {
          "songs": {
            "type": "array",
            "items": {
              "type": "object",
              "properties": {
                "title": {"type": "string"},
                "artist": {"type": "string"},
                "line": {"type": "string", "description": "The actual lyric line"},
              },
              "required": ["title", "artist", "line"],
              "additionalProperties": false,
            },
          },
        },
        "required": ["songs"],
        "additionalProperties": false,
      },
    );
    final candidates = [
      for (final song in (result["songs"] as List? ?? []).cast<Map<String, dynamic>>())
        if (song["title"] is String && song["artist"] is String)
          (
            song: SongRef(title: song["title"] as String, artist: song["artist"] as String),
            line: song["line"] as String?,
          ),
    ];
    final matches = await Future.wait([
      for (final candidate in candidates)
        () async {
          final (plain, track) = await (
            LrclibService.plainLyrics(candidate.song.title, candidate.song.artist),
            LibraryMatcher.find(candidate.song),
          ).wait;
          return LyricsMatch(
            song: candidate.song,
            line: candidate.line,
            verified: plain != null && containsLine(plain, lyrics),
            track: track,
          );
        }(),
    ]);
    _logger.info(
      "Lyrics search found ${matches.length} songs, ${matches.where((match) => match.track != null).length} in the library",
    );
    // Confirmed songs first, then those in the library, keeping the AI's order otherwise.
    int rank(LyricsMatch match) => (match.verified ? 0 : 2) + (match.track != null ? 0 : 1);
    final ranked = matches.indexed.toList()
      ..sort((a, b) => rank(a.$2) != rank(b.$2) ? rank(a.$2) - rank(b.$2) : a.$1 - b.$1);
    return [for (final (_, match) in ranked) match];
  }
}
