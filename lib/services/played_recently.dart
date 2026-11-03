import 'dart:convert';

import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/radio_preferences.dart';
import 'package:finamp/services/song_duplicates.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Songs heard in the chosen time, so that with "Don't repeat songs" on, new queues (playlists, albums, mixes, Radio)
/// leave them out: the same recording, and its other versions as [withoutDuplicateSongs] counts them.
class PlayedRecently {
  PlayedRecently._();

  static final _logger = Logger("PlayedRecently");

  /// The times to choose from for how long a heard song is left out, in hours, besides a custom one.
  static const presets = [1, 3, 6, 12, 24];

  /// The longest custom time, in hours, and so how long plays are kept: a longer time chosen later knows them.
  static const maxHours = 72;

  static const _defaultHours = 24;

  /// How long a heard song is left out for, in hours, as last loaded.
  static int get hours => _hours ?? _defaultHours;

  static Duration get window => Duration(hours: hours);

  /// Listened to for this long, a song of unknown length counts as heard.
  static const unknownLength = Duration(seconds: 90);

  static const _onKey = "playedRecentlyNoRepeats";
  static const _hoursKey = "playedRecentlyHours";

  /// Followed by the server and account: item ids belong to one server.
  static const _playsKey = "playedRecentlyPlays_";

  /// Bumped when the setting or the list changes, for the settings screen.
  static final changed = ValueNotifier(0);

  @visibleForTesting
  static DateTime Function() now = DateTime.now;

  /// The server and account the list belongs to.
  @visibleForTesting
  static String Function() scope = () => RadioPreferencesStore.scope;

  static bool? _on;
  static int? _hours;
  static List<({BaseItemDto track, DateTime at})>? _plays;
  static Future<void>? _loading;
  static String? _loadedScope;
  static Future<void> _saving = Future.value();

  /// Whether heard songs are being left out, as last loaded.
  static bool get isOn => _on ?? false;

  /// Loads the setting and the list, again after switching server or account.
  static Future<void> ensureLoaded() {
    final current = scope();
    if (_loading == null || _loadedScope != current) {
      _loadedScope = current;
      _plays = null;
      _loading = _load(current);
    }
    return _loading!;
  }

  static Future<void> _load(String scope) async {
    final prefs = SharedPreferencesAsync();
    try {
      _on = await prefs.getBool(_onKey) ?? false;
      _hours = (await prefs.getInt(_hoursKey) ?? _defaultHours).clamp(1, maxHours);
      final plays = <({BaseItemDto track, DateTime at})>[];
      for (final json in jsonDecode(await prefs.getString("$_playsKey$scope") ?? "[]") as List<dynamic>) {
        final play = json as Map<String, dynamic>;
        plays.add((
          track: BaseItemDto(
            id: BaseItemId(play["id"] as String),
            name: play["n"] as String?,
            artists: (play["ar"] as List<dynamic>?)?.cast<String>(),
            albumArtist: play["aa"] as String?,
            album: play["al"] as String?,
            type: "Audio",
          ),
          at: DateTime.fromMillisecondsSinceEpoch(play["t"] as int),
        ));
      }
      // Not if the server changed while loading: that one's list is loading now.
      if (_loadedScope == scope) _plays = plays;
    } catch (e) {
      _logger.warning("Couldn't read recently played songs", e);
      _on ??= false;
      if (_loadedScope == scope) _plays = [];
    }
  }

  /// Sets how long a heard song is left out for, from 1 hour up to [maxHours].
  static Future<void> setHours(int value) async {
    await ensureLoaded();
    _hours = value.clamp(1, maxHours);
    changed.value++;
    await SharedPreferencesAsync().setInt(_hoursKey, _hours!);
  }

  static Future<void> setOn(bool on) async {
    await ensureLoaded();
    _on = on;
    changed.value++;
    await SharedPreferencesAsync().setBool(_onKey, on);
  }

  /// Whether listening for [played] of a song lasting [total] counts as hearing it: at least half of it.
  static bool heard(Duration played, Duration? total) =>
      total == null || total <= Duration.zero ? played >= unknownLength : played * 2 >= total;

  /// Notes that [track] was listened to for [played], counted if that's [heard]. Recorded even while the setting is
  /// off, so turning it on knows what was heard already.
  static Future<void> record(BaseItemDto track, {required Duration played, Duration? total}) async {
    if (!heard(played, total)) return;
    final account = scope();
    await ensureLoaded();
    // Switched server or account meanwhile: the play isn't the new one's.
    if (_loadedScope != account) return;
    _prune();
    (_plays ??= [])
      ..removeWhere((play) => play.track.id == track.id)
      ..add((track: track, at: now()));
    changed.value++;
    await _save();
  }

