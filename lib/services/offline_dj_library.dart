import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/dj_recordings.dart';
import 'package:finamp/services/dj_voice_settings.dart';
import 'package:finamp/services/radio_preferences.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

final _offlineId = RegExp(r'^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$');

class OfflineDjVoice {
  const OfflineDjVoice(this.fileName, this.text);
  final String fileName, text;
  Map<String, dynamic> toJson() => {'file': fileName, 'text': text};
}

class OfflineDjMix {
  OfflineDjMix({
    required this.id,
    required this.playlist,
    required this.tracks,
    required this.profile,
    required this.includeDj,
    required this.createdAt,
    this.stationId,
    Map<String, OfflineDjVoice>? voices,
  }) : voices = voices ?? {};
  final String id;
  final BaseItemDto playlist;
  final List<BaseItemDto> tracks;
  final DjVoiceProfile profile;
  final DateTime createdAt;
  final String? stationId;
  bool includeDj;
  final Map<String, OfflineDjVoice> voices;
  Map<String, dynamic> toJson() => {
    'id': id,
    'playlist': playlist.toJson(),
    'tracks': tracks.map((track) => track.toJson()).toList(),
    'profile': profile.toJson(),
    'includeDj': includeDj,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'stationId': stationId,
    'voices': {for (final entry in voices.entries) entry.key: entry.value.toJson()},
  };

  factory OfflineDjMix.fromJson(Map<String, dynamic> json) {
    final id = json['id'] as String;
    if (!_offlineId.hasMatch(id)) throw const FormatException('Invalid offline mix identifier');
    final tracks = (json['tracks'] as List)
        .map((value) => BaseItemDto.fromJson(Map<String, dynamic>.from(value as Map)))
        .toList();
    if (tracks.isEmpty || tracks.length > 50) throw const FormatException('Invalid offline mix length');
    final voices = <String, OfflineDjVoice>{};
    for (final entry in ((json['voices'] as Map?) ?? const {}).entries) {
      if (entry.key is! String || entry.value is! Map) continue;
      final value = Map<String, dynamic>.from(entry.value as Map);
      final file = value['file'], text = value['text'];
      if (file is String &&
          file.endsWith('.wav') &&
          _offlineId.hasMatch(file.substring(0, file.length - 4)) &&
          text is String) {
        voices[entry.key as String] = OfflineDjVoice(file, text);
      }
    }
    return OfflineDjMix(
      id: id,
      playlist: BaseItemDto.fromJson(Map<String, dynamic>.from(json['playlist'] as Map)),
      tracks: List.unmodifiable(tracks),
      profile: DjVoiceProfile.fromJson(Map<String, dynamic>.from(json['profile'] as Map)),
      includeDj: json['includeDj'] == true,
      createdAt: DateTime.parse(json['createdAt'] as String),
      stationId: json['stationId'] as String?,
      voices: voices,
    );
  }
}

/// Files live in an account-scoped application directory. The music itself
/// remains owned by the normal download service and its shared-track graph.
class OfflineDjLibrary {
  OfflineDjLibrary(this.root, {required this.scope});
  final Directory root;
  final String scope;
  final changed = ValueNotifier<int>(0);
  final Map<String, OfflineDjMix> _mixes = {};
  bool _loaded = false;
  final Map<String, Future<void>> _writes = {};

  static OfflineDjLibrary? _active;
  static Future<OfflineDjLibrary>? _opening;
  static String? _openingScope;
  static Future<OfflineDjLibrary> current() {
    final scope = RadioPreferencesStore.scope;
    if (_active?.scope == scope) return Future.value(_active!);
    if (_openingScope == scope && _opening != null) return _opening!;
    late final Future<OfflineDjLibrary> opening;
    opening =
        (() async {
          final folder = await getApplicationSupportDirectory();
          final library = OfflineDjLibrary(Directory(path.join(folder.path, 'offline-dj', scope)), scope: scope);
          await library.load();
          if (scope != RadioPreferencesStore.scope) throw StateError('The active account changed.');
          _active = library;
          return library;
        })().whenComplete(() {
          if (identical(_opening, opening)) {
            _opening = null;
            _openingScope = null;
          }
        });
    _openingScope = scope;
    _opening = opening;
    return opening;
  }

  static OfflineDjMix? cachedForPlaylist(String playlistId) =>
      _active?.scope == RadioPreferencesStore.scope ? _active!.forPlaylist(playlistId) : null;

