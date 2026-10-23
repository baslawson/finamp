import 'dart:async';
import 'package:finamp/services/listening_preferences.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/shuffle_randomness.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:finamp/services/finamp_user_helper.dart';
import 'package:finamp/services/artist_spacing.dart';
import 'package:finamp/services/jellyfin_api_helper.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:finamp/services/skip_service.dart';
import 'package:finamp/services/song_duplicates.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';

/// How often a track has been played, as a smart playlist rule.
enum PlayCountRule { any, never, rarely, often }

enum SmartPlaylistOrder { random, mostPlayed, leastPlayed, newestRelease, oldestRelease, recentlyAdded }

/// Rules for a playlist that keeps itself up to date. Synced to a real Jellyfin playlist when [playlistId] is set.
class SmartPlaylist {
  SmartPlaylist({
    required this.id,
    required this.name,
    this.genres = const [],
    this.fromYear,
    this.toYear,
    this.playCount = PlayCountRule.any,
    this.favoritesOnly = false,
    this.leaveOutSkipped = true,
    this.order = SmartPlaylistOrder.random,
    this.size = 100,
    this.playlistId,
    this.lastSync,
  });

  final String id;
  String name;
  List<String> genres;
  int? fromYear;
  int? toYear;
  PlayCountRule playCount;
  bool favoritesOnly;
  bool leaveOutSkipped;
  SmartPlaylistOrder order;
  int size;
  String? playlistId;
  DateTime? lastSync;

  factory SmartPlaylist.fromJson(Map<String, dynamic> json) => SmartPlaylist(
    id: json["id"] as String,
    name: json["name"] as String,
    genres: (json["genres"] as List?)?.cast<String>() ?? const [],
    fromYear: json["fromYear"] as int?,
    toYear: json["toYear"] as int?,
    playCount: PlayCountRule.values.firstWhere(
      (rule) => rule.name == json["playCount"],
      orElse: () => PlayCountRule.any,
    ),
    favoritesOnly: json["favoritesOnly"] as bool? ?? false,
    leaveOutSkipped: json["leaveOutSkipped"] as bool? ?? true,
    order: SmartPlaylistOrder.values.firstWhere(
      (order) => order.name == json["order"],
      orElse: () => SmartPlaylistOrder.random,
    ),
    size: json["size"] as int? ?? 100,
    playlistId: json["playlistId"] as String?,
    lastSync: json["lastSync"] == null ? null : DateTime.fromMillisecondsSinceEpoch(json["lastSync"] as int),
  );

  Map<String, dynamic> toJson() => {
    "id": id,
    "name": name,
    "genres": genres,
    if (fromYear != null) "fromYear": fromYear,
    if (toYear != null) "toYear": toYear,
    "playCount": playCount.name,
    "favoritesOnly": favoritesOnly,
    "leaveOutSkipped": leaveOutSkipped,
    "order": order.name,
    "size": size,
    if (playlistId != null) "playlistId": playlistId,
    if (lastSync != null) "lastSync": lastSync!.millisecondsSinceEpoch,
  };

  SmartPlaylist copy() => SmartPlaylist.fromJson(jsonDecode(jsonEncode(toJson())) as Map<String, dynamic>);
}

/// Smart playlists: rule-based playlists ("rock from the nineties I rarely play") that refresh themselves.
class SmartPlaylistService {
  SmartPlaylistService._();

  static final _logger = Logger("SmartPlaylistService");
  static const sourceId = "smartPlaylist";
  static const refreshEvery = Duration(hours: 20);

  static Future<File> get _file async => File("${(await getApplicationSupportDirectory()).path}/smart_playlists.json");

  static Future<List<SmartPlaylist>> load() async {
    try {
      final file = await _file;
      if (!await file.exists()) return [];
      return [
        for (final json in (jsonDecode(await file.readAsString()) as List<dynamic>).cast<Map<String, dynamic>>())
          SmartPlaylist.fromJson(json),
      ];
    } catch (e) {
      _logger.warning("Couldn't read smart playlists", e);
      return [];
    }
  }

  static Future<void> _saveAll(List<SmartPlaylist> playlists) async {
    await (await _file).writeAsString(jsonEncode([for (final playlist in playlists) playlist.toJson()]));
  }

  static Future<void> save(SmartPlaylist playlist) async {
    final all = await load();
    final index = all.indexWhere((existing) => existing.id == playlist.id);
    index < 0 ? all.add(playlist) : all[index] = playlist;
    await _saveAll(all);
  }

  /// Forgets the rules. The Jellyfin playlist, if any, stays as it is.
  static Future<void> delete(SmartPlaylist playlist) async {
    await _saveAll((await load()).where((existing) => existing.id != playlist.id).toList());
  }

  static bool matchesPlayCount(PlayCountRule rule, int plays) => switch (rule) {
    PlayCountRule.any => true,
    PlayCountRule.never => plays == 0,
    PlayCountRule.rarely => plays <= 3,
    PlayCountRule.often => plays >= 10,
  };

  static String? _sortBy(SmartPlaylistOrder order) => switch (order) {
    SmartPlaylistOrder.random => "Random",
    SmartPlaylistOrder.mostPlayed || SmartPlaylistOrder.leastPlayed => "PlayCount,SortName",
    SmartPlaylistOrder.newestRelease || SmartPlaylistOrder.oldestRelease => "PremiereDate,ProductionYear,SortName",
    SmartPlaylistOrder.recentlyAdded => "DateCreated,SortName",
  };

