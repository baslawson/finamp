import 'dart:convert';
import 'dart:math';

import 'package:collection/collection.dart';

import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/artist_spacing.dart';
import 'package:finamp/services/radio_preferences.dart';
import 'package:finamp/services/song_duplicates.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum SongTransition { automatic, fullEnding, shortFade, gapless }

/// A song resting, or an artist blocked, until [until] (or for good, see [forever]). An artist is matched by their
/// name as a key, or by [artistId], their id in the library, when known.
class ListeningRest {
  const ListeningRest({
    required this.key,
    required this.name,
    required this.until,
    required this.artist,
    this.artistId,
  });
  final String key, name;
  final DateTime until;
  final bool artist;
  final String? artistId;

  /// The end of a block for good.
  static final forever = DateTime.utc(9999);
  bool get isForever => !until.isBefore(forever);

  bool active(DateTime now) => until.isAfter(now);
  Map<String, dynamic> toJson() => {
    'key': key,
    'name': name,
    'until': until.toUtc().toIso8601String(),
    'artist': artist,
    if (artistId != null) 'artistId': artistId,
  };
  factory ListeningRest.fromJson(Map<String, dynamic> json) => ListeningRest(
    key: json['key'] as String,
    name: json['name'] as String,
    until: DateTime.parse(json['until'] as String),
    artist: json['artist'] == true,
    artistId: json['artistId'] as String?,
  );
}

/// An artist credited on a song, or the artist themselves, to block: by [name], with their library [id] when known.
typedef BlockableArtist = ({String name, String? id});

/// Account-scoped opt-outs for generated lists (and, with [everywhere], the lists the listener opens too). The song a
/// listener deliberately picked, and what they add to the queue themselves, still play.
class ListeningPreferences {
  static String? _scope;
  static final _rests = <String, ListeningRest>{};
  static bool _everywhere = false;
  static final _transitions = <String, SongTransition>{};
  static Future<void> _tail = Future.value();
  static final changed = ValueNotifier<int>(0);

  static Future<void> _serialize(Future<void> Function() action) {
    final next = _tail.catchError((Object _) {}).then((_) => action());
    _tail = next;
    return next;
  }

  /// Forgets what was loaded, so a test starts afresh (and doesn't wait on another test's zone).
  @visibleForTesting
  static void reset() {
    _scope = null;
    _rests.clear();
    _transitions.clear();
    _everywhere = false;
    _tail = Future.value();
  }

  static Future<void> ensureLoaded() => _serialize(_load);
  static Future<void> _load() async {
    final scope = RadioPreferencesStore.scope;
    if (_scope == scope) return;
    final raw = await SharedPreferencesAsync().getString('listeningChoices.$scope');
    if (scope != RadioPreferencesStore.scope) return;
    _rests.clear();
    _transitions.clear();
    _everywhere = false;
    try {
      final json = jsonDecode(raw ?? '{}') as Map;
      _everywhere = json['everywhere'] == true;
      for (final value in json['rests'] as List? ?? []) {
        try {
          final rest = ListeningRest.fromJson(Map<String, dynamic>.from(value as Map));
          if (rest.active(DateTime.now())) _rests[rest.key] = rest;
        } on Object {
          /* Keep the remaining valid choices. */
        }
      }
      for (final entry in (json['transitions'] as Map? ?? {}).entries) {
        final value = SongTransition.values.where((v) => v.name == entry.value).firstOrNull;
        if (entry.key is String && value != null) _transitions[entry.key as String] = value;
      }
    } on Object {
      /* Damaged preferences never block playback. */
    }
    _scope = scope;
    changed.value++;
  }

  static List<ListeningRest> get rests =>
      _scope == RadioPreferencesStore.scope ? _rests.values.where((r) => r.active(DateTime.now())).toList() : [];

  /// Whether blocked artists and resting songs are left out of the lists the listener opens (albums, playlists, artist
  /// pages) as well as generated mixes.
  static bool get everywhere => _scope == RadioPreferencesStore.scope && _everywhere;

  static Future<void> setEverywhere(bool value) => _serialize(() async {
    await _load();
    _everywhere = value;
    await _save();
  });

