import 'dart:convert';
import 'package:finamp/services/listening_preferences.dart';
import 'dart:math';

import 'package:collection/collection.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/dj_transition_service.dart';
import 'package:finamp/services/ai_service.dart';
import 'package:finamp/services/analyzer_service.dart';
import 'package:finamp/services/downloads_service.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:finamp/services/finamp_user_helper.dart';
import 'package:finamp/services/jellyfin_api_helper.dart';
import 'package:finamp/services/mood_notes.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:finamp/services/radio_tuning.dart';
import 'package:get_it/get_it.dart';
import 'package:finamp/services/skip_service.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A clean genre made up of one or more of the library's raw genre tags.
class GenreGroup {
  const GenreGroup({required this.name, required this.genreIds});

  final String name;
  final List<BaseItemId> genreIds;

  Map<String, dynamic> toJson() => {"name": name, "ids": genreIds.map((id) => id.raw).toList()};

  factory GenreGroup.fromJson(Map<String, dynamic> json) => GenreGroup(
    name: json["name"] as String,
    genreIds: (json["ids"] as List<dynamic>).map((id) => BaseItemId(id as String)).toList(),
  );
}

/// AI powered playlists ("AI DJ") and genre cleanup, using the provider chosen in [AiService].
class AiDjService {
  AiDjService._();

  static final _logger = Logger("AiDjService");

  /// The AI sees at most this many tracks, a random selection on bigger libraries,
  /// which keeps requests fast and cheap and gives every mix some variety.
  static const _maxCatalogTracks = 2000;

  static String _genreGroupsKey(BaseItemId libraryId) => "aiGenreGroups_${libraryId.raw}";

