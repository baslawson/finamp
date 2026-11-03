import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/analyzer_service.dart';
import 'package:finamp/services/loudness_normalization.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

enum KaraokeState { missing, queued, processing, ready, failed }

/// The part of the song the server takes out: vocals to sing along, drums to drum along, or both to drum along to
/// the band alone. The guide brought back is drums for both.
enum KaraokePart {
  vocals,
  drums,
  both;

  /// Each part's downloads keep their own details beside the song's shared lyrics.
  String get manifest => this == vocals ? 'manifest.json' : 'manifest-$name.json';
}

typedef SavedKaraoke = ({BaseItemDto item, KaraokeJob job, List<int> guides});
typedef KaraokeCatalogue = ({List<({String id, KaraokeJob job})> items, int total});

class KaraokeDashboardUnavailable extends AnalyzerException {
  KaraokeDashboardUnavailable() : super('Update the karaoke server to show its jobs');
}

class KaraokeJob {
  KaraokeJob.fromJson(this.json)
    : state = KaraokeState.values.firstWhere((s) => s.name == json['state'], orElse: () => KaraokeState.missing);

  final Map<String, dynamic> json;
  final KaraokeState state;

  /// Servers from before drum removal only make vocal karaoke and don't say so.
  KaraokePart get part =>
      KaraokePart.values.firstWhere((p) => p.name == json['part'], orElse: () => KaraokePart.vocals);
  String get revision => json['revision'] as String? ?? '';
  String? get message => json['message'] as String?;
  bool get waiting => state == KaraokeState.queued || state == KaraokeState.processing;
  bool get ready => state == KaraokeState.ready && RegExp(r'^[a-f0-9]{64}$').hasMatch(revision);
  Map<String, dynamic> mix(int guide) => Map<String, dynamic>.from((json['mixes'] as Map?)?['$guide'] as Map? ?? {});
  LoudnessMeasurement? measurement(int guide) => LoudnessMeasurement.fromJson(mix(guide));
}

/// Downloads authenticated, lossless server mixes. Tokens never appear in audio URLs or saved manifests.
class KaraokeService {
  KaraokeService({
    http.Client? client,
    Future<Directory> Function()? directory,
    Future<({String? url, String? token})> Function()? settings,
  }) : _client = client ?? http.Client(),
       _directory = directory ?? (() async => Directory('${(await getApplicationSupportDirectory()).path}/karaoke')),
       _cacheDirectory = directory ?? (() async => Directory('${(await getTemporaryDirectory()).path}/karaoke')),
       _settings = settings ?? AnalyzerService.getSettings;

  static final instance = KaraokeService();
  static const guideLevels = [0, 25, 50, 75, 100];

  /// Mashups (1.6.81 and 1.6.82) were removed; this frees the space their saved and cached copies took.
  static Future<void> removeRetiredMashups({List<Directory>? roots}) async {
    for (final root in roots ?? [await getApplicationSupportDirectory(), await getTemporaryDirectory()]) {
      final folder = Directory('${root.path}/mashups');
      if (await folder.exists()) await folder.delete(recursive: true);
    }
  }

  final http.Client _client;
  final Future<Directory> Function() _directory;
  final Future<Directory> Function() _cacheDirectory;
  final Future<({String? url, String? token})> Function() _settings;
  final Map<String, Future<File>> _downloads = {};
  final Map<String, int> _localWrites = {};
  final Set<String> _deleting = {};

  String _localKey(String id, String? url) => '$url:${songId(id)}';

  Future<T> _writeLocal<T>(String id, String? url, Future<T> Function() write) async {
    final key = _localKey(id, url);
    if (_deleting.contains(key)) throw AnalyzerException('This karaoke download is being deleted; try again');
    _localWrites[key] = (_localWrites[key] ?? 0) + 1;
    try {
      return await write();
    } finally {
      final remaining = _localWrites[key]! - 1;
      if (remaining == 0) {
        _localWrites.remove(key);
      } else {
        _localWrites[key] = remaining;
      }
    }
  }

