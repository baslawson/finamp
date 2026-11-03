import 'dart:math';

import 'package:collection/collection.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/library_health_service.dart';

/// Words that mark a part of a title as a version of the song ("Hey Jude - Remastered 2009", "Song - X-Press 2
/// Remix", "Wonderwall (Live)").
const _versionWords =
    r"\b(?:remaster\w*|live|demo|remix|mix|edit|version|acoustic|mono|stereo|instrumental|rehearsal|session|unplugged|"
    r"reprise|outtake|alternate|extended)\b";

final _versionWord = RegExp(_versionWords, caseSensitive: false);

const _sectionLabel =
    r"(?:parts?|pts?|nos?|nr|numbers?|vols?|volumes?|movements?|mvts?|acts?|scenes?|chapters?|books?|op|opus|bwv|k|d|hob)"
    r"\.?\s*(?:\d+|[ivxlc]+|one|two|three|four|five|six|seven|eight|nine|ten)\b(?:\s*[-–]\s*(?:\d+|[ivxlc]+)\b)?";

/// A numbered section anywhere in a version tag ("Part 1 Live", "Parts I-III Live"), which is kept.
final _section = RegExp("\\b$_sectionLabel", caseSensitive: false);

/// A bare number starting the text: "II", "2:", "I. Adagio", "I-V", or an undotted Roman numeral before a name
/// ("XIX Allegro"), though not "I" ("(I Can't Get No) Satisfaction").
const _sectionNumber =
    r"(?:\d+|[ivxlc]+)(?:[.:]|\s*$|\s*[-–]\s*(?:\d+|[ivxlc]+)\b)|(?!i\s)(?=[ivxl])l?x{0,3}(?:ix|iv|v?i{0,3})\s+\S";

/// Text that tells songs apart rather than versions, by starting with a number: "Part 2", "Part 1: Sunrise",
/// "Parts I-V", "No. 1", "II", "I. Adagio sostenuto", "XIX Allegro", "Act 3".
final _identifying = RegExp("^\\s*(?:$_sectionLabel|$_sectionNumber)", caseSensitive: false);

/// Words marking bracketed text as a credit or release tag rather than part of the name: "(feat. …)", "(Explicit)",
/// "(Bonus Track)", "(2011)". Not "(From …)", which can tell works apart ("Main Title (From "Jaws")").
final _tagWord = RegExp(
  r"\b(?:feat|ft|featuring|with|explicit|clean|bonus|deluxe|single|radio|original|prod|produced|duet|cover|"
  r"karaoke|vs|x|bbc|\d{4})\b",
  caseSensitive: false,
);

final _brackets = RegExp(r"\(([^)]*)\)|\[([^\]]*)\]|\{([^}]*)\}");
final _dash = RegExp(r"\s+-\s+");

/// What stays of [text], a bracket's contents or a version part after " - ": a numbered section starting it keeps its
/// number and name but not a version after them ("Part 2 Live", "I. Allegro Live"); otherwise only numbered sections
/// in it stay ("Live - Part 1"), so a plain tag ("Live", "feat. …") goes.
String _numberedPart(String text) => _identifying.hasMatch(text)
    ? text.substring(0, _versionWord.firstMatch(text)?.start ?? text.length)
    : _section.allMatches(text).map((section) => section[0]).join(" ");

/// [text] without the parts after " - " that are version tags ("Song - Live - Remastered 2009", "Suite - Live -
/// Part 1"), keeping the ones that aren't ("Love - Part 2").
String _withoutVersionParts(String text) {
  final parts = text.split(_dash);
  return [
    parts.first,
    for (final part in parts.skip(1)) _versionWord.hasMatch(part) ? _numberedPart(part) : part,
  ].join(" ");
}

/// [title] without what tells versions apart: text in brackets ("(Live)", "[Demo]", "(feat. …)") unless it numbers
/// a part, and version tags after " - ". A title that is all brackets, like "(Nice Dream) (Live)", keeps the first
/// as its name.
String versionlessTitle(String title) {
  final bare = _withoutVersionParts(
    title.replaceAllMapped(_brackets, (match) {
      final text = match[1] ?? match[2] ?? match[3] ?? "";
      // Brackets that tell songs apart rather than versions stay ("Peace (A Beginning)", "Peace (An End)"), but not a
      // version or credit tag, or a leading alternative name ("(I Can't Get No) Satisfaction").
      final leading = title.substring(0, match.start).trim().isEmpty;
      final tag = leading || _versionWord.hasMatch(text) || _tagWord.hasMatch(text);
      return " ${tag ? _numberedPart(text) : text} ";
    }),
  );
  final clean = LibraryHealthService.duplicateTitle(bare);
  // Nothing named outside brackets ("(Nice Dream) (Part 1)"): the first bracket is the name.
  final named = LibraryHealthService.duplicateTitle(_withoutVersionParts(title.replaceAll(_brackets, " ")));
  if (clean.isNotEmpty && named.isNotEmpty) return clean;
  final opened = title.replaceFirstMapped(_brackets, (match) => " ${match[1] ?? match[2] ?? match[3] ?? ""} ");
  return opened == title ? LibraryHealthService.duplicateTitle(title) : versionlessTitle(opened);
}