  /// Creates a mix for [request] (a mood, moment or description) and starts playing it.
  /// Returns the name the AI gave the mix. With [harmonic] mixing (the Ai DJ menu's switch when not given), songs are
  /// ordered so each flows into the next in key and tempo, inside the energy shape when the AI chose one.
  static Future<String> playMix(String request, {required int trackCount, bool? harmonic}) async {
    harmonic ??= await HarmonicMixing.menuEnabled(HarmonicMixingMenu.aiDj) && await AnalyzerService.isConfigured();
    final library = GetIt.instance<FinampUserHelper>().currentUser!.currentView!;
    final catalog = await _loadCatalog(library);
    if (catalog.isEmpty) throw AiException("Your library has no tracks to choose from");

    final cleanGenres = await _cleanGenreNames(library);
    final moodNotes = await MoodNotes.load();
    // Grouped by artist so each artist name is sent once, which keeps the prompt (and its cost and latency) down.
    final byArtist = groupBy(catalog.indexed, ((int, BaseItemDto) entry) {
      final track = entry.$2;
      return track.albumArtist ?? track.artists?.firstOrNull ?? "";
    });
    final lines = [
      for (final MapEntry(key: artist, value: tracks) in byArtist.entries) ...[
        "# $artist",
        for (final (index, track) in tracks)
          [
            index,
            track.name ?? "",
            track.productionYear ?? "",
            (track.genres ?? []).map((genre) => cleanGenres[genre] ?? genre).toSet().join("/"),
          ].join("|"),
      ],
    ];

    final prompt =
        '''
You are a skilled DJ building a playlist from the user's own music library.

The listener asked for: "${request.replaceAll('"', "'")}"

Pick about $trackCount tracks from the library below that fit this request well, using what you know about these artists and songs (their sound, energy, mood and era), not just the genre tags. Unless the listener explicitly restricted the mix to particular artists, use a wide variety of artists: no more than a few tracks by any one artist, and don't simply take tracks in the order they're listed. Order them so the mix flows: a sensible energy arc, smooth transitions, and never the same artist twice in a row. Artist names used as examples of a sound ("like Queen") do not restrict the mix to those artists. Repeated artists are allowed when the listener explicitly requests those artists. If few tracks fit, return fewer rather than unfitting ones.

Also choose the energy shape that suits the request: "build" (calm to intense, like a warm-up), "peak" (up to a high point two thirds in, then easing off, like a party or a workout), "steady" (even energy, like focus or running), "windDown" (intense to calm, like bedtime), or "free" when no shape fits.

Also give the mix a short, catchy name (at most 5 words).

Return only track numbers from the list.
${MoodNotes.promptSection(moodNotes, catalog)}
Library, grouped under "# artist" headings (number|title|year|genres):
${lines.join("\n")}''';

    final result = await AiService.generateJson(
      prompt: prompt,
      schemaName: "playlist",
      schema: {
        "type": "object",
        "properties": {
          "name": {"type": "string", "description": "Short name for the mix"},
          "artistsRequested": {
            "type": "boolean",
            "description":
                "True only if the listener explicitly restricted the mix to named artists, not names used as examples of a sound",
          },
          "energyShape": {
            "type": "string",
            "enum": ["build", "peak", "steady", "windDown", "free"],
            "description": "How the mix's energy should run from start to end",
          },
          "tracks": {
            "type": "array",
            "description": "Track numbers from the library, in play order",
            "items": {"type": "integer"},
          },
        },
        "required": ["name", "artistsRequested", "energyShape", "tracks"],
        "additionalProperties": false,
      },
    );

    final name = (result["name"] as String?)?.trim();
    final artistsRequested = result["artistsRequested"] == true;
    // Unless the listener asked for particular artists, no artist gets more than a fair share of the mix.
    final maxPerArtist = artistsRequested ? trackCount : max(2, (trackCount / 10).ceil());
    final perArtist = <String, int>{};
    final notFitting = {
      for (final note in moodNotes)
        if (MoodNotes.sameRequest(note.request, request)) note.trackId,
    };
    final seen = <int>{};
    final picked = (result["tracks"] as List<dynamic>? ?? [])
        .whereType<num>()
        .map((number) => number.toInt())
        .where((index) => index >= 0 && index < catalog.length && seen.add(index))
        .map((index) => catalog[index])
        // Said not to fit this very request before: left out whatever the AI made of the note.
        .where((track) => !notFitting.contains(track.id.raw))
        .where((track) {
          final artist = DjTransitionService.artistKey(track);
          if (artist == null) return true;
          return (perArtist[artist] = (perArtist[artist] ?? 0) + 1) <= maxPerArtist;
        })
        .toList();
    _logger.info(
      "AI DJ picked ${picked.length} tracks for \"$request\" (mix \"$name\", "
      "${artistsRequested ? "artists requested" : "at most $maxPerArtist per artist"})",
    );
    if (picked.isEmpty) throw AiException("The AI didn't find any fitting tracks, try describing it differently");

    final mixName = (name == null || name.isEmpty) ? request : name;
    final detailed = await _withFullDetails(picked);
    final shape =
        EnergyShape.values.firstWhereOrNull((shape) => shape.name == result["energyShape"]) ?? EnergyShape.free;
    final analysis = shape == EnergyShape.free
        ? const <String, TrackAnalysis>{}
        : await AnalyzerService.cachedAnalysis([for (final track in detailed) track.id.raw]);
    final measured = detailed.where((track) => analysis[track.id.raw]?.intensity != null).length;
    // The shape needs most songs measured by the analyzer; without that the AI's own order keeps its arc.
    var shaped = measured >= detailed.length / 2
        ? DjTransitionService.shapeOrder(detailed, (track) => analysis[track.id.raw]?.intensity, shape)
        : null;
    final strength = HarmonicMixing.strength.value;
    // At 0% harmonic strength key and tempo don't count, so the energy shape stands as it is.
    if (shaped != null && harmonic && strength > 0) {
      shaped = DjTransitionService.smoothWithinGroups(
        shaped,
        (from, to) => DjTransitionService.transitionCost(analysis[from.id.raw], analysis[to.id.raw]),
        strength: strength,
      );
    }
    _logger.info(
      "Energy shape ${shape.name}: ${shaped == null ? "the AI's order" : "ordered by measured intensity"}"
      "${harmonic ? ", harmonic mixing" : ""} "
      "($measured of ${detailed.length} measured)",
    );
    await GetIt.instance<QueueService>().startPlayback(
      // Along the energy shape when there is one; otherwise, with harmonic mixing or DJ transitions on, so keys and
      // tempos flow; otherwise in the AI's order. An explicit artist request may repeat that artist; other mixes need
      // spacing.
      items: shaped != null
          ? (artistsRequested ? shaped : DjTransitionService.spreadArtistsFreely(shaped))
          : harmonic || await DjTransitionService.isEnabled()
          ? await DjTransitionService.smoothOrder(
              detailed,
              allowArtistRepeats: artistsRequested,
              // Harmonic mixes follow the harmonic strength; DJ transitions alone always take the best next song.
              strength: harmonic ? strength : null,
            )
          : artistsRequested
          ? detailed
          : DjTransitionService.spreadArtistsFreely(detailed),
      source: QueueItemSource.rawId(
        type: QueueItemSourceType.unknown,
        name: QueueItemSourceName(
          type: QueueItemSourceNameType.preTranslated,
          pretranslatedName: "${MoodNotes.aiDjNamePrefix}$mixName",
        ),
        id: MoodNotes.aiDjSourceId,
        // So a song in it can be said not to fit this request.
        mixRequest: request,
        allowArtistRepeats: artistsRequested,
      ),
      order: FinampPlaybackOrder.linear,
      // Every order above is meant (the AI's arc, the energy shape, or keys and tempos), so shuffle randomness, which
      // would undo it, isn't applied.
      randomizeGenerated: false,
      harmonicOrder: harmonic,
      keepsShape: shaped != null,
    );
    return mixName;
  }

