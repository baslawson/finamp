import 'dart:convert';

import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/artist_spacing.dart';
import 'package:finamp/services/radio_preferences.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum SongTransition { automatic, fullEnding, shortFade, gapless }

class ListeningRest {
  const ListeningRest({required this.key, required this.name, required this.until, required this.artist});
  final String key, name;
  final DateTime until;
  final bool artist;
  bool active(DateTime now) => until.isAfter(now);
  Map<String, dynamic> toJson() => {
    'key': key,
    'name': name,
    'until': until.toUtc().toIso8601String(),
    'artist': artist,
  };
  factory ListeningRest.fromJson(Map<String, dynamic> json) => ListeningRest(
    key: json['key'] as String,
    name: json['name'] as String,
    until: DateTime.parse(json['until'] as String),
    artist: json['artist'] == true,
  );
}

/// Account-scoped opt-outs for generated lists. Explicit album/artist playback
/// and the seed a listener deliberately picked remain available.
class ListeningPreferences {
  static String? _scope;
  static final _rests = <String, ListeningRest>{};
  static final _transitions = <String, SongTransition>{};
  static Future<void> _tail = Future.value();
  static final changed = ValueNotifier<int>(0);

  static Future<void> _serialize(Future<void> Function() action) {
    final next = _tail.catchError((Object _) {}).then((_) => action());
    _tail = next;
    return next;
  }

  static Future<void> ensureLoaded() => _serialize(_load);
  static Future<void> _load() async {
    final scope = RadioPreferencesStore.scope;
    if (_scope == scope) return;
    final raw = await SharedPreferencesAsync().getString('listeningChoices.$scope');
    if (scope != RadioPreferencesStore.scope) return;
    _rests.clear();
    _transitions.clear();
    try {
      final json = jsonDecode(raw ?? '{}') as Map;
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
  static bool permits(BaseItemDto item, {DateTime? now}) {
    if (_scope != RadioPreferencesStore.scope) return true;
    final at = now ?? DateTime.now();
    return !(_rests['track:${item.id.raw}']?.active(at) ?? false) &&
        !(_rests['artist:${ArtistSpacing.artistKey(item)}']?.active(at) ?? false);
  }

  static Future<void> rest(BaseItemDto item, {required bool artist, required int days}) => _serialize(() async {
    await _load();
    final key = artist ? ArtistSpacing.artistKey(item) : item.id.raw;
    if (key == null) return;
    final id = '${artist ? 'artist' : 'track'}:$key';
    _rests[id] = ListeningRest(
      key: id,
      name: artist ? item.artists?.firstOrNull ?? item.albumArtist ?? key : item.name ?? key,
      until: DateTime.now().add(Duration(days: days.clamp(1, 31))),
      artist: artist,
    );
    await _save();
  });
  static Future<void> removeRest(String key) => _serialize(() async {
    await _load();
    _rests.remove(key);
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
