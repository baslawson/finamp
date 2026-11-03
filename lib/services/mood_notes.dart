import 'dart:convert';

import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/radio_preferences.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A song the listener said doesn't fit an AI DJ request ("Not for this mood").
class MoodNote {
  const MoodNote({
    required this.trackId,
    required this.title,
    required this.artist,
    required this.request,
    required this.at,
  });

  final String trackId;
  final String title;
  final String artist;

  /// What the listener asked the AI DJ for when they said so.
  final String request;
  final DateTime at;

  Map<String, dynamic> toJson() => {
    "id": trackId,
    "title": title,
    "artist": artist,
    "request": request,
    "at": at.millisecondsSinceEpoch,
  };

  static MoodNote? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final (id, request, at) = (json["id"], json["request"], json["at"]);
    if (id is! String || request is! String || at is! int) return null;
    return MoodNote(
      trackId: id,
      title: json["title"] as String? ?? "",
      artist: json["artist"] as String? ?? "",
      request: request,
      at: DateTime.fromMillisecondsSinceEpoch(at),
    );
  }
}

/// "Not for this mood": songs the listener took out of an AI DJ mix, with what that mix was asked for, so the AI leaves
/// them out of mixes for similar requests. One note per song (the latest), at most [maxNotes], for [keepFor].
class MoodNotes {
  MoodNotes._();

  static const maxNotes = 50;
  static const keepFor = Duration(days: 90);

  /// The source id of AI DJ mixes, whose name is "Ai DJ: " and the mix's name.
  static const aiDjSourceId = "aiDj";
  static const aiDjNamePrefix = "Ai DJ: ";

  static const _notesKey = "aiDjMoodNotes_";

  /// The server and account the notes belong to: each keeps its own.
  @visibleForTesting
  static String Function() scope = () => RadioPreferencesStore.scope;

  /// Bumped whenever the notes change, for a list showing them.
  static final changed = ValueNotifier<int>(0);

  @visibleForTesting
  static DateTime Function() now = DateTime.now;

  static Future<List<MoodNote>> load() => _load(scope());

  static Future<List<MoodNote>> _load(String scope) async {
    try {
      final stored = await SharedPreferencesAsync().getString("$_notesKey$scope");
      if (stored == null) return [];
      final cutoff = now().subtract(keepFor);
      return [
        for (final json in jsonDecode(stored) as List<dynamic>)
          if (MoodNote.fromJson(json) case final note? when note.at.isAfter(cutoff)) note,
      ];
    } catch (_) {
      // Unreadable notes are no notes.
      return [];
    }
  }

  /// Each change waits for the one before, so two at once (removing two notes, say) don't undo each other.
  static Future<void> _changing = Future.value();

  static Future<void> _change(List<MoodNote> Function(List<MoodNote> notes) change) {
    // For the account it was asked for, even if another signs in meanwhile.
    final account = scope();
    final done = _changing.then((_) async => _save(account, change(await _load(account))));
    _changing = done.catchError((_) {});
    return done;
  }

  static Future<void> _save(String scope, List<MoodNote> notes) async {
    await SharedPreferencesAsync().setString("$_notesKey$scope", jsonEncode([for (final note in notes) note.toJson()]));
    changed.value++;
  }

  /// Notes that [track] doesn't fit [request], replacing what was noted about it before. The oldest go past
  /// [maxNotes].
  static Future<void> add(BaseItemDto track, String request) => _change((notes) {
    final kept = notes.where((note) => note.trackId != track.id.raw).toList()
      ..add(
        MoodNote(
          trackId: track.id.raw,
          title: track.name ?? "",
          artist: track.albumArtist ?? track.artists?.firstOrNull ?? "",
          request: request,
          at: now(),
        ),
      );
    kept.sort((a, b) => a.at.compareTo(b.at));
    return kept.length > maxNotes ? kept.sublist(kept.length - maxNotes) : kept;
  });

  static Future<void> remove(String trackId) =>
      _change((notes) => notes.where((note) => note.trackId != trackId).toList());

  static Future<void> clear() => _change((_) => const []);

  /// What the AI DJ mix [source] was asked for (kept with each of its songs), or null for anything else.
  static String? requestFor(QueueItemSource source) => source.id == aiDjSourceId ? source.mixRequest : null;

  /// Whether [a] and [b] are the very same request, give or take case, spacing and punctuation.
  static bool sameRequest(String a, String b) => _requestKey(a) == _requestKey(b);

  static String _requestKey(String request) =>
      request.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ').trim();

  /// The part of the AI DJ prompt about [notes] whose songs are in the [catalog] it sees, by their number there; empty
  /// when there are none.
  static String promptSection(List<MoodNote> notes, List<BaseItemDto> catalog) {
    final numbers = {for (final (index, track) in catalog.indexed) track.id.raw: index};
    final lines = [
      for (final note in notes)
        if (numbers[note.trackId] case final number?)
          '$number (${note.title} by ${note.artist}): not for "${note.request.replaceAll('"', "'")}"',
    ];
    if (lines.isEmpty) return "";
    return '''

The listener said these tracks didn't fit earlier requests. Leave a track out when this request is like the one it was turned down for (the same mood, moment or sound); for a different request it may still fit:
${lines.join("\n")}
''';
  }
}