  /// Forgets every song heard, so they can all play again.
  static Future<void> clear() async {
    await ensureLoaded();
    _plays?.clear();
    changed.value++;
    await _save();
  }

  /// Plays are kept for the longest time that can be chosen.
  static void _prune() => _plays?.removeWhere((play) => now().difference(play.at) >= const Duration(hours: maxHours));

  /// The plays within the chosen time.
  static Iterable<({BaseItemDto track, DateTime at})> get _recent {
    _prune();
    final time = now();
    return (_plays ?? const <({BaseItemDto track, DateTime at})>[]).where((play) => time.difference(play.at) < window);
  }

  static Future<void> _save() {
    final scope = _loadedScope;
    final plays = [
      for (final play in _plays ?? const <({BaseItemDto track, DateTime at})>[])
        {
          "id": play.track.id.raw,
          if (play.track.name != null) "n": play.track.name,
          if (play.track.artists != null) "ar": play.track.artists,
          if (play.track.albumArtist != null) "aa": play.track.albumArtist,
          if (play.track.album != null) "al": play.track.album,
          "t": play.at.millisecondsSinceEpoch,
        },
    ];
    return _saving = _saving.then((_) async {
      try {
        await SharedPreferencesAsync().setString("$_playsKey$scope", jsonEncode(plays));
      } catch (e) {
        _logger.warning("Couldn't save recently played songs", e);
      }
    });
  }

  /// How many songs were heard in the chosen time, as of the last load.
  static int get heardCount => _recent.length;

  /// The songs heard in the chosen time, while the setting is on (none while it's off), as of the last load.
  static List<BaseItemDto> get blocking {
    if (!isOn || _loadedScope != scope()) return const [];
    return [for (final play in _recent) play.track];
  }

  /// [tracks] without the songs heard in the chosen time, keeping [keep] (a song picked to start with). When none
  /// but [keep] would be left, all of [tracks] stay and [allHeard] says so: something plays rather than nothing. Without
  /// [fallBack] (the rest of a list whose start had songs to play), heard songs go even if none are left.
  /// [through] are tracks left out for other reasons (like being unplayable) that still link a heard song's versions.
  static ({List<BaseItemDto> tracks, bool allHeard}) filter(
    List<BaseItemDto> tracks, {
    BaseItemDto? keep,
    bool fallBack = true,
    Iterable<BaseItemDto> through = const [],
  }) {
    final heard = blocking;
    if (heard.isEmpty || tracks.isEmpty) return (tracks: tracks, allHeard: false);
    // Only tracks sharing a title with a heard song can be one, so the rest needn't be compared.
    final titles = {for (final track in heard) songKey(track)};
    final heardIds = {for (final track in heard) track.id};
    final suspects = [
      for (final track in tracks)
        if (heardIds.contains(track.id) || titles.contains(songKey(track))) track,
    ];
    final suspectIds = {for (final track in suspects) track.id};
    final fresh = {
      for (final track in withoutSongsIn(
        suspects,
        heard,
        through: through.where((track) => titles.contains(songKey(track))),
      ))
        track.id,
    };
    final left = <BaseItemDto>[
      for (final track in tracks)
        if (track.id == keep?.id || !suspectIds.contains(track.id) || fresh.contains(track.id)) track,
    ];
    if (left.every((track) => track.id == keep?.id)) return (tracks: fallBack ? tracks : left, allHeard: true);
    return (tracks: left, allHeard: false);
  }

  /// [tracks] with the songs heard in the chosen time moved to the end, for picking the others first.
  static List<BaseItemDto> heardLast(List<BaseItemDto> tracks) {
    final fresh = filter(tracks, fallBack: false).tracks;
    if (fresh.length == tracks.length) return tracks;
    final ids = {for (final track in fresh) track.id};
    return [...fresh, ...tracks.where((track) => !ids.contains(track.id))];
  }

  @visibleForTesting
  static void reset() {
    _on = null;
    _hours = null;
    _plays = null;
    _loading = null;
    _saving = Future.value();
    now = DateTime.now;
    scope = () => RadioPreferencesStore.scope;
    _loadedScope = null;
  }
}