  static String _sortOrder(SmartPlaylistOrder order) => switch (order) {
    SmartPlaylistOrder.mostPlayed ||
    SmartPlaylistOrder.newestRelease ||
    SmartPlaylistOrder.recentlyAdded => "Descending",
    _ => "Ascending",
  };

  /// The tracks that currently match [playlist]'s rules, in its order.
  static Future<List<BaseItemDto>> tracks(SmartPlaylist playlist) async {
    final api = GetIt.instance<JellyfinApiHelper>();
    final library = GetIt.instance<FinampUserHelper>().currentUser?.currentView;

    List<BaseItemId>? genreIds;
    if (playlist.genres.isNotEmpty) {
      final genres =
          await api.getItems(parentItem: library, includeItemTypes: BaseItemDtoType.genre.jellyfinName) ?? [];
      final wanted = playlist.genres.map((genre) => genre.toLowerCase()).toSet();
      genreIds = [
        for (final genre in genres)
          if (wanted.contains(genre.name?.toLowerCase())) genre.id,
      ];
      if (genreIds.isEmpty) return [];
    }
    final years = playlist.fromYear == null && playlist.toYear == null
        ? null
        : [for (var year = playlist.fromYear ?? 1900; year <= (playlist.toYear ?? DateTime.now().year); year++) year];

    // Play counts and skips are filtered here, so ask for more when they'll thin the results out.
    final filtered = playlist.playCount != PlayCountRule.any || playlist.leaveOutSkipped;
    final pool =
        await api.getItems(
          parentItem: library,
          includeItemTypes: BaseItemDtoType.track.jellyfinName,
          recursive: true,
          genreFilters: genreIds,
          years: years,
          isFavorite: playlist.favoritesOnly ? true : null,
          sortBy: _sortBy(playlist.order),
          sortOrder: _sortOrder(playlist.order),
          limit: filtered ? min(playlist.size * 4, 2000) : playlist.size,
        ) ??
        [];
    final chance = playlist.leaveOutSkipped ? await SkipService.chanceToPlay() : null;
    await ListeningPreferences.ensureLoaded();
    final matching = withoutDuplicateSongs(pool)
        .where(ListeningPreferences.permits)
        .where((track) => matchesPlayCount(playlist.playCount, track.userData?.playCount ?? 0))
        // Songs skipped again and again (less than a coin flip's chance in mixes) are left out.
        .where((track) => chance == null || chance(track.id.raw) >= 0.5)
        .toList();
    return ArtistSpacing.order(
      ShuffleRandomness.order(
        playlist.order == SmartPlaylistOrder.random ? ShuffleRandomness.libraryOrder(matching) : matching,
        FinampSettingsHelper.finampSettings.shuffleRandomness,
      ),
      ArtistSpacing.artistKey,
      keepFirst: false,
      dropUnavoidable: true,
    ).take(playlist.size).toList();
  }

  static Future<void> play(SmartPlaylist playlist, {List<BaseItemDto>? tracks}) async {
    final items = tracks ?? await SmartPlaylistService.tracks(playlist);
    if (items.isEmpty) return;
    await GetIt.instance<QueueService>().startPlayback(
      items: items,
      randomizeGenerated: false,
      source: QueueItemSource.rawId(
        type: QueueItemSourceType.unknown,
        name: QueueItemSourceName(type: QueueItemSourceNameType.preTranslated, pretranslatedName: playlist.name),
        id: sourceId,
      ),
      order: FinampPlaybackOrder.linear,
    );
  }

  /// Creates or refreshes the Jellyfin playlist for [playlist] with the tracks matching now. Returns the track count.
  static Future<int> sync(SmartPlaylist playlist) async {
    final api = GetIt.instance<JellyfinApiHelper>();
    final items = await tracks(playlist);
    final ids = [for (final track in items) track.id];
    final existing = playlist.playlistId;
    var updated = false;
    if (existing != null) {
      try {
        await api.updatePlaylist(
          itemId: BaseItemId(existing),
          newPlaylist: NewPlaylist(name: playlist.name, ids: ids),
        );
        updated = true;
      } catch (e) {
        // Deleted on the server: make a new one.
        _logger.info("Couldn't update smart playlist ${playlist.name}, recreating: $e");
      }
    }
    if (!updated) {
      final created = await api.createNewPlaylist(
        NewPlaylist(
          name: playlist.name,
          userId: GetIt.instance<FinampUserHelper>().currentUserId,
          mediaType: "Audio",
          ids: ids,
        ),
      );
      playlist.playlistId = created.id?.raw;
    }
    playlist.lastSync = DateTime.now();
    await save(playlist);
    return ids.length;
  }

  /// Refreshes the synced playlists that weren't refreshed for a while. Called at startup.
  static Future<void> refreshDue() async {
    for (final playlist in await load()) {
      final lastSync = playlist.lastSync;
      if (playlist.playlistId == null || (lastSync != null && DateTime.now().difference(lastSync) < refreshEvery)) {
        continue;
      }
      try {
        await sync(playlist);
        _logger.info("Refreshed smart playlist ${playlist.name}");
      } catch (e) {
        _logger.warning("Couldn't refresh smart playlist ${playlist.name}", e);
      }
    }
  }
}