/// The title two tracks must share to be the same song: the title without its version tags.
String songKey(BaseItemDto track) {
  final title = versionlessTitle(track.name ?? "");
  // Without a usable title, only the exact same track counts as a duplicate.
  return title.isEmpty ? "id:${track.id.raw}" : title;
}

final _nonWord = RegExp(r"[^\p{L}\p{N}]+", unicode: true);
final _featuring = RegExp(
  r",|;|&|\band\b|\bfeaturing\b|\bfeat\b\.?|\bft\b\.?|\bwith\b|(?<=[\p{L}\p{N}])\s+x\s+(?=[\p{L}\p{N}])|/",
  unicode: true,
);

/// [text] in lower case, as words separated by single spaces: "Green Day's" is "green day s", "blink-182" "blink 182".
String _words(String text) => text.toLowerCase().replaceAll(_nonWord, " ").trim();

/// Words in an album title before an artist's name that say the album covers them: "Vitamin String Quartet Performs
/// Green Day's …", "A Tribute to Green Day", "The Music of Green Day".
const _coverWords =
    "performs?|plays?|sings?|covers?|tributes?|tribute to|salute to|songs of|music of|hits of|best of|interprets?";

/// What tells whether a track is another version of a song of the same title.
class _Credit {
  factory _Credit(BaseItemDto track) {
    // Its own main artist, not a compilation's "Various Artists".
    final artist = (track.artists?.firstOrNull ?? track.albumArtist ?? "").toLowerCase().split(_featuring).first;
    final name = _words(artist).replaceFirst(RegExp(r"^the "), "");
    return _Credit._(
      name,
      name.replaceAll(" ", ""),
      {
        // Each credited artist on its own: "Original Broadway Cast Featuring Green Day" credits Green Day.
        for (final credit in [track.albumArtist, ...?track.artists].whereType<String>())
          for (final part in credit.toLowerCase().split(_featuring))
            _words(part).replaceFirst(RegExp(r"^the "), "").replaceAll(" ", ""),
      },
      [if (track.album case final album?) " ${_words(album)} "],
    );
  }

  _Credit._(this.name, this.key, this.artists, this.albums);

  /// The main artist's words, to be found in another track's [albums].
  final String name;

  /// The main artist without spaces or punctuation, so "blink-182" and "Blink 182" are the same artist.
  final String key;

  /// Every artist credited, as [key]s.
  final Set<String> artists;

  /// The album titles, as words with a space at each end.
  final List<String> albums;

  /// Takes in [other]'s credits, a copy by the same artist: what either says counts for both.
  void add(_Credit other) {
    artists.addAll(other.artists);
    albums.addAll(other.albums);
  }

  /// Whether this credits [other]'s artist: as one of its artists, or an album covering them ("… Performs Green Day's
  /// American Idiot"). Not a very short name, or one that's just a word in an album title ("Home" by Live and
  /// Michael Bublé's "Caught in the Act (Live)").
  bool names(_Credit other) {
    if (other.name.length < 3) return false;
    if (artists.contains(other.key)) return true;
    final name = RegExp.escape(other.name);
    final cover = RegExp(" (?:$_coverWords) (?:the )?$name | $name s ");
    return albums.any(cover.hasMatch);
  }
}

/// Above this many artists with tracks of one title (a common one like "Intro"), only the same artist links versions:
/// checking every pair of them for covers would take too long.
const _coverCheckLimit = 200;

/// [tracks] without repeats: the same track twice, or another version of the same song: by the same artist (another
/// version, or a copy on a compilation), or a cover naming the other's artist, directly or through another version
/// ("Original Broadway Cast Featuring Green Day" and a string quartet's "… Performs Green Day's American Idiot" are
/// linked by Green Day's own). Same-titled songs by unrelated artists (U2's and Metallica's "One") aren't. The first
/// one is kept, unless one of them is in [keep] (like the song picked to start with), and songs already in [already]
/// (like what's in the queue) are left out too.
/// [through] are recordings that only link versions (left out for other reasons, but still telling which songs are
/// the same): never kept, and not keeping their versions out either.
List<BaseItemDto> withoutDuplicateSongs(
  Iterable<BaseItemDto> tracks, {
  Iterable<BaseItemDto> already = const [],
  Iterable<BaseItemDto> keep = const [],
  Iterable<BaseItemDto> through = const [],
}) => _withoutRepeats(tracks, already: already, keep: keep, through: through, everyVersion: false);

