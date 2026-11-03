import 'package:collection/collection.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/finamp_user_helper.dart';
import 'package:finamp/services/jellyfin_api_helper.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';

/// A song from outside the library, e.g. from another service's playlist.
class SongRef {
  const SongRef({required this.title, required this.artist});

  final String title;

  /// One or more artists, as the source wrote them ("A, B" or "A & B feat. C").
  final String artist;

  @override
  String toString() => "$artist – $title";
}

/// Finds songs from elsewhere in the Jellyfin library, tolerating the usual differences in how titles and artists
/// are written ("(feat. X)", "- Remastered 2011", "&" versus ",").
class LibraryMatcher {
  LibraryMatcher._();

  static final _logger = Logger("LibraryMatcher");

  /// Lower-cased [title] without featured artists, version suffixes, brackets and punctuation.
  static String normalizeTitle(String title) => title
      .toLowerCase()
      .replaceAll(RegExp(r"[(\[].*?[)\]]"), " ")
      .replaceAll(
        RegExp(r"\s+-\s+.*(remaster|version|edit|mix|live|mono|stereo|demo|acoustic|feat).*$", caseSensitive: false),
        " ",
      )
      .replaceAll(RegExp(r"\b(feat|ft|featuring)\b.*$"), " ")
      .replaceAll("&", " and ")
      .replaceAll(RegExp(r"[’'`]"), "")
      .replaceAll(RegExp(r"[^\p{L}\p{N}]+", unicode: true), " ")
      .trim();

  /// The individual artists in [artist], normalized.
  static Set<String> splitArtists(String artist) => artist
      .toLowerCase()
      .split(RegExp(r",|;|&|\band\b|\bx\b|\bfeat\.?|\bft\.?|\bfeaturing\b|\bwith\b|/"))
      .map((name) => name.replaceAll(RegExp(r"^the\s+"), "").replaceAll(RegExp(r"[^\p{L}\p{N}]+", unicode: true), ""))
      .where((name) => name.isNotEmpty)
      .toSet();

  /// How well [track] fits [song], from 0 (no match) up; 0 unless both title and an artist match.
  static double score(SongRef song, BaseItemDto track) {
    final wanted = normalizeTitle(song.title);
    final title = normalizeTitle(track.name ?? "");
    if (wanted.isEmpty || title.isEmpty) return 0;
    final double titleScore = title == wanted
        ? 1.0
        : (title.startsWith(wanted) || wanted.startsWith(title))
        ? 0.7
        : 0.0;
    if (titleScore == 0) return 0;

    final wantedArtists = splitArtists(song.artist);
    final trackArtists = {
      ...splitArtists(track.albumArtist ?? ""),
      for (final artist in track.artists ?? <String>[]) ...splitArtists(artist),
    };
    if (wantedArtists.isEmpty) return titleScore * 0.8;
    if (wantedArtists.intersection(trackArtists).isEmpty) return 0;
    // Prefer studio versions over live recordings and remixes when there's a choice.
    final variant = RegExp(r"\b(live|remix|karaoke|instrumental|demo)\b", caseSensitive: false);
    final penalty = variant.hasMatch(track.name ?? "") && !variant.hasMatch(song.title) ? 0.2 : 0.0;
    return titleScore - penalty;
  }

  /// The best library track for [song], or null.
  static Future<BaseItemDto?> find(SongRef song) async {
    final api = GetIt.instance<JellyfinApiHelper>();
    final library = GetIt.instance<FinampUserHelper>().currentUser?.currentView;
    final cleaned = normalizeTitle(song.title);
    if (cleaned.isEmpty) return null;
    // Jellyfin matches the search term against the start of words, so fall back to fewer words for long titles.
    final words = cleaned.split(" ");
    for (final term in {cleaned, words.take(3).join(" ")}) {
      try {
        final results =
            await api.getItems(
              parentItem: library,
              includeItemTypes: BaseItemDtoType.track.jellyfinName,
              searchTerm: term,
              recursive: true,
              limit: 40,
            ) ??
            [];
        final best = results
            .map((track) => (track: track, score: score(song, track)))
            .where((candidate) => candidate.score >= 0.5)
            .sortedBy<num>((candidate) => -candidate.score)
            .firstOrNull;
        if (best != null) return best.track;
      } catch (e) {
        _logger.info("Searching for $song failed: $e");
      }
    }
    return null;
  }

  /// Matches [songs] in parallel, keeping their order. [onProgress] gets the number done so far.
  static Future<List<BaseItemDto?>> findAll(List<SongRef> songs, {void Function(int done)? onProgress}) async {
    final results = List<BaseItemDto?>.filled(songs.length, null);
    var done = 0;
    for (final batch in songs.indexed.slices(6)) {
      await Future.wait([
        for (final (index, song) in batch)
          find(song).then((track) {
            results[index] = track;
            onProgress?.call(++done);
          }),
      ]);
    }
    return results;
  }
}
