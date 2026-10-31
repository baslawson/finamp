import 'package:collection/collection.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/finamp_user_helper.dart';
import 'package:finamp/services/jellyfin_api_helper.dart';
import 'package:finamp/services/library_matcher.dart';
import 'package:get_it/get_it.dart';

/// What a library scan found. Nothing is changed on the server; this only points out what to fix.
class LibraryHealthReport {
  LibraryHealthReport({
    required this.trackCount,
    required this.albumCount,
    required this.duplicates,
    required this.lowQuality,
    required this.albumsWithoutArtwork,
    required this.albumsMissingTags,
  });

  final int trackCount;
  final int albumCount;

  /// Groups of tracks that look like the same recording.
  final List<List<BaseItemDto>> duplicates;

  /// Lossy tracks below [LibraryHealthService.lowBitrate].
  final List<BaseItemDto> lowQuality;
  final List<BaseItemDto> albumsWithoutArtwork;

  /// Albums with tracks missing an album artist, year or genre, and which of those are missing.
  final List<({BaseItemDto album, Set<MissingTag> missing})> albumsMissingTags;

  bool get isHealthy =>
      duplicates.isEmpty && lowQuality.isEmpty && albumsWithoutArtwork.isEmpty && albumsMissingTags.isEmpty;
}

enum MissingTag { albumArtist, year, genre }

class LibraryHealthService {
  LibraryHealthService._();

  /// Below this, lossy files usually sound noticeably worse (bits per second).
  static const lowBitrate = 192000;
  static const _lossy = {"mp3", "aac", "m4a", "ogg", "opus", "wma", "mp2", "webma"};
  static const _pageSize = 1000;

  static Future<LibraryHealthReport> scan({void Function(int done, int? total)? onProgress}) async {
    final api = GetIt.instance<JellyfinApiHelper>();
    final library = GetIt.instance<FinampUserHelper>().currentUser?.currentView;

    final tracks = <BaseItemDto>[];
    while (true) {
      final page =
          await api.getItems(
            parentItem: library,
            includeItemTypes: BaseItemDtoType.track.jellyfinName,
            recursive: true,
            sortBy: "SortName",
            fields: "MediaSources,Genres,ParentId",
            startIndex: tracks.length,
            limit: _pageSize,
          ) ??
          [];
      tracks.addAll(page);
      onProgress?.call(tracks.length, null);
      if (page.length < _pageSize) break;
    }
    final albums =
        await api.getItems(
          parentItem: library,
          includeItemTypes: BaseItemDtoType.album.jellyfinName,
          recursive: true,
          sortBy: "SortName",
        ) ??
        [];
    return analyze(tracks, albums);
  }

  /// [title] compared for duplicates: remaster tags don't matter, but other versions (live, demo, a mix) do.
  static String duplicateTitle(String title) => title
      .toLowerCase()
      .replaceAll(RegExp(r"[(\[][^)\]]*remaster[^)\]]*[)\]]"), " ")
      .replaceAll(RegExp(r"\s+-\s+[^-]*remaster.*$"), " ")
      .replaceAll(RegExp(r"[’'`]"), "")
      .replaceAll(RegExp(r"[^\p{L}\p{N}]+", unicode: true), " ")
      .trim();

  /// The checks themselves, separate from loading so they can be tested.
  static LibraryHealthReport analyze(List<BaseItemDto> tracks, List<BaseItemDto> albums) {
    // Same title and artist, and lengths within two seconds: probably the same recording twice.
    final byKey = groupBy(tracks, (BaseItemDto track) {
      final artist = LibraryMatcher.splitArtists(track.albumArtist ?? track.artists?.firstOrNull ?? "").firstOrNull;
      return "${duplicateTitle(track.name ?? "")}|$artist";
    });
    final duplicates = <List<BaseItemDto>>[];
    for (final group in byKey.values) {
      if (group.length < 2) continue;
      final sorted = group.sortedBy<num>((track) => track.runTimeTicks ?? 0);
      var cluster = [sorted.first];
      for (final track in sorted.skip(1)) {
        final gap = ((track.runTimeTicks ?? 0) - (cluster.last.runTimeTicks ?? 0)).abs();
        if (gap <= 2 * 10000000) {
          cluster.add(track);
        } else {
          if (cluster.length > 1) duplicates.add(cluster);
          cluster = [track];
        }
      }
      if (cluster.length > 1) duplicates.add(cluster);
    }

    final lowQuality = tracks.where((track) {
      final source = track.mediaSources?.firstOrNull;
      final container = (source?.container ?? track.container ?? "").toLowerCase();
      final bitrate = source?.bitrate;
      return bitrate != null && bitrate > 0 && bitrate < lowBitrate && container.split(",").any(_lossy.contains);
    }).toList();

    final albumsWithoutArtwork = albums.where((album) => album.imageTags?["Primary"] == null).toList();

    final albumsById = {for (final album in albums) album.id: album};
    final missingByAlbum = <BaseItemId, Set<MissingTag>>{};
    for (final track in tracks) {
      final albumId = track.albumId;
      if (albumId == null) continue;
      final missing = {
        if ((track.albumArtist ?? "").isEmpty) MissingTag.albumArtist,
        if (track.productionYear == null) MissingTag.year,
        if (track.genres?.isEmpty ?? true) MissingTag.genre,
      };
      if (missing.isNotEmpty) missingByAlbum.putIfAbsent(albumId, () => {}).addAll(missing);
    }
    final albumsMissingTags = [
      for (final MapEntry(key: id, value: missing) in missingByAlbum.entries)
        if (albumsById[id] != null) (album: albumsById[id]!, missing: missing),
    ]..sortBy((entry) => entry.album.name ?? "");

    return LibraryHealthReport(
      trackCount: tracks.length,
      albumCount: albums.length,
      // Copies within one album first: those are most likely accidental, unlike a song that's also on a compilation.
      duplicates: duplicates
        ..sort((a, b) {
          int sameAlbum(List<BaseItemDto> group) =>
              group.map((track) => track.albumId).toSet().length < group.length ? 0 : 1;
          final bySameAlbum = sameAlbum(a).compareTo(sameAlbum(b));
          return bySameAlbum != 0 ? bySameAlbum : (a.first.name ?? "").compareTo(b.first.name ?? "");
        }),
      lowQuality: lowQuality,
      albumsWithoutArtwork: albumsWithoutArtwork,
      albumsMissingTags: albumsMissingTags,
    );
  }
}