/// [tracks] with one version of each song, as [withoutDuplicateSongs], for a list started at [start]: the song there
/// stays, the ones after it come next, and those before it keep only songs not still to come. So a copy that was
/// skipped neither drops an upcoming version nor moves the start, which is where [start] says it is now.
/// With [playable] (the ids that can play), the version kept is a playable one: those that can't stay only when their
/// song has no playable version, in their place (playback skips them, as it would have).
({List<BaseItemDto> tracks, int start}) withoutDuplicateSongsFrom(
  List<BaseItemDto> tracks,
  int start, {
  Iterable<BaseItemDto> through = const [],
  Set<BaseItemId>? playable,
}) {
  if (playable != null) return _playableVersionsFrom(tracks, start, playable, through);
  final at = start.clamp(0, tracks.length);
  final upcoming = tracks.sublist(at);
  final ahead = withoutDuplicateSongs(upcoming, keep: [?upcoming.firstOrNull], through: through);
  final before = withoutDuplicateSongs(tracks.take(at), already: ahead, through: through);
  return (tracks: [...before, ...ahead], start: before.length);
}

({List<BaseItemDto> tracks, int start}) _playableVersionsFrom(
  List<BaseItemDto> tracks,
  int start,
  Set<BaseItemId> playable,
  Iterable<BaseItemDto> through,
) {
  final at = start.clamp(0, tracks.length);
  // Even the song to start with: one that can't play is skipped by playback, so its playable version is the one.
  // Worked out by position, as a list can hold the very same entry twice.
  final candidates = [
    for (var index = 0; index < tracks.length; index++)
      if (playable.contains(tracks[index].id)) index,
  ];
  final startAt = candidates.where((index) => index < at).length;
  final unique = withoutDuplicateSongsFrom([for (final index in candidates) tracks[index]], startAt, through: through);
  // Both parts keep their order, so each kept track is the next one of its part with that entry.
  final keptPositions = <int>{
    ..._positionsOf(unique.tracks.take(unique.start), candidates.take(startAt), tracks),
    ..._positionsOf(unique.tracks.skip(unique.start), candidates.skip(startAt), tracks),
  };
  final broken = [
    for (var index = 0; index < tracks.length; index++)
      if (!playable.contains(tracks[index].id)) index,
  ];
  // A song picked part-way. At the top it's the list played from the start, which starts with the first song kept.
  final picked = at > 0 ? tracks.elementAtOrNull(at) : null;
  // Those whose song has no playable version, one of each too: the picked one itself when it's among them, so the
  // start stays where the listener tapped.
  final brokenLeft = withoutDuplicateSongs(
    withoutSongsIn([for (final index in broken) tracks[index]], unique.tracks, through: through),
    keep: [if (picked != null && !playable.contains(picked.id)) picked],
    through: through,
  );
  final brokenKept = _positionsOf(brokenLeft, broken, tracks);
  // The very same entry twice collapses to its first place; the picked one stays where it was picked.
  if (picked != null && !playable.contains(picked.id)) {
    final copy = brokenKept.indexWhere((index) => tracks[index].id == picked.id);
    if (copy >= 0) brokenKept[copy] = at;
  }
  final positions = ({...keptPositions, ...brokenKept}.toList())..sort();
  final first = unique.start < unique.tracks.length
      ? _positionsOf(unique.tracks.skip(unique.start), candidates.skip(startAt), tracks).first
      : null;
  // A picked song that can't play starts at its playable version, wherever that is, else at the next song kept.
  int? version, keptCopy;
  if (picked != null && !playable.contains(picked.id)) {
    // Worked out once for the whole list: the kept tracks that aren't a version of it.
    final others = Set<BaseItemDto>.identity()
      ..addAll(withoutSongsIn([for (final index in positions) tracks[index]], [picked], through: through));
    // Only a playable one: another copy that can't play would just be skipped too, back from where the listener began.
    version = positions.firstWhereOrNull(
      (index) => playable.contains(tracks[index].id) && !others.contains(tracks[index]),
    );
    // The copy kept in its place, for when nothing kept comes after it.
    keptCopy = positions.firstWhereOrNull((index) => !others.contains(tracks[index]));
  }
  // Else the picked one itself, when it's the copy kept.
  var startIndex = version != null
      ? positions.indexOf(version)
      : picked != null && !playable.contains(picked.id) && positions.contains(at)
      ? positions.indexOf(at)
      : first == null
      ? positions.indexWhere((index) => index >= at)
      : positions.indexOf(first);
  if (startIndex < 0 && keptCopy != null) startIndex = positions.indexOf(keptCopy);
  return (tracks: [for (final index in positions) tracks[index]], start: startIndex < 0 ? 0 : startIndex);
}

