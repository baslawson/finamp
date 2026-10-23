import 'package:collection/collection.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/library_health_service.dart';
import 'package:finamp/services/library_matcher.dart';

/// What makes two tracks "the same song": the title (ignoring remaster tags, but keeping live versions, remixes and
/// other mixes apart) and the main artist. The same song on an album and a compilation shares this.
String songKey(BaseItemDto track) {
  final artist = LibraryMatcher.splitArtists(track.albumArtist ?? track.artists?.firstOrNull ?? "").firstOrNull ?? "";
  final title = LibraryHealthService.duplicateTitle(track.name ?? "");
  // Without a usable title, only the exact same track counts as a duplicate.
  return title.isEmpty ? "id:${track.id.raw}" : "$title|${artist.toLowerCase()}";
}

/// [tracks] without repeats: the same track twice, or the same song from another album. The first one is kept, and
/// songs already in [already] (like what's in the queue) are left out too.
List<BaseItemDto> withoutDuplicateSongs(Iterable<BaseItemDto> tracks, {Iterable<BaseItemDto> already = const []}) {
  final seen = {for (final track in already) songKey(track)};
  final seenIds = {for (final track in already) track.id.raw};
  return [
    for (final track in tracks)
      if (seenIds.add(track.id.raw) && seen.add(songKey(track))) track,
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
