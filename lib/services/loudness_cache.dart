import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'analyzer_service.dart';
import 'loudness_normalization.dart';

/// Measurements persist across restarts and remain usable without the analyzer.
/// Each Jellyfin server gets its own namespace, including when switching users.
class LoudnessCache {
  LoudnessCache({
    Future<String?> Function()? read,
    Future<void> Function(String)? write,
    Future<String?> Function()? readDownloads,
    Future<void> Function(String)? writeDownloads,
    Future<Map<String, Map<String, dynamic>>> Function(List<String>)? fetch,
    Future<bool> Function()? isConfigured,
  }) : _read = read ?? (() => SharedPreferencesAsync().getString('loudnessMeasurementsV1')),
       _write = write ?? ((json) => SharedPreferencesAsync().setString('loudnessMeasurementsV1', json)),
       _readDownloads = readDownloads ?? (() => SharedPreferencesAsync().getString('downloadLoudnessMeasurementsV1')),
       _writeDownloads =
           writeDownloads ?? ((json) => SharedPreferencesAsync().setString('downloadLoudnessMeasurementsV1', json)),
       _fetch = fetch ?? AnalyzerService.loudness,
       _isConfigured = isConfigured ?? AnalyzerService.isConfigured;

  static final instance = LoudnessCache();
  final Future<String?> Function() _read;
  final Future<void> Function(String) _write;
  final Future<String?> Function() _readDownloads;
  final Future<void> Function(String) _writeDownloads;
  final Future<Map<String, Map<String, dynamic>>> Function(List<String>) _fetch;
  final Future<bool> Function() _isConfigured;
  final _values = <String, Map<String, dynamic>>{};
  final _downloads = <String, Map<String, dynamic>>{};
  final _downloadGenerations = <String, int>{};
  Future<void>? _loading;
  Future<void> _writes = Future.value();
  final _pending = <String, Future<void>>{};
  final _attempted = <String, DateTime>{};
  int _generation = 0;
  final changes = StreamController<void>.broadcast();

  void invalidateRequests() {
    _generation++;
    _attempted.clear();
    _pending.clear();
  }

  Future<void> load() => _loading ??= () async {
    Future<void> restore(Future<String?> Function() read, Map<String, Map<String, dynamic>> into) async {
      try {
        final saved = await read();
        if (saved == null) return;
        final json = jsonDecode(saved) as Map<String, dynamic>;
        for (final entry in json.entries) {
          if (entry.value is Map) into[entry.key] = Map<String, dynamic>.from(entry.value as Map);
        }
      } catch (_) {
        /* A damaged cache must not stop playback. */
      }
    }

    await Future.wait([restore(_read, _values), restore(_readDownloads, _downloads)]);
  }();

  String _key(String server, String id) => '$server/${id.replaceAll('-', '')}';
  LoudnessMeasurement? get(String server, String id, {bool downloaded = false}) {
    final key = _key(server, id);
    final json = downloaded && _downloads.containsKey(key) ? _downloads[key] : _values[key];
    return json == null ? null : LoudnessMeasurement.fromJson(json);
  }

  /// Serve the immediate playback window before fetching the rest of a queue.
  Future<void> fetchAhead(String server, List<String> ids, {bool offline = false}) async {
    final wanted = ids.toSet().take(2000).toList();
    final generation = _generation;
    await fetch(server, wanted.take(6).toList(), offline: offline);
    if (offline) return;
    for (var start = 6; start < wanted.length && generation == _generation; start += 64) {
      await fetch(server, wanted.skip(start).take(64).toList());
    }
  }

  /// Keep the measurement belonging to a completed download even when its
  /// server original is replaced or its online measurement is invalidated.
  Future<void> pinDownload(String server, String id, {bool offline = false}) async {
    final key = _key(server, id);
    final downloadGeneration = (_downloadGenerations[key] ?? 0) + 1;
    _downloadGenerations[key] = downloadGeneration;
    final generation = _generation;
    await fetch(server, [id], offline: offline);
    if (generation != _generation || _downloadGenerations[key] != downloadGeneration) return;
    _downloads[key] = Map<String, dynamic>.from(_values[key] ?? const {});
    try {
      _writes = _writes.catchError((_) {}).then((_) => _writeDownloads(jsonEncode(_downloads)));
      await _writes;
    } catch (_) {
      /* A metadata write must never fail a completed music download. */
    }
  }

  Future<void> unpinDownload(String server, String id) async {
    final key = _key(server, id);
    _downloadGenerations[key] = (_downloadGenerations[key] ?? 0) + 1;
    await load();
    _downloads.remove(key);
    try {
      _writes = _writes.catchError((_) {}).then((_) => _writeDownloads(jsonEncode(_downloads)));
      await _writes;
    } catch (_) {
      /* Deleting audio must not depend on a metadata write. */
    }
  }

  Future<void> fetch(String server, List<String> ids, {bool offline = false}) async {
    try {
      await _fetchMeasurements(server, ids, offline: offline);
    } catch (_) {
      /* Measurement availability must never stop playback. */
    }
  }

  Future<void> _fetchMeasurements(String server, List<String> ids, {required bool offline}) async {
    final generation = _generation;
    await load();
    if (offline || ids.isEmpty) return;
    if (!await _isConfigured() || generation != _generation) return;
    final now = DateTime.now();
    final existing = ids.map((id) => _pending[_key(server, id)]).nonNulls.toList();
    final wanted = ids
        .map((id) => id.replaceAll('-', ''))
        .toSet()
        .where((id) {
          final key = _key(server, id);
          final last = _attempted[key];
          return last == null || now.difference(last) > const Duration(minutes: 5);
        })
        .take(2000)
        .toList();
    if (wanted.isEmpty) {
      // A caller preparing the crossfade must await a request already in flight.
      await Future.wait(existing);
      return;
    }
    final task = () async {
      try {
        final result = await _fetch(wanted);
        if (generation != _generation) return;
        var downloadsChanged = false;
        // Only replace this request's keys; a successful empty reply invalidates
        // old measurements for files the server removed or could no longer read.
        for (final id in wanted) {
          final key = _key(server, id);
          final json = result[id];
          if (json != null && LoudnessMeasurement.fromJson(json) != null) {
            _values[key] = json;
            // A download completed before analysis was ready. Fill its pending
            // measurement once; later server revisions cannot replace that copy.
            if (_downloads[key]?.isEmpty ?? false) {
              _downloads[key] = Map<String, dynamic>.from(json);
              downloadsChanged = true;
            }
          } else {
            _values.remove(key);
          }
        }
        _writes = _writes.catchError((_) {}).then((_) => _write(jsonEncode(_values)));
        if (downloadsChanged) _writes = _writes.then((_) => _writeDownloads(jsonEncode(_downloads)));
        await _writes;
        changes.add(null);
      } catch (_) {
        /* Keep cached measurements when the server is unreachable. */
      }
    }();
    for (final id in wanted) {
      final key = _key(server, id);
      _attempted[key] = now;
      _pending[key] = task;
    }
    try {
      await Future.wait([...existing, task]);
    } finally {
      for (final id in wanted) {
        final key = _key(server, id);
        if (identical(_pending[key], task)) unawaited(_pending.remove(key));
      }
    }
  }
}
