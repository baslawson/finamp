import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/finamp_user_helper.dart';
import 'package:finamp/services/jellyfin_api_helper.dart';
import 'package:finamp/services/listening_log_service.dart';
import 'package:get_it/get_it.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';

/// An album or EP by an artist in the library that the library doesn't have.
class NewRelease {
  NewRelease({required this.id, required this.title, required this.artist, required this.type, required this.date});

  /// MusicBrainz release group id.
  final String id;
  final String title;
  final String artist;
  final String type;

  /// Release date as MusicBrainz gives it: YYYY, YYYY-MM or YYYY-MM-DD.
  final String date;

  bool get upcoming => date.compareTo(_today()) > 0;

  Uri get url => Uri.parse("https://musicbrainz.org/release-group/$id");

  factory NewRelease.fromJson(Map<String, dynamic> json) => NewRelease(
    id: json["id"] as String,
    title: json["title"] as String,
    artist: json["artist"] as String,
    type: json["type"] as String,
    date: json["date"] as String,
  );

  Map<String, dynamic> toJson() => {"id": id, "title": title, "artist": artist, "type": type, "date": date};
}

typedef NewReleasesResult = ({DateTime checked, int artists, List<NewRelease> releases});

String _today() => DateTime.now().toIso8601String().substring(0, 10);

/// Finds new and upcoming albums from the artists you listen to most, using MusicBrainz.
class NewReleasesService {
  NewReleasesService._();

  static final _logger = Logger("NewReleasesService");
  static const _maxArtists = 40;
  static const _lookback = Duration(days: 365);
  static const _checkEvery = Duration(days: 7);
  static const _headers = {
    "User-Agent": "Finamp+ ( https://github.com/baslawson/finamp )",
    "Accept": "application/json",
  };

  static Future<File> get _cacheFile async =>
      File("${(await getApplicationSupportDirectory()).path}/new_releases.json");

  static Future<NewReleasesResult?> loadCached() async {
    try {
      final file = await _cacheFile;
      if (!await file.exists()) return null;
      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return (
        checked: DateTime.fromMillisecondsSinceEpoch(json["checked"] as int),
        artists: json["artists"] as int,
        releases: [
          for (final release in json["releases"] as List) NewRelease.fromJson(release as Map<String, dynamic>),
        ],
      );
    } catch (e) {
      _logger.warning("Couldn't read cached new releases", e);
      return null;
    }
  }

  /// Checks again if the last check is more than a week old. Returns the new result, or null if no check ran.
  static Future<NewReleasesResult?> checkIfDue() async {
    final cached = await loadCached();
    if (cached != null && DateTime.now().difference(cached.checked) < _checkEvery) return null;
    return check();
  }

  /// Lower-cased title without bracketed suffixes like "(Deluxe Edition)" and punctuation, for comparing albums.
  static String normalizeTitle(String title) => title
      .toLowerCase()
      .replaceAll(RegExp(r"[(\[].*?[)\]]"), "")
      .replaceAll(RegExp(r"[^\p{L}\p{N}]+", unicode: true), " ")
      .trim();

  static Future<NewReleasesResult> check({void Function(int done, int total)? onProgress}) async {
    final api = GetIt.instance<JellyfinApiHelper>();
    final library = GetIt.instance<FinampUserHelper>().currentUser?.currentView;
    final artists = await _pickArtists(api);
    final owned = await _ownedAlbums(api, library);
    final since = DateTime.now().subtract(_lookback).toIso8601String().substring(0, 10);

    final seenReleases = <String>{};
    final releases = <NewRelease>[];
    for (final (index, artist) in artists.indexed) {
      onProgress?.call(index, artists.length);
      // MusicBrainz allows one request per second.
      if (index > 0) await Future<void>.delayed(const Duration(milliseconds: 1100));
      try {
        final found = await _releasesFor(artist, since, owned[artist.name?.toLowerCase()] ?? const {});
        releases.addAll(found.where((release) => seenReleases.add(release.id)));
      } catch (e) {
        _logger.info("MusicBrainz lookup for ${artist.name} failed: $e");
      }
    }
    onProgress?.call(artists.length, artists.length);
    releases.sort((a, b) => b.date.compareTo(a.date));

    final result = (checked: DateTime.now(), artists: artists.length, releases: releases);
    await (await _cacheFile).writeAsString(
      jsonEncode({
        "checked": result.checked.millisecondsSinceEpoch,
        "artists": result.artists,
        "releases": [for (final release in releases) release.toJson()],
      }),
    );
    _logger.info("Found ${releases.length} new releases from ${artists.length} artists");
    return result;
  }