  List<OfflineDjMix> get mixes =>
      List.unmodifiable(_mixes.values.toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt)));
  bool contains(OfflineDjMix mix) => identical(_mixes[mix.id], mix);
  OfflineDjMix? forPlaylist(String id) => _mixes.values.where((mix) => mix.playlist.id.raw == id).firstOrNull;

  Directory _folder(String id) {
    if (!_offlineId.hasMatch(id)) throw const FormatException('Invalid offline mix identifier');
    final folder = Directory(path.join(root.path, id));
    if (!path.isWithin(root.absolute.path, folder.absolute.path) ||
        FileSystemEntity.typeSync(folder.path, followLinks: false) == FileSystemEntityType.link) {
      throw const FileSystemException('Unsafe offline mix directory');
    }
    return folder;
  }

  Future<void> load() async {
    if (_loaded) return;
    if (await root.exists()) {
      await for (final entity in root.list(followLinks: false)) {
        if (entity is! Directory || !_offlineId.hasMatch(path.basename(entity.path))) continue;
        try {
          final file = File(path.join(_folder(path.basename(entity.path)).path, 'manifest.json'));
          if (await file.length() > 4 * 1024 * 1024) continue;
          final mix = OfflineDjMix.fromJson(jsonDecode(await file.readAsString()) as Map<String, dynamic>);
          if (mix.id == path.basename(entity.path)) _mixes[mix.id] = mix;
        } on Object {
          /* Keep other complete manifests when a download was interrupted. */
        }
      }
    }
    _loaded = true;
  }

  Future<void> add(OfflineDjMix mix) async {
    if (_mixes.containsKey(mix.id)) throw StateError('The offline mix already exists.');
    _mixes[mix.id] = mix;
    try {
      await save(mix);
    } catch (_) {
      _mixes.remove(mix.id);
      rethrow;
    }
  }

  Future<void> save(OfflineDjMix mix) {
    final json = jsonEncode(mix.toJson());
    late final Future<void> write;
    write = (_writes[mix.id] ?? Future<void>.value())
        .catchError((Object _) {})
        .then((_) async {
          if (!contains(mix)) return;
          final folder = _folder(mix.id);
          await folder.create(recursive: true);
          final temporary = File(path.join(folder.path, 'manifest.json.tmp'));
          await temporary.writeAsString(json, flush: true);
          if (!contains(mix)) {
            await temporary.delete();
            return;
          }
          await temporary.rename(path.join(folder.path, 'manifest.json'));
          changed.value++;
        })
        .whenComplete(() {
          if (identical(_writes[mix.id], write)) _writes.remove(mix.id);
        });
    _writes[mix.id] = write;
    return write;
  }

  Future<void> saveVoice(OfflineDjMix mix, String trackId, DjAudioClip clip) async {
    if (!contains(mix) || !mix.includeDj || !mix.tracks.any((track) => track.id.raw == trackId)) return;
    final size = await clip.file.length();
    if (size < 44 || size > 6 * 1024 * 1024) throw const FormatException('Invalid saved voice length');
    final folder = _folder(mix.id);
    await folder.create(recursive: true);
    final name = '${const Uuid().v4()}.wav';
    final copy = await clip.file.copy(path.join(folder.path, name));
    if (!contains(mix) || !mix.includeDj) {
      await copy.delete();
      return;
    }
    final previous = mix.voices[trackId];
    mix.voices[trackId] = OfflineDjVoice(name, clip.text);
    try {
      await save(mix);
    } catch (_) {
      previous == null ? mix.voices.remove(trackId) : mix.voices[trackId] = previous;
      await copy.delete();
      rethrow;
    }
    if (previous != null) await File(path.join(folder.path, previous.fileName)).delete().catchError((_) => copy);
  }

  Future<DjAudioClip?> copyVoice(OfflineDjMix mix, String trackId) async {
    final voice = mix.voices[trackId];
    if (!contains(mix) || !mix.includeDj || voice == null) return null;
    try {
      final input = File(path.join(_folder(mix.id).path, voice.fileName));
      if (await input.length() > 6 * 1024 * 1024) return null;
      final temp = await getTemporaryDirectory();
      final copy = await input.copy(path.join(temp.path, 'dj-offline-${const Uuid().v4()}.wav'));
      if (!contains(mix) || !mix.includeDj) {
        await copy.delete();
        return null;
      }
      return DjAudioClip(copy, voice.text);
    } on FileSystemException {
      return null;
    }
  }

  Future<bool> hasVoice(OfflineDjMix mix, String trackId) async {
    final voice = mix.voices[trackId];
    if (!mix.includeDj || voice == null) return false;
    final file = File(path.join(_folder(mix.id).path, voice.fileName));
    try {
      final size = await file.length();
      return size >= 44 && size <= 6 * 1024 * 1024;
    } on FileSystemException {
      return false;
    }
  }

  Future<void> clearVoices(OfflineDjMix mix) async {
    if (!contains(mix)) return;
    mix.includeDj = false;
    mix.voices.clear();
    await save(mix);
    final folder = _folder(mix.id);
    if (await folder.exists()) {
      await for (final file in folder.list(followLinks: false)) {
        if (file is File && path.extension(file.path) == '.wav') await file.delete();
      }
    }
    changed.value++;
  }

  Future<void> remove(OfflineDjMix mix) async {
    _mixes.remove(mix.id);
    await _writes[mix.id]?.catchError((Object _) {});
    final folder = _folder(mix.id);
    if (await folder.exists()) await folder.delete(recursive: true);
    changed.value++;
  }

  static Future<void> removeForPlaylist(String playlistId, {required String expectedScope}) async {
    if (expectedScope != RadioPreferencesStore.scope) return;
    final library = await current();
    if (expectedScope != library.scope) return;
    final mix = library.forPlaylist(playlistId);
    if (mix != null) await library.remove(mix);
  }
}