  /// Groups the library's genre tags into clean genres (merging duplicates, typos, languages
  /// and combined tags) and remembers the result on this device. Nothing changes on the server.
  static Future<List<GenreGroup>> tidyGenres(List<BaseItemDto> genres) async {
    final library = GetIt.instance<FinampUserHelper>().currentUser!.currentView!;
    if (genres.isEmpty) return [];
    final prompt = '''
These are the genre tags of a music library. Many are duplicates, typos, other languages or combinations of several genres.

Group them into a clean, consistent set of genres a listener would expect (for example "Progressive Rock", "Alternative", "Hip-Hop"). Use English, Title Case names. Put every tag into exactly one group: for a combined tag like "Pop / Rock", pick its most specific main genre. Prefer fewer, meaningful groups over many tiny ones, but keep clearly different styles apart.

Group by how the music sounds, so someone who picks a group hears what they expect. Softer or acoustic styles never go into a harder parent genre: keep "Soft Rock", "Folk Rock", "Acoustic", "Singer-Songwriter", "Ballads" and similar in their own groups (or with each other), not in "Rock" or "Metal". Likewise keep "Pop / Rock" and "Adult Contemporary" out of "Rock".

Tags (number|tag):
${[for (final (index, genre) in genres.indexed) "$index|${genre.name}"].join("\n")}''';

    final result = await AiService.generateJson(
      prompt: prompt,
      schemaName: "genre_groups",
      schema: {
        "type": "object",
        "properties": {
          "groups": {
            "type": "array",
            "items": {
              "type": "object",
              "properties": {
                "name": {"type": "string", "description": "Clean genre name"},
                "tags": {
                  "type": "array",
                  "description": "Numbers of the tags in this genre",
                  "items": {"type": "integer"},
                },
              },
              "required": ["name", "tags"],
              "additionalProperties": false,
            },
          },
        },
        "required": ["groups"],
        "additionalProperties": false,
      },
    );

    final assigned = <int>{};
    final groups = <String, List<BaseItemId>>{};
    for (final group in (result["groups"] as List<dynamic>? ?? []).whereType<Map<String, dynamic>>()) {
      final name = (group["name"] as String?)?.trim();
      if (name == null || name.isEmpty) continue;
      for (final index in (group["tags"] as List<dynamic>? ?? []).whereType<num>().map((n) => n.toInt())) {
        if (index >= 0 && index < genres.length && assigned.add(index)) {
          (groups[name] ??= []).add(genres[index].id);
        }
      }
    }
    // Tags the AI forgot keep their own name, so no music disappears from the genre list.
    for (final (index, genre) in genres.indexed) {
      if (!assigned.contains(index)) (groups[genre.name ?? ""] ??= []).add(genre.id);
    }

    final tidied = [for (final entry in groups.entries) GenreGroup(name: entry.key, genreIds: entry.value)]
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    await SharedPreferencesAsync().setString(
      _genreGroupsKey(library.id),
      jsonEncode(tidied.map((group) => group.toJson()).toList()),
    );
    return tidied;
  }

