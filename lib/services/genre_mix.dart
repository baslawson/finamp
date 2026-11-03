import 'dart:convert';
import 'dart:math';

import 'package:collection/collection.dart';

import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/ai_dj_service.dart';
import 'package:finamp/services/jellyfin_api_helper.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:finamp/services/radio_preferences.dart';
import 'package:get_it/get_it.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Which genre the music playing was picked for, so a song can be marked as not fitting it.
class GenreMix {
  GenreMix._();

  static const _key = "genreMixes";

  /// How many genre mixes are remembered, so ones from saved queues still know their genre.
  static const _kept = 30;

  /// The queue id Smart Shuffle plays under.
  static const smartShuffleId = "smartShuffle";

  /// What Radio's songs picked with [preferences] are picked for, kept with their source as
  /// [QueueItemSource.genreMix]: the name of the genres, or "" for none.
  static String radioGenreMix(RadioPreferences preferences) =>
      preferences.genres.isEmpty ? "" : radioGenreName(preferences.genres);

  /// Up to [count] of the songs [ids] (said to be a genre) at random that are in [library], are favourites with
  /// [favoritesOnly] and are from [years]. They're asked about 200 at a time until enough are found, so the few that
  /// qualify among many that don't still turn up.
  static Future<List<BaseItemDto>> answeredSongs(
    JellyfinApiHelper api,
    Iterable<String> ids, {
    required BaseItemDto library,
    required int count,
    bool favoritesOnly = false,
    List<int>? years,
    Duration wait = const Duration(seconds: 4),
  }) async {
    final found = <BaseItemDto>[];
    final waited = Stopwatch()..start();
    for (final slice in ([...ids]..shuffle()).slices(200)) {
      if (found.length >= count || waited.elapsed > wait) break;
      try {
        found.addAll(
          await api
                  .getItems(
                    parentItem: library,
                    recursive: true,
                    includeItemTypes: BaseItemDtoType.track.jellyfinName,
                    isFavorite: favoritesOnly ? true : null,
                    years: years,
                    itemIds: [for (final id in slice) BaseItemId(id)],
                  )
                  .timeout(wait) ??
              [],
        );
      } catch (_) {
        break;
      }
    }
    // The server sends them in its own order, whatever order they were asked in.
    return (found..shuffle()).take(count).toList();
  }

  /// Remembers that the Smart Shuffle queue named [sourceName] is a mix of [genre].
  static Future<void> started({required String sourceName, required String genre}) async {
    final mixes = await _mixes()
      ..remove(sourceName)
      ..[sourceName] = genre;
    // The oldest go first.
    final kept = mixes.entries.skip(max(0, mixes.length - _kept));
    await SharedPreferencesAsync().setString(_key, jsonEncode(Map.fromEntries(kept)));
  }

  /// The genre of each Smart Shuffle queue by its name, oldest first.
  static Future<Map<String, String>> _mixes() async {
    try {
      final stored = await SharedPreferencesAsync().getString(_key);
      if (stored == null) return {};
      return {
        for (final MapEntry(:key, :value) in (jsonDecode(stored) as Map<String, dynamic>).entries)
          if (value is String) key: value,
      };
    } catch (_) {
      // An unreadable entry is no genre.
      return {};
    }
  }

  /// The genre [item] (by default the song playing) was picked for: its Smart Shuffle genre, or Radio's picked genres
  /// for a song Radio added. Null for anything else.
  static Future<String?> current({FinampQueueItem? item}) async {
    // Each song keeps where it came from, so Radio songs added after a Smart Shuffle go by Radio's genres.
    final source = item?.source ?? _playingSource();
    if (source.type == QueueItemSourceType.radio) {
      // The genres Radio picked the song for; ones queued before they were kept go by Radio's genres now.
      if (source.genreMix case final picked?) return picked.isEmpty ? null : picked;
      final genres = (await RadioPreferencesStore.load()).genres;
      return genres.isEmpty ? null : radioGenreName(genres);
    }
    final name = source.name.pretranslatedName;
    if (source.id == smartShuffleId && name != null) return (await _mixes())[name];
    return null;
  }

  static QueueItemSource _playingSource() {
    final queueService = GetIt.instance<QueueService>();
    return queueService.getCurrentTrack()?.source ?? queueService.getQueue().source;
  }

  /// Between Radio's picked genres in [radioGenreName]. Jellyfin splits genre tags at "|", so no genre has one, and
  /// different picks (say "Country and Western" with "Rock", or "Country", "Rock" and "Western") never share a name.
  static const _separator = " | ";

  /// The name Radio checks its picked [genres] under, as one genre. The same genres make the same name in any order, so
  /// answers given for them always apply.
  static String radioGenreName(List<String> genres) =>
      ([...genres]..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()))).join(_separator);

  /// [name] (from [current]) as shown to the listener: "Pop and Rock" for Radio's "Pop | Rock".
  static String displayName(String name) => name.split(_separator).join(" and ");
}

/// A genre to pick: one of the library's genre tags, or an AI tidied group of tags, with the tag names.
typedef GenreChoice = ({String name, List<BaseItemId> ids, Set<String> tags});

/// The genres to pick from, the tidied ones if the AI grouped them.
Future<({List<GenreChoice> choices, bool tidied})> loadGenreChoices() async {
  final groups = await AiDjService.loadGenreGroups();
  final genres = await AiDjService.loadGenres();
  if (groups != null) {
    final nameById = {for (final genre in genres) genre.id: genre.name};
    return (
      choices: [
        for (final group in groups)
          (name: group.name, ids: group.genreIds, tags: {for (final id in group.genreIds) ?nameById[id], group.name}),
      ],
      tidied: true,
    );
  }
  return (
    choices: [
      for (final genre in genres) (name: genre.name ?? "", ids: [genre.id], tags: {?genre.name}),
    ],
    tidied: false,
  );
}