  /// Removes only this song's karaoke audio and metadata on this device.
  Future<void> deleteLocal(String id) async {
    final connection = await _settings();
    final key = _localKey(id, connection.url);
    if (_deleting.contains(key) || (_localWrites[key] ?? 0) > 0) {
      throw AnalyzerException('Wait for this karaoke download to finish before deleting it');
    }
    _deleting.add(key);
    try {
      for (final offline in [true, false]) {
        final folder = await _folder(id, offline: offline, serverUrl: connection.url);
        if (await folder.exists()) await folder.delete(recursive: true);
      }
    } finally {
      _deleting.remove(key);
    }
  }

  /// Server deletion leaves this device's downloaded copies intact.
  Future<void> deleteServer(String id, KaraokeJob job) async {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(job.revision)) throw AnalyzerException('Invalid karaoke revision');
    final response = await _send('DELETE', id, revision: job.revision, part: job.part);
    await response.stream.drain<void>().timeout(const Duration(seconds: 20));
  }

  Future<KaraokeCatalogue> catalogue({int offset = 0, KaraokeState? state}) async {
    if (offset < 0) throw RangeError.value(offset);
    final settings = await _settings();
    if (settings.url == null) throw AnalyzerException('Set up the Finamp+ analyzer in Settings first');
    final uri = Uri.parse('${settings.url!.replaceAll(RegExp(r'/+$'), '')}/karaoke').replace(
      queryParameters: {'offset': '$offset', 'limit': '50', 'part': 'all', if (state != null) 'state': state.name},
    );
    final request = http.Request('GET', uri)..followRedirects = false;
    request.headers['X-Api-Key'] = settings.token ?? '';
    final response = await _client.send(request).timeout(const Duration(seconds: 20));
    final text = await response.stream.bytesToString().timeout(const Duration(seconds: 20));
    if (response.statusCode == 404) throw KaraokeDashboardUnavailable();
    if (response.statusCode != 200) throw AnalyzerException('Karaoke dashboard returned ${response.statusCode}');
    final json = jsonDecode(text) as Map<String, dynamic>;
    final items = <({String id, KaraokeJob job})>[];
    for (final raw in json['items'] as List) {
      final entry = Map<String, dynamic>.from(raw as Map);
      items.add((id: songId(entry['id'] as String), job: KaraokeJob.fromJson(entry)));
    }
    return (items: items, total: (json['total'] as num).toInt());
  }

  /// A mix's file name. Revisions differ between parts, so it names the part and guide level too.
  static String mixName(KaraokeJob job, int guide) => '${job.revision}-$guide.flac';

  static String songId(String id) {
    final result = id.replaceAll('-', '').toLowerCase();
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(result)) throw AnalyzerException('Invalid song ID');
    return result;
  }

  Future<Directory> _folder(String id, {bool offline = false, String? serverUrl}) async {
    final url = serverUrl ?? (await _settings()).url;
    if (url == null) throw AnalyzerException('Set up the Finamp+ analyzer in Settings first');
    final namespace = sha256.convert(utf8.encode(url)).toString();
    final root = await (offline ? _directory : _cacheDirectory)();
    return Directory('${root.path}/${offline ? 'offline' : 'cache'}/$namespace/${songId(id)}');
  }

  Future<http.StreamedResponse> _send(
    String method,
    String id, {
    KaraokeJob? job,
    int guide = 0,
    String? revision,
    KaraokePart part = KaraokePart.vocals,
    ({String? url, String? token})? connection,
  }) async {
    final settings = connection ?? await _settings();
    if (settings.url == null) throw AnalyzerException('Set up the Finamp+ analyzer in Settings first');
    final base = settings.url!.replaceAll(RegExp(r'/+$'), '');
    final asked = job?.part ?? part;
    final query = {
      if (job != null) ...{'guide': '$guide', 'revision': job.revision} else 'revision': ?revision,
      // Vocal requests stay as they were, so servers from before drum removal still understand them.
      if (asked != KaraokePart.vocals) 'part': asked.name,
    };
    final uri = Uri.parse(
      '$base/karaoke/${songId(id)}${job == null ? '' : '/audio'}',
    ).replace(queryParameters: query.isEmpty ? null : query);
    final request = http.Request(method, uri)..followRedirects = false;
    request.headers['X-Api-Key'] = settings.token ?? '';
    final response = await _client.send(request).timeout(const Duration(seconds: 20));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final error = await response.stream.bytesToString().timeout(const Duration(seconds: 20));
      String message;
      try {
        message = (jsonDecode(error) as Map)['detail'].toString();
      } catch (_) {
        message = 'Server karaoke returned ${response.statusCode}';
      }
      throw AnalyzerException(message);
    }
    return response;
  }

  Future<KaraokeJob> status(String id, {bool offline = false, KaraokePart part = KaraokePart.vocals}) async {
    if (offline) return (await _savedJob(id, part)) ?? KaraokeJob.fromJson({'state': 'missing', 'part': part.name});
    return _job(await _send('GET', id, part: part), part);
  }

  Future<KaraokeJob> prepare(String id, {KaraokePart part = KaraokePart.vocals}) async {
    // An older server would queue vocal karaoke for a drum request, so ask it first without changing anything.
    if (part != KaraokePart.vocals) await status(id, part: part);
    return _job(await _send('POST', id, part: part), part);
  }

  Future<KaraokeJob> _job(http.StreamedResponse response, KaraokePart part) async {
    final job = KaraokeJob.fromJson(
      jsonDecode(await response.stream.bytesToString().timeout(const Duration(seconds: 20))) as Map<String, dynamic>,
    );
    // An older server ignores the part it doesn't know and answers with vocal karaoke.
    if (job.part != part) throw AnalyzerException('Update the karaoke server to remove drums');
    return job;
  }

  Future<KaraokeJob?> _savedJob(String id, KaraokePart part) async {
    for (final offline in [true, false]) {
      final folder = await _folder(id, offline: offline);
      final manifest = File('${folder.path}/${part.manifest}');
      if (!await manifest.exists()) continue;
      try {
        final job = KaraokeJob.fromJson(jsonDecode(await manifest.readAsString()) as Map<String, dynamic>);
        if (job.part == part && job.ready && (await availableGuides(id, job, onlyOffline: offline)).isNotEmpty) {
          return job;
        }
      } catch (_) {
        /* A partial old manifest is safe to replace. */
      }
    }
    return null;
  }

  Future<List<int>> availableGuides(String id, KaraokeJob job, {bool onlyOffline = false}) async {
    final guides = <int>[];
    for (final guide in guideLevels) {
      if (await localMix(id, job, guide, onlyOffline: onlyOffline) != null) guides.add(guide);
    }
    return guides;
  }

  Future<File?> localMix(String id, KaraokeJob job, int guide, {bool onlyOffline = false, String? serverUrl}) async {
    if (!job.ready || !guideLevels.contains(guide)) return null;
    final expected = (job.mix(guide)['bytes'] as num?)?.toInt();
    if (expected == null || expected <= 0) return null;
    for (final offline in onlyOffline ? [true] : [true, false]) {
      final file = File('${(await _folder(id, offline: offline, serverUrl: serverUrl)).path}/${mixName(job, guide)}');
      if (await file.exists() && await file.length() == expected) return file;
    }
    return null;
  }

  Future<File> download(String id, KaraokeJob job, int guide, {bool keepOffline = false, bool offline = false}) async {
    final connection = await _settings();
    final key = '${connection.url}:${songId(id)}:${job.revision}:$guide:$keepOffline:$offline';
    return _downloads.putIfAbsent(
      key,
      () =>
          _writeLocal(
            id,
            connection.url,
            () => _download(id, job, guide, keepOffline: keepOffline, offline: offline, connection: connection),
          ).whenComplete(() {
            _downloads.remove(key);
          }),
    );
  }

  Future<File> _download(
    String id,
    KaraokeJob job,
    int guide, {
    required bool keepOffline,
    required bool offline,
    required ({String? url, String? token}) connection,
  }) async {
    if (!job.ready || !guideLevels.contains(guide)) throw AnalyzerException('Prepare this karaoke song first');
    final existing = await localMix(id, job, guide, onlyOffline: keepOffline, serverUrl: connection.url);
    if (existing != null) return existing;
    final cached = await localMix(id, job, guide, serverUrl: connection.url);
    if (offline && cached == null) throw AnalyzerException('This guide mix has not been downloaded');
    final expected = (job.mix(guide)['bytes'] as num?)?.toInt();
    if (expected == null || expected <= 0 || expected > 512 * 1024 * 1024) {
      throw AnalyzerException('The server returned an invalid karaoke file');
    }
    final folder = await _folder(id, offline: keepOffline, serverUrl: connection.url);
    await folder.create(recursive: true);
    final file = File('${folder.path}/${mixName(job, guide)}');
    final partial = File('${file.path}.part');
    try {
      if (cached != null) {
        await cached.copy(partial.path);
      } else {
        final response = await _send('GET', id, job: job, guide: guide, connection: connection);
        final output = partial.openWrite();
        try {
          var received = 0;
          await for (final chunk in response.stream.timeout(const Duration(seconds: 30))) {
            received += chunk.length;
            if (received > expected) throw AnalyzerException('The server returned an oversized karaoke file');
            output.add(chunk);
            await output.flush();
          }
        } finally {
          await output.close();
        }
      }
      if (await partial.length() != expected) {
        throw AnalyzerException('The karaoke download was interrupted; try again');
      }
      await partial.rename(file.path);
      final manifest = File('${folder.path}/${job.part.manifest}');
      await manifest.writeAsString(jsonEncode(job.json), flush: true);
      return file;
    } catch (_) {
      if (await partial.exists()) await partial.delete();
      rethrow;
    }
  }

  Future<void> saveLyrics(String id, LyricDto lyrics) async {
    final connection = await _settings();
    await _writeLocal(id, connection.url, () async {
      final folder = await _folder(id, serverUrl: connection.url);
      await folder.create(recursive: true);
      await File('${folder.path}/lyrics.json').writeAsString(jsonEncode(lyrics.toJson()), flush: true);
    });
  }

  Future<LyricDto?> savedLyrics(String id) async {
    try {
      for (final offline in [true, false]) {
        final file = File('${(await _folder(id, offline: offline)).path}/lyrics.json');
        if (await file.exists()) {
          return LyricDto.fromJson(jsonDecode(await file.readAsString()) as Map<String, dynamic>);
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<void> saveOfflineDetails(BaseItemDto item, LyricDto? lyrics) async {
    final connection = await _settings();
    await _writeLocal(item.id.raw, connection.url, () async {
      final folder = await _folder(item.id.raw, offline: true, serverUrl: connection.url);
      await folder.create(recursive: true);
      await File('${folder.path}/track.json').writeAsString(jsonEncode(item.toJson(setOffline: false)), flush: true);
      if (lyrics != null) {
        await File('${folder.path}/lyrics.json').writeAsString(jsonEncode(lyrics.toJson()), flush: true);
      }
    });
  }

  /// Own offline catalogue: the original song need not also be downloaded.
  Future<List<SavedKaraoke>> savedSongs() async {
    final parent = (await _folder('0' * 32, offline: true)).parent;
    if (!await parent.exists()) return [];
    final result = <SavedKaraoke>[];
    await for (final entry in parent.list(followLinks: false)) {
      if (entry is! Directory) continue;
      try {
        final item = BaseItemDto.fromJson(
          jsonDecode(await File('${entry.path}/track.json').readAsString()) as Map<String, dynamic>,
        );
        for (final part in KaraokePart.values) {
          try {
            final job = KaraokeJob.fromJson(
              jsonDecode(await File('${entry.path}/${part.manifest}').readAsString()) as Map<String, dynamic>,
            );
            if (job.part != part) continue;
            final guides = await availableGuides(item.id.raw, job, onlyOffline: true);
            if (guides.isNotEmpty) result.add((item: item, job: job, guides: guides));
          } catch (_) {
            /* A song can be saved with only one of its parts. */
          }
        }
      } catch (_) {
        /* Incomplete downloads are not playable catalogue entries. */
      }
    }
    result.sort((a, b) {
      final byName = (a.item.name ?? '').compareTo(b.item.name ?? '');
      return byName != 0 ? byName : a.job.part.index.compareTo(b.job.part.index);
    });
    return result;
  }
}
