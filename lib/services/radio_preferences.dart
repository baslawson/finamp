import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/analyzer_service.dart';
import 'package:finamp/services/artist_spacing.dart';
import 'package:finamp/services/listening_preferences.dart';
import 'package:finamp/services/finamp_user_helper.dart';
import 'package:finamp/services/jellyfin_api_helper.dart';
import 'package:get_it/get_it.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

class RadioPreferences {
  const RadioPreferences({
    this.discovery = 50,
    this.genres = const [],
    this.excludedArtists = const [],
    this.energy = 0,
  });
  final int discovery;
  final List<String> genres, excludedArtists;
  final int energy;
  factory RadioPreferences.fromJson(Map<String, dynamic> json) => RadioPreferences(
    discovery: ((json['discovery'] as num?)?.toInt() ?? 50).clamp(0, 100),
    genres: (json['genres'] as List?)?.whereType<String>().toList() ?? [],
    excludedArtists: (json['excludedArtists'] as List?)?.whereType<String>().toList() ?? [],
    energy: ((json['energy'] as num?)?.toInt() ?? 0).clamp(-1, 1),
  );
  Map<String, dynamic> toJson() => {
    'discovery': discovery,
    'genres': genres,
    'excludedArtists': excludedArtists,
    'energy': energy,
  };
  RadioPreferences copyWith({int? discovery, List<String>? genres, List<String>? excludedArtists, int? energy}) =>
      RadioPreferences(
        discovery: discovery ?? this.discovery,
        genres: genres ?? this.genres,
        excludedArtists: excludedArtists ?? this.excludedArtists,
        energy: energy ?? this.energy,
      );
  bool permits(BaseItemDto item) =>
      ListeningPreferences.permits(item) &&
      !excludedArtists.contains(ArtistSpacing.artistKey(item)) &&
      (genres.isEmpty ||
          (item.genres ?? []).any((g) => genres.any((selected) => selected.toLowerCase() == g.toLowerCase())));

  Future<List<BaseItemId>> genreIds(JellyfinApiHelper api, BaseItemDto? library) async {
    if (genres.isEmpty) return [];
    final available =
        await api
            .getItems(parentItem: library, includeItemTypes: 'MusicGenre', limit: 1000)
            .timeout(const Duration(seconds: 4)) ??
        [];
    return available
        .where((item) => genres.any((genre) => genre.toLowerCase() == item.name?.toLowerCase()))
        .map((item) => item.id)
        .toList();
  }

  Future<List<BaseItemDto>> libraryTracks(
    JellyfinApiHelper api,
    BaseItemDto library,
    int limit, {
    bool favoritesOnly = false,
  }) async {
    final ids = await genreIds(api, library);
    if (ids.isEmpty) return [];
    return await api
            .getItems(
              parentItem: library,
              includeItemTypes: 'Audio',
              recursive: true,
              sortBy: 'Random',
              isFavorite: favoritesOnly ? true : null,
              genreFilters: ids,
              limit: limit,
            )
            .timeout(const Duration(seconds: 4)) ??
        [];
  }

  /// Target the unheard share within the available pool, without losing surplus matches.
  List<BaseItemDto> order(
    List<BaseItemDto> candidates,
    int needed, {
    Map<String, TrackAnalysis> analysis = const {},
    bool album = false,
  }) {
    final pool = candidates.where(permits).toList();
    if (album) return pool;
    if (energy != 0 && analysis.isNotEmpty) {
      final positions = {for (final (i, item) in pool.indexed) item.id: i};
      pool.sort((a, b) {
        final ae = analysis[a.id.raw]?.intensity ?? analysis[a.id.raw]?.energy;
        final be = analysis[b.id.raw]?.intensity ?? analysis[b.id.raw]?.energy;
        if (ae == null || be == null) {
          return ae == null && be == null
              ? positions[a.id]!.compareTo(positions[b.id]!)
              : ae == null
              ? 1
              : -1;
        }
        final comparison = energy > 0 ? be.compareTo(ae) : ae.compareTo(be);
        return comparison == 0 ? positions[a.id]!.compareTo(positions[b.id]!) : comparison;
      });
    }
    bool unheard(BaseItemDto item) => (item.userData?.playCount ?? 0) == 0 && item.userData?.played != true;
    final fresh = pool.where(unheard).toList(), familiar = pool.where((item) => !unheard(item)).toList();
    final size = min(max(0, needed), pool.length);
    var wantedFresh = (size * discovery / 100).round();
    wantedFresh = wantedFresh.clamp(max(0, size - familiar.length), min(size, fresh.length));
    var freshIndex = 0, familiarIndex = 0;
    final result = <BaseItemDto>[];
    for (var i = 0; i < size; i++) {
      if (freshIndex < wantedFresh &&
          (familiarIndex >= size - wantedFresh || freshIndex < ((i + 1) * wantedFresh / size).round())) {
        result.add(fresh[freshIndex++]);
      } else {
        result.add(familiar[familiarIndex++]);
      }
    }
    return [...result, ...fresh.skip(freshIndex), ...familiar.skip(familiarIndex)];
  }