/// Where [kept], an in-order selection from the entries of [tracks] at [positions], came from.
List<int> _positionsOf(Iterable<BaseItemDto> kept, Iterable<int> positions, List<BaseItemDto> tracks) {
  final found = <int>[];
  final remaining = positions.iterator;
  for (final track in kept) {
    while (remaining.moveNext()) {
      if (identical(tracks[remaining.current], track)) {
        found.add(remaining.current);
        break;
      }
    }
  }
  return found;
}

/// [tracks] without the songs in [already], counting their other versions as [withoutDuplicateSongs] does, but
/// keeping every version of the rest: a version that isn't wanted can still link others when they're de-duplicated
/// together with more tracks later. [through] only link versions, as in [withoutDuplicateSongs].
List<BaseItemDto> withoutSongsIn(
  Iterable<BaseItemDto> tracks,
  Iterable<BaseItemDto> already, {
  Iterable<BaseItemDto> through = const [],
}) => _withoutRepeats(tracks, already: already, keep: const [], through: through, everyVersion: true);

List<BaseItemDto> _withoutRepeats(
  Iterable<BaseItemDto> tracks, {
  required Iterable<BaseItemDto> already,
  required Iterable<BaseItemDto> keep,
  required Iterable<BaseItemDto> through,
  required bool everyVersion,
}) {
  final list = tracks.toList();
  final keepIds = {for (final track in keep) track.id.raw};
  // Everything compared, most preferred first: what's already queued (never added again), the songs to keep, the rest,
  // and last the ones that only link others.
  final entries = <({BaseItemDto track, bool queued, bool linkOnly})>[];
  final ids = <String>{};
  for (final track in already) {
    if (ids.add(track.id.raw)) entries.add((track: track, queued: true, linkOnly: false));
  }
  for (final track in [...list.where((track) => keepIds.contains(track.id.raw)), ...list]) {
    if (ids.add(track.id.raw)) entries.add((track: track, queued: false, linkOnly: false));
  }
  for (final track in through) {
    if (ids.add(track.id.raw)) entries.add((track: track, queued: false, linkOnly: true));
  }
  // Versions are linked across the whole list before any is chosen, so no order lets two of them through. Each
  // linked set's root is its most preferred track.
  final root = List.generate(entries.length, (i) => i);
  int find(int i) {
    while (root[i] != i) {
      i = root[i] = root[root[i]];
    }
    return i;
  }

  void link(int a, int b) {
    a = find(a);
    b = find(b);
    if (a != b) root[max(a, b)] = min(a, b);
  }

  final byTitle = <String, List<int>>{};
  for (final (i, entry) in entries.indexed) {
    byTitle.putIfAbsent(songKey(entry.track), () => []).add(i);
  }
  for (final group in byTitle.values.where((group) => group.length > 1)) {
    final byArtist = <String, int>{};
    final credits = <int, _Credit>{};
    for (final i in group) {
      final credit = _Credit(entries[i].track);
      final first = byArtist.putIfAbsent(credit.key, () => i);
      if (first == i) {
        credits[i] = credit;
      } else {
        link(first, i);
        credits[first]!.add(credit);
      }
    }
    if (credits.length > _coverCheckLimit) continue;
    final artists = credits.entries.toList();
    for (var a = 0; a < artists.length; a++) {
      for (var b = a + 1; b < artists.length; b++) {
        if (artists[a].value.names(artists[b].value) || artists[b].value.names(artists[a].value)) {
          link(artists[a].key, artists[b].key);
        }
      }
    }
  }
  final accepted = {
    for (final (i, entry) in entries.indexed)
      // A set's root is queued if any of it is, as queued tracks come first, and only links if all of it does.
      if (!entry.linkOnly && (everyVersion || find(i) == i) && !entries[find(i)].queued) entry.track.id.raw,
  };
  final emitted = <String>{};
  return [
    for (final track in list)
      if (accepted.contains(track.id.raw) && emitted.add(track.id.raw)) track,
  ];
}

/// Queues made by the app (mixes, shuffles, the AI DJ), as opposed to an album or playlist played as it is: only
/// these are cleaned of duplicates.
bool isGeneratedSource(QueueItemSource source) =>
    const {
      QueueItemSourceType.allTracks,
      QueueItemSourceType.favorites,
      QueueItemSourceType.trackMix,
      QueueItemSourceType.artistMix,
      QueueItemSourceType.albumMix,
      QueueItemSourceType.genreMix,
      QueueItemSourceType.collectionMix,
      QueueItemSourceType.radio,
    }.contains(source.type) ||
    (source.type == QueueItemSourceType.unknown && _generatedIds.contains(source.id));

const _generatedIds = {
  "aiDj",
  "rightNow",
  "onThisDay",
  "smartPlaylist",
  "smartShuffle",
  "vibe",
  "alarm",
  "lyricsSearch",
  "yearInMusic",
  "running",
};