  /// Favorite artists first, then the most listened ones from the listening log, all with a MusicBrainz id.
  static Future<List<BaseItemDto>> _pickArtists(JellyfinApiHelper api) async {
    final favorites =
        await api.getItems(
          includeItemTypes: BaseItemDtoType.artist.jellyfinName,
          filters: "IsFavorite",
          recursive: true,
          fields: "ProviderIds",
          limit: _maxArtists,
        ) ??
        [];
    final listens = await ListeningLogService.load(forLearning: true);
    final topIds = listens
        .where((entry) => entry.artistId != null)
        .groupListsBy((entry) => entry.artistId!)
        .entries
        .sortedBy<num>((entry) => -entry.value.length)
        .take(_maxArtists)
        .map((entry) => BaseItemId(entry.key))
        .toList();
    final listened = topIds.isEmpty
        ? <BaseItemDto>[]
        : await api.getItems(itemIds: topIds, fields: "ProviderIds") ?? [];
    // The server's play counts cover listening on every device, so they fill up the rest.
    final mostPlayedTracks =
        await api.getItems(
          includeItemTypes: BaseItemDtoType.track.jellyfinName,
          filters: "IsPlayed",
          sortBy: "PlayCount",
          sortOrder: "Descending",
          recursive: true,
          limit: 300,
        ) ??
        [];
    final knownIds = {...favorites.map((artist) => artist.id), ...listened.map((artist) => artist.id)};
    final playedIds = mostPlayedTracks
        .expand((track) => track.albumArtists ?? <NameIdPair>[])
        .map((artist) => artist.id)
        .where(knownIds.add)
        .take(_maxArtists)
        .toList();
    final played = playedIds.isEmpty
        ? <BaseItemDto>[]
        : await api.getItems(itemIds: playedIds, fields: "ProviderIds") ?? [];
    // getItems returns them in name order, so restore the play count order.
    final playedOrder = {for (final (index, id) in playedIds.indexed) id: index};
    played.sortBy<num>((artist) => playedOrder[artist.id] ?? playedIds.length);

    final seen = <BaseItemId>{};
    return [
      ...favorites,
      ...listened,
      ...played,
    ].where((artist) => _musicBrainzId(artist) != null && seen.add(artist.id)).take(_maxArtists).toList();
  }

  /// MusicBrainz placeholder artists like Various Artists and [unknown], which would match every compilation.
  static const _placeholderArtists = {
    "89ad4ac3-39f7-470e-963a-56509c546377", // Various Artists
    "125ec42a-7229-4250-afc5-e057484327fe", // [unknown]
    "f731ccc4-e22a-43af-a747-64213329e088", // [anonymous]
    "eec63d3c-3b81-4ad4-b1e4-7c147d4d2b61", // [no artist]
    "9be7f096-97ec-4615-8957-8d40b5dcbc41", // [traditional]
    "314e1c25-dde7-4e4d-b2f4-0a7b9f7c56dc", // [dialogue]
  };

  static String? _musicBrainzId(BaseItemDto artist) {
    final id = artist.providerIds?["MusicBrainzArtist"] as String?;
    return _placeholderArtists.contains(id) ? null : id;
  }

  /// Normalized album titles in the library by lower-cased album artist.
  static Future<Map<String?, Set<String>>> _ownedAlbums(JellyfinApiHelper api, BaseItemDto? library) async {
    final albums =
        await api.getItems(
          parentItem: library,
          includeItemTypes: BaseItemDtoType.album.jellyfinName,
          recursive: true,
          fields: "",
        ) ??
        [];
    final owned = <String?, Set<String>>{};
    for (final album in albums) {
      if (album.name == null) continue;
      owned.putIfAbsent(album.albumArtist?.toLowerCase(), () => {}).add(normalizeTitle(album.name!));
    }
    return owned;
  }

  static Future<List<NewRelease>> _releasesFor(BaseItemDto artist, String since, Set<String> owned) async {
    final query =
        "arid:${_musicBrainzId(artist)} AND firstreleasedate:[$since TO 2099-12-31] "
        "AND (primarytype:album OR primarytype:ep) AND NOT secondarytype:compilation AND NOT secondarytype:live";
    final uri = Uri.https("musicbrainz.org", "/ws/2/release-group", {"query": query, "fmt": "json", "limit": "25"});
    final response = await http.get(uri, headers: _headers).timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) throw Exception("MusicBrainz error ${response.statusCode}");
    final json = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    return [
      for (final group in (json["release-groups"] as List).cast<Map<String, dynamic>>())
        if (group["first-release-date"] case final String date when date.isNotEmpty)
          if (!owned.contains(normalizeTitle(group["title"] as String)))
            NewRelease(
              id: group["id"] as String,
              title: group["title"] as String,
              artist: artist.name ?? "",
              type: group["primary-type"] as String? ?? "Album",
              date: date,
            ),
    ];
  }
}