  /// The tidied genres of the current library, or null if they haven't been tidied yet.
  static Future<List<GenreGroup>?> loadGenreGroups() async {
    final library = GetIt.instance<FinampUserHelper>().currentUser?.currentView;
    if (library == null) return null;
    final stored = await SharedPreferencesAsync().getString(_genreGroupsKey(library.id));
    if (stored == null) return null;
    try {
      return (jsonDecode(stored) as List<dynamic>).cast<Map<String, dynamic>>().map(GenreGroup.fromJson).toList();
    } catch (e) {
      _logger.warning("Stored genre groups are unreadable", e);
      return null;
    }
  }

  static Future<void> clearGenreGroups() async {
    final library = GetIt.instance<FinampUserHelper>().currentUser?.currentView;
    if (library != null) await SharedPreferencesAsync().remove(_genreGroupsKey(library.id));
  }

  /// Maps raw genre names to their tidied name, if the genres were tidied.
  static Future<Map<String, String>> _cleanGenreNames(BaseItemDto library) async {
    final groups = await loadGenreGroups();
    if (groups == null) return {};
    final genres = await loadGenres();
    final nameById = {for (final genre in genres) genre.id: genre.name};
    return {
      for (final group in groups)
        for (final id in group.genreIds) ?nameById[id]: group.name,
    };
  }

  /// Genres of the current library, online or from the downloads.
  static Future<List<BaseItemDto>> loadGenres() async {
    final settings = FinampSettingsHelper.finampSettings;
    final library = GetIt.instance<FinampUserHelper>().currentUser?.currentView;
    if (settings.isOffline) {
      final stubs = await GetIt.instance<DownloadsService>().getAllCollections(
        includeItemTypes: [BaseItemDtoType.genre],
        childViewFilter: library?.id,
        nullableViewFilters: settings.showDownloadsWithUnknownLibrary,
      );
      return stubs.map((stub) => stub.baseItem).nonNulls.toList()
        ..sort((a, b) => (a.name ?? "").toLowerCase().compareTo((b.name ?? "").toLowerCase()));
    }
    final genres = await GetIt.instance<JellyfinApiHelper>().getItems(
      parentItem: library,
      includeItemTypes: BaseItemDtoType.genre.jellyfinName,
      recursive: false,
      sortBy: "SortName",
      sortOrder: "Ascending",
    );
    return genres ?? [];
  }

  /// Tracks the AI may choose from: the downloads when offline, otherwise (a random part of) the library.
  static Future<List<BaseItemDto>> _loadCatalog(BaseItemDto library) async {
    await ListeningPreferences.ensureLoaded();
    final settings = FinampSettingsHelper.finampSettings;
    if (settings.isOffline) {
      final stubs = await GetIt.instance<DownloadsService>().getAllTracks(
        viewFilter: library.id,
        nullableViewFilters: settings.showDownloadsWithUnknownLibrary,
      );
      final tracks = stubs.map((stub) => stub.baseItem).nonNulls.toList()..shuffle();
      return SkipService.thinOut(
        tracks.where(ListeningPreferences.permits).take(_maxCatalogTracks).toList(),
        (track) => track.id.raw,
      );
    }
    final tracks = await GetIt.instance<JellyfinApiHelper>().getItems(
      parentItem: library,
      includeItemTypes: BaseItemDtoType.track.jellyfinName,
      sortBy: "Random",
      // Only what the prompt needs, the full details are loaded for the picked tracks.
      fields: "Genres",
      limit: _maxCatalogTracks,
    );
    // Often skipped songs are less likely to be offered to the AI.
    return SkipService.thinOut((tracks ?? []).where(ListeningPreferences.permits).toList(), (track) => track.id.raw);
  }

  /// The catalog was loaded with minimal fields, playback needs the full details.
  static Future<List<BaseItemDto>> _withFullDetails(List<BaseItemDto> tracks) async {
    if (FinampSettingsHelper.finampSettings.isOffline) return tracks;
    final full = await GetIt.instance<JellyfinApiHelper>().getItems(itemIds: tracks.map((track) => track.id).toList());
    final byId = {for (final track in full ?? <BaseItemDto>[]) track.id: track};
    return [for (final track in tracks) byId[track.id] ?? track];
  }
}
