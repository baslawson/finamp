import 'package:collection/collection.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/downloads_service.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:finamp/services/finamp_user_helper.dart';
import 'package:finamp/services/jellyfin_api_helper.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Where smart downloads pick tracks from, highest priority first.
enum SmartDownloadSource {
  // A stable order, so an update doesn't swap random favorites in and out when they exceed the limit.
  favorites(filters: "IsFavorite", sortBy: "PlayCount,SortName", sortOrder: "Descending"),
  mostPlayed(filters: "IsPlayed", sortBy: "PlayCount", sortOrder: "Descending"),
  recentlyPlayed(filters: "IsPlayed", sortBy: "DatePlayed", sortOrder: "Descending"),
  recentlyAdded(sortBy: "DateCreated", sortOrder: "Descending");

  const SmartDownloadSource({this.filters, required this.sortBy, this.sortOrder});

  final String? filters;
  final String sortBy;
  final String? sortOrder;
}

typedef SmartDownloadsSettings = ({int limitGigabytes, Set<SmartDownloadSource> sources});

/// The outcome of filling the smart downloads playlist.
typedef SmartDownloadsResult = ({int tracks, int bytes, BaseItemDto playlist, bool alreadyDownloaded});

/// Keeps a server playlist filled with the tracks most worth having offline, up to a storage limit, and downloads it.
/// Finamp's normal download sync then adds and removes the files as the playlist changes.
class SmartDownloadsService {
  SmartDownloadsService._();

  static final _logger = Logger("SmartDownloadsService");
  static const playlistName = "Finamp+ Smart Downloads";
  static const _limitKey = "smartDownloadsLimitGigabytes";
  static const _sourcesKey = "smartDownloadsSources";
  static const _candidatesPerSource = 1000;

  static Future<SmartDownloadsSettings> loadSettings() async {
    final prefs = SharedPreferencesAsync();
    final sources = await prefs.getStringList(_sourcesKey);
    return (
      limitGigabytes: await prefs.getInt(_limitKey) ?? 8,
      sources: sources == null
          ? SmartDownloadSource.values.toSet()
          : {
              for (final name in sources) ...SmartDownloadSource.values.where((source) => source.name == name),
            },
    );
  }

  static Future<void> saveSettings(SmartDownloadsSettings settings) async {
    final prefs = SharedPreferencesAsync();
    await prefs.setInt(_limitKey, settings.limitGigabytes);
    await prefs.setStringList(_sourcesKey, [for (final source in settings.sources) source.name]);
  }

  /// The estimated download size of [track], taking download transcoding into account.
  static int estimateSize(BaseItemDto track) {
    final settings = FinampSettingsHelper.finampSettings;
    final duration = track.runTimeTicksDuration();
    if (settings.shouldTranscodeDownloads == TranscodeDownloadsSetting.always && duration != null) {
      return settings.downloadTranscodingProfile.stereoBitrate * duration.inSeconds ~/ 8;
    }
    final size = track.mediaSources?.firstOrNull?.size;
    if (size != null) return size;
    // Assume 320 kbps when the server doesn't say.
    return 40000 * (duration?.inSeconds ?? 240);
  }

  /// Picks unique tracks in source priority order until [limitBytes] is reached.
  static List<BaseItemDto> pick(List<List<BaseItemDto>> candidatesBySource, int limitBytes) {
    final picked = <BaseItemDto>[];
    final seen = <BaseItemId>{};
    var total = 0;
    for (final candidates in candidatesBySource) {
      for (final track in candidates) {
        if (!seen.add(track.id)) continue;
        final size = estimateSize(track);
        if (total + size > limitBytes) continue;
        total += size;
        picked.add(track);
      }
    }
    return picked;
  }

  /// Fills the smart downloads playlist for the current library.
  static Future<SmartDownloadsResult> update(SmartDownloadsSettings settings) async {
    final api = GetIt.instance<JellyfinApiHelper>();
    final user = GetIt.instance<FinampUserHelper>().currentUser!;
    final library = user.currentView;

    final candidates = <List<BaseItemDto>>[];
    for (final source in SmartDownloadSource.values.where(settings.sources.contains)) {
      final tracks = await api.getItems(
        parentItem: library,
        includeItemTypes: BaseItemDtoType.track.jellyfinName,
        filters: source.filters,
        sortBy: source.sortBy,
        sortOrder: source.sortOrder,
        fields: "${api.defaultFields},MediaSources",
        limit: _candidatesPerSource,
      );
      candidates.add(tracks ?? []);
    }
    final picked = pick(candidates, settings.limitGigabytes * 1000 * 1000 * 1000);
    final bytes = picked.fold(0, (total, track) => total + estimateSize(track));

    final playlist = await _findOrCreatePlaylist();
    final current = await api.getItems(parentItem: playlist, includeItemTypes: BaseItemDtoType.track.jellyfinName) ?? [];
    final wanted = {for (final track in picked) track.id};
    final stale = [
      for (final entry in current)
        if (!wanted.contains(entry.id) && entry.playlistItemId != null) entry.playlistItemId!,
    ];
    final have = {for (final entry in current) entry.id};
    final missing = [for (final track in picked) if (!have.contains(track.id)) track.id];
    // Entry ids go in the URL, so remove in chunks like adding does.
    for (final slice in stale.slices(100)) {
      await api.removeItemsFromPlaylist(playlistId: playlist.id, entryIds: slice);
    }
    if (missing.isNotEmpty) await api.addItemstoPlaylist(playlistId: playlist.id, ids: missing);
    _logger.info("Smart downloads: ${picked.length} tracks, $bytes bytes (+${missing.length} -${stale.length})");

    final downloads = GetIt.instance<DownloadsService>();
    final stub = DownloadStub.fromItem(type: DownloadItemType.collection, item: playlist);
    final alreadyDownloaded = downloads.getStatus(stub, null).isRequired;
    if (alreadyDownloaded) await downloads.resync(stub, library?.id);
    return (tracks: picked.length, bytes: bytes, playlist: playlist, alreadyDownloaded: alreadyDownloaded);
  }

  static Future<BaseItemDto> _findOrCreatePlaylist() async {
    final api = GetIt.instance<JellyfinApiHelper>();
    final playlists = await api.getItems(
      includeItemTypes: BaseItemDtoType.playlist.jellyfinName,
      searchTerm: playlistName,
    );
    final existing = playlists?.where((playlist) => playlist.name == playlistName).firstOrNull;
    if (existing != null) return existing;
    final created = await api.createNewPlaylist(
      NewPlaylist(
        name: playlistName,
        userId: GetIt.instance<FinampUserHelper>().currentUserId,
        mediaType: "Audio",
        isPublic: false,
      ),
    );
    return api.getItemById(created.id!);
  }
}