  /// Whether blocks and rests apply to songs from [source]: generated mixes always; the lists the listener opens with
  /// [everywhere]; never what they put in the queue themselves ([byHand]).
  /// Never a SyncPlay group's queue, which must stay the same as everyone else's.
  static bool appliesTo(QueueItemSource source, {bool byHand = false}) =>
      source.type != QueueItemSourceType.remoteClient && (isGeneratedSource(source) || (!byHand && everywhere));

  static bool permits(BaseItemDto item, {DateTime? now}) {
    if (_scope != RadioPreferencesStore.scope) return true;
    final at = now ?? DateTime.now();
    if (_rests['track:${item.id.raw}']?.active(at) ?? false) return false;
    final blocked = [
      for (final rest in _rests.values)
        if (rest.artist && rest.active(at)) rest,
    ];
    if (blocked.isEmpty) return true;
    final keys = artistKeysOf(item);
    final ids = {for (final artist in item.artistItems ?? <NameIdPair>[]) artist.id.raw};
    return !blocked.any(
      (rest) =>
          keys.contains(rest.key.substring('artist:'.length)) || (rest.artistId != null && ids.contains(rest.artistId)),
    );
  }

  /// A list the listener opened, without blocked artists and resting songs, but with the song they [picked]. If that
  /// leaves nothing else, the list stays as it is ([allBlocked]): they asked for it.
  static ({List<BaseItemDto> tracks, bool allBlocked}) filterOpened(List<BaseItemDto> items, {BaseItemDto? picked}) {
    final kept = items.where((item) => item.id == picked?.id || permits(item)).toList();
    if (kept.length == items.length) return (tracks: items, allBlocked: false);
    // The picked song (any copy of it) doesn't count as something else left.
    if (!kept.any((item) => item.id != picked?.id)) return (tracks: items, allBlocked: true);
    return (tracks: kept, allBlocked: false);
  }

  /// Every artist credited on [item] as a key, featured ones too; the album's artist only when none is.
  /// "Unknown Artist" and the like don't count as credited.
  static Set<String> artistKeysOf(BaseItemDto item) {
    final keys = {
      for (final name in [...?item.artists, for (final artist in item.artistItems ?? <NameIdPair>[]) artist.name])
        ?ArtistSpacing.keyOfName(name),
    };
    return keys.isNotEmpty ? keys : {?ArtistSpacing.keyOfName(item.albumArtist)};
  }

  /// The artists credited on [item], each once, with their library id when known, to choose which to block. Not
  /// "Various Artists" or a name with no letters, which can't be blocked.
  static List<BlockableArtist> artistsOf(BaseItemDto item) {
    final seen = <String>{};
    return [
      for (final artist in item.artistItems ?? <NameIdPair>[])
        if (artist.name case final name?
            when ArtistSpacing.keyOfName(name) != null && seen.add(ArtistSpacing.keyOfName(name)!))
          (name: name, id: artist.id.raw),
      for (final name in [
        ...?item.artists,
        if (seen.isEmpty && (item.artists ?? []).every((name) => ArtistSpacing.keyOfName(name) == null))
          item.albumArtist,
      ])
        if (name != null && ArtistSpacing.keyOfName(name) != null && seen.add(ArtistSpacing.keyOfName(name)!))
          (name: name, id: null),
    ];
  }

  /// Whether [artist] is credited on [item], as [permits] matches a block on them.
  static bool credits(BaseItemDto item, BlockableArtist artist) =>
      artistKeysOf(item).contains(ArtistSpacing.keyOfName(artist.name)) ||
      (artist.id != null && (item.artistItems ?? <NameIdPair>[]).any((credit) => credit.id.raw == artist.id));

  /// The block on [artist], if they're blocked now.
  static ListeningRest? blockOf(BlockableArtist artist) {
    final key = ArtistSpacing.keyOfName(artist.name);
    return rests.firstWhereOrNull(
      (rest) => rest.artist && (rest.key == 'artist:$key' || (artist.id != null && rest.artistId == artist.id)),
    );
  }