  Future<List<BaseItemDto>> rank(List<BaseItemDto> pool, int needed, {bool album = false}) async {
    Map<String, TrackAnalysis> analysis = const {};
    if (energy != 0 && !album) {
      try {
        if (await AnalyzerService.isConfigured()) {
          analysis = await AnalyzerService.cachedAnalysis(
            pool.take(100).map((item) => item.id.raw).toList(),
          ).timeout(const Duration(seconds: 3), onTimeout: () => {});
        }
      } catch (_) {
        /* Unavailable analysis leaves normal Radio available. */
      }
    }
    return order(pool, needed, analysis: analysis, album: album);
  }
}

class RadioStation {
  RadioStation({
    required this.id,
    required this.name,
    required this.seed,
    required this.mode,
    required this.preferences,
  });
  final String id, name;
  final BaseItemDto seed;
  final RadioMode mode;
  final RadioPreferences preferences;
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'seed': {'id': seed.id.raw, 'name': seed.name, 'type': seed.type},
    'mode': mode.name,
    'preferences': preferences.toJson(),
  };
  factory RadioStation.fromJson(Map<String, dynamic> json) {
    final seed = Map<String, dynamic>.from(json['seed'] as Map);
    return RadioStation(
      id: json['id'] as String,
      name: json['name'] as String,
      seed: BaseItemDto(
        id: BaseItemId(seed['id'] as String),
        name: seed['name'] as String?,
        type: seed['type'] as String?,
      ),
      mode: RadioMode.values.firstWhere((mode) => mode.name == json['mode']),
      preferences: RadioPreferences.fromJson(Map<String, dynamic>.from(json['preferences'] as Map)),
    );
  }
}

class RadioPreferencesStore {
  static String get scope {
    final user = GetIt.instance.isRegistered<FinampUserHelper>()
        ? GetIt.instance<FinampUserHelper>().currentUser
        : null;
    return sha256.convert(utf8.encode('${user?.serverId ?? ''}:${user?.id ?? ''}')).toString();
  }

  static Future<RadioPreferences> load() async {
    try {
      final raw = await SharedPreferencesAsync().getString('radio.preferences.$scope');
      if (raw == null) return const RadioPreferences();
      return RadioPreferences.fromJson(Map<String, dynamic>.from(jsonDecode(raw) as Map));
    } catch (_) {
      return const RadioPreferences();
    }
  }

  static Future<void> save(RadioPreferences preferences) =>
      SharedPreferencesAsync().setString('radio.preferences.$scope', jsonEncode(preferences.toJson()));
  static Future<List<RadioStation>> stations() async {
    final raw = await SharedPreferencesAsync().getString('radio.stations.$scope');
    final result = <RadioStation>[];
    try {
      for (final value in (jsonDecode(raw ?? '[]') as List)) {
        try {
          result.add(RadioStation.fromJson(Map<String, dynamic>.from(value as Map)));
        } catch (_) {
          /* Keep other valid stations. */
        }
      }
    } catch (_) {
      /* A damaged station file should not break playback. */
    }
    return result;
  }

  static Future<void> writeStations(List<RadioStation> stations) =>
      SharedPreferencesAsync().setString('radio.stations.$scope', jsonEncode(stations.map((s) => s.toJson()).toList()));
  static RadioStation station(String name, BaseItemDto seed, RadioMode mode, RadioPreferences preferences) =>
      RadioStation(id: const Uuid().v4(), name: name.trim(), seed: seed, mode: mode, preferences: preferences);
}