  /// The rest on [item] itself and the blocks on its artists, active now.
  static List<ListeningRest> restsFor(BaseItemDto item) {
    final keys = artistKeysOf(item);
    final ids = {for (final artist in item.artistItems ?? <NameIdPair>[]) artist.id.raw};
    return [
      for (final rest in rests)
        if (rest.key == 'track:${item.id.raw}' ||
            (rest.artist &&
                (keys.contains(rest.key.substring('artist:'.length)) ||
                    (rest.artistId != null && ids.contains(rest.artistId)))))
          rest,
    ];
  }

  /// Blocks [artists] until [until] ([ListeningRest.forever] for good), replacing any block they had.
  static Future<void> blockArtists(List<BlockableArtist> artists, DateTime until) => _serialize(() async {
    await _load();
    for (final artist in artists) {
      final key = ArtistSpacing.keyOfName(artist.name);
      if (key == null) continue;
      // A block found by id under another spelling of the name is replaced too; the id it knew is kept.
      final id = artist.id ?? _rests['artist:$key']?.artistId;
      _rests.removeWhere((_, rest) => rest.artist && id != null && rest.artistId == id);
      _rests['artist:$key'] = ListeningRest(
        key: 'artist:$key',
        name: artist.name,
        until: until,
        artist: true,
        artistId: id,
      );
    }
    await _save();
  });

  /// Rests [item] itself until [until].
  static Future<void> restSong(BaseItemDto item, DateTime until) => _serialize(() async {
    await _load();
    final key = 'track:${item.id.raw}';
    _rests[key] = ListeningRest(key: key, name: item.name ?? item.id.raw, until: until, artist: false);
    await _save();
  });

  static Future<void> rest(BaseItemDto item, {required bool artist, required int days}) {
    final until = DateTime.now().add(Duration(days: max(1, days)));
    if (!artist) return restSong(item, until);
    final first = artistsOf(item).firstOrNull;
    return first == null ? Future.value() : blockArtists([first], until);
  }

  static Future<void> removeRest(String key) => _serialize(() async {
    await _load();
    _rests.remove(key);
    await _save();
  });

  /// Ends every rest and block.
  static Future<void> clearRests() => _serialize(() async {
    await _load();
    _rests.clear();
    await _save();
  });
  static SongTransition transition(String? id) =>
      _scope == RadioPreferencesStore.scope ? _transitions[id] ?? SongTransition.automatic : SongTransition.automatic;
  static Future<void> setTransition(String id, SongTransition value) => _serialize(() async {
    await _load();
    if (value == SongTransition.automatic) {
      _transitions.remove(id);
    } else {
      _transitions[id] = value;
    }
    await _save();
  });
  static int fadeSeconds(String? outgoing, String? incoming, int seconds) {
    final from = transition(outgoing), into = transition(incoming);
    if (from == SongTransition.fullEnding || from == SongTransition.gapless || into == SongTransition.gapless) return 0;
    return from == SongTransition.shortFade || into == SongTransition.shortFade ? seconds.clamp(0, 2) : seconds;
  }

  static Future<void> _save() async {
    final scope = _scope;
    if (scope == null || scope != RadioPreferencesStore.scope) throw StateError('The active account changed.');
    _rests.removeWhere((_, value) => !value.active(DateTime.now()));
    await SharedPreferencesAsync().setString(
      'listeningChoices.$scope',
      jsonEncode({
        'everywhere': _everywhere,
        'rests': _rests.values.map((v) => v.toJson()).toList(),
        'transitions': {for (final entry in _transitions.entries) entry.key: entry.value.name},
      }),
    );
    changed.value++;
  }
}

/// Deliberately ephemeral. This affects Finamp's local recommendation learning,
/// not Jellyfin playback reporting, scrobbles, or the visible listening history.
class ListeningSession {
  static final excludeFromLearning = ValueNotifier<bool>(false);
  static final _excluded = Expando<bool>();
  static void begin(Object listen) {
    _excluded[listen] = excludeFromLearning.value;
  }

  static void exclude(Object? listen) {
    if (listen != null) _excluded[listen] = true;
  }

  static bool excluded(Object listen) => _excluded[listen] ?? excludeFromLearning.value;
}
