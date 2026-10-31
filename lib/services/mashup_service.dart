import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/analyzer_service.dart';
import 'package:finamp/services/karaoke_service.dart';
import 'package:finamp/services/loudness_normalization.dart';
import 'package:finamp/services/lyrics_timeline.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// How the server fits one song's vocals to another's instrumental.
class MashupPlan {
  MashupPlan.fromJson(Map<String, dynamic> json)
    : semitones = (json['semitones'] as num?)?.toInt() ?? 0,
      tempo = (json['tempo'] as num?)?.toDouble() ?? 1,
      key = json['key'] as String? ?? 'same',
      score = (json['score'] as num?)?.toDouble() ?? 0,
      warnings = [for (final warning in json['warnings'] as List? ?? const []) '$warning'];

  /// Semitones the singer is moved, up when positive.
  final int semitones;

  /// How much faster the vocals play: 1.04 is 4% faster.
  final double tempo;

  /// How the keys meet after the shift: same, relative or neighbour.
  final String key;
  final double score;
  final List<String> warnings;

  /// Percent faster (positive) or slower (negative), rounded.
  int get tempoPercent => ((tempo - 1) * 100).round();
}

/// A song that mashes up well with another, as the server suggests it.
/// A pair worth trying: [vocals] sings over [backing]'s band.
class MashupIdea {
  MashupIdea.fromJson(Map<String, dynamic> json)
    : vocals = KaraokeService.songId(json['vocals'] as String),
      backing = KaraokeService.songId(json['backing'] as String),
      plan = MashupPlan.fromJson(json);

  final String vocals, backing;
  final MashupPlan plan;
}

class MashupPartner {
  MashupPartner.fromJson(Map<String, dynamic> json)
    : id = KaraokeService.songId(json['id'] as String),
      plan = MashupPlan.fromJson(json);

  final String id;
  final MashupPlan plan;
}

/// One mashup on the server: [vocals] sung over the instrumental of [backing].
class MashupJob {
  MashupJob.fromJson(this.json)
    : state = KaraokeState.values.firstWhere((s) => s.name == json['state'], orElse: () => KaraokeState.missing);

  final Map<String, dynamic> json;
  final KaraokeState state;

  String get revision => json['revision'] as String? ?? '';
  String? get message => json['message'] as String?;
  String? get vocals => json['vocals'] as String?;
  String? get backing => json['backing'] as String?;
  bool get waiting => state == KaraokeState.queued || state == KaraokeState.processing;
  bool get ready => state == KaraokeState.ready && RegExp(r'^[a-f0-9]{64}$').hasMatch(revision) && bytes != null;
  double get progress => (json['progress'] as num?)?.toDouble() ?? 0;
  MashupPlan? get plan =>
      json['plan'] is Map ? MashupPlan.fromJson(Map<String, dynamic>.from(json['plan'] as Map)) : null;
  Map<String, dynamic> get _mix => Map<String, dynamic>.from((json['mixes'] as Map?)?['mashup'] as Map? ?? {});
  int? get bytes {
    final value = (_mix['bytes'] as num?)?.toInt();
    return value != null && value > 0 && value <= 512 * 1024 * 1024 ? value : null;
  }

  LoudnessMeasurement? get measurement => LoudnessMeasurement.fromJson(_mix);

  /// Where the singer's lyrics land in the mashup; null when the server didn't say.
  LyricsTimeline? get lyricsTimeline {
    final offset = (json['placement'] as Map?)?['offset'];
    final tempo = plan?.tempo;
    return tempo == null ? null : LyricsTimeline.fromJson({'tempo': tempo, 'offset': offset});
  }
}

/// Makes, lists, downloads and deletes mashups on the Finamp+ server. Tokens never appear in URLs or on disk.
class MashupService {
  MashupService({
    http.Client? client,
    Future<Directory> Function()? directory,
    Future<({String? url, String? token})> Function()? settings,
  }) : _client = client ?? http.Client(),
       _directory = directory ?? (() async => Directory('${(await getTemporaryDirectory()).path}/mashups')),
       _offlineDirectory =
           directory ?? (() async => Directory('${(await getApplicationSupportDirectory()).path}/mashups')),
       _settings = settings ?? AnalyzerService.getSettings;

  static final instance = MashupService();
  static const _upgrade = 'Update the Finamp+ server to make mashups';
  final http.Client _client;
  final Future<Directory> Function() _directory;
  final Future<Directory> Function() _offlineDirectory;
  final Future<({String? url, String? token})> Function() _settings;
  final Map<String, Future<File>> _downloads = {};
  final Set<String> _deleting = {};

  Future<http.StreamedResponse> _send(String method, String path, {Map<String, String>? query}) async {
    final settings = await _settings();
    if (settings.url == null) throw AnalyzerException('Set up the Finamp+ analyzer in Settings first');
    final uri = Uri.parse(
      '${settings.url!.replaceAll(RegExp(r'/+$'), '')}$path',
    ).replace(queryParameters: query == null || query.isEmpty ? null : query);
    final request = http.Request(method, uri)..followRedirects = false;
    request.headers['X-Api-Key'] = settings.token ?? '';
    final response = await _client.send(request).timeout(const Duration(seconds: 30));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final error = await response.stream.bytesToString().timeout(const Duration(seconds: 20));
      String? detail;
      try {
        detail = (jsonDecode(error) as Map)['detail']?.toString();
      } catch (_) {
        /* Not the server's own error answer. */
      }
      // A server from before mashups doesn't know the routes, or the mashup list.
      if (detail == null ||
          detail == 'Not Found' ||
          detail == 'Method Not Allowed' ||
          detail.startsWith('Choose vocals')) {
        throw AnalyzerException(detail == null ? 'The server returned ${response.statusCode}' : _upgrade);
      }
      throw AnalyzerException(detail);
    }
    return response;
  }

  Future<dynamic> _json(String method, String path, {Map<String, String>? query}) async {
    final response = await _send(method, path, query: query);
    return jsonDecode(await response.stream.bytesToString().timeout(const Duration(seconds: 20)));
  }

  String _pair(String vocals, String backing) {
    final a = KaraokeService.songId(vocals), b = KaraokeService.songId(backing);
    if (a == b) throw AnalyzerException('Choose two different songs');
    return '/mashup/$a/$b';
  }

  /// Songs that go with [song], best first. With [sings] the song's vocals go over theirs; otherwise theirs go over
  /// its instrumental.
  Future<List<MashupPartner>> partners(String song, {bool sings = true}) async {
    final json = await _json(
      'GET',
      '/mashup-partners/${KaraokeService.songId(song)}',
      query: {'role': sings ? 'vocals' : 'backing', 'limit': '20'},
    );
    return [for (final entry in json as List) MashupPartner.fromJson(Map<String, dynamic>.from(entry as Map))];
  }

  /// How a pair picked by hand would be fitted. Throws with the reason when it can't be mashed up.
  /// Pairs worth trying, best first, each with one of [songs] (such as the ones played lately) in it.
  Future<List<MashupIdea>> ideas(List<String> songs) async {
    if (songs.isEmpty) return [];
    final json = await _json(
      'GET',
      '/mashup-ideas',
      query: {'songs': songs.map(KaraokeService.songId).join(','), 'limit': '20'},
    );
    return [for (final entry in json as List) MashupIdea.fromJson(Map<String, dynamic>.from(entry as Map))];
  }

  Future<MashupPlan> plan(String vocals, String backing) async =>
      MashupPlan.fromJson(Map<String, dynamic>.from(await _json('GET', '${_pair(vocals, backing)}/plan') as Map));

  Future<MashupJob> make(String vocals, String backing) async =>
      MashupJob.fromJson(Map<String, dynamic>.from(await _json('POST', _pair(vocals, backing)) as Map));

  Future<MashupJob> status(String vocals, String backing) async =>
      MashupJob.fromJson(Map<String, dynamic>.from(await _json('GET', _pair(vocals, backing)) as Map));

  /// The server's mashups, the ones being made first.
  Future<List<MashupJob>> list() async {
    final jobs = <MashupJob>[];
    // Page by page: the server answers at most 100 at a time.
    for (var offset = 0; ;) {
      final json =
          await _json('GET', '/karaoke', query: {'part': 'mashup', 'limit': '100', 'offset': '$offset'}) as Map;
      final items = json['items'] as List;
      jobs.addAll(items.map((entry) => MashupJob.fromJson(Map<String, dynamic>.from(entry as Map))));
      offset += items.length;
      if (items.isEmpty || offset >= (json['total'] as num).toInt()) break;
    }
    return jobs.where((job) => job.vocals != null && job.backing != null).toList();
  }

  /// Removes the mashup from the server; copies saved on the phone stay.
  Future<void> deleteServer(MashupJob job) async {
    final response = await _send(
      'DELETE',
      _pair(job.vocals!, job.backing!),
      query: {if (RegExp(r'^[a-f0-9]{64}$').hasMatch(job.revision)) 'revision': job.revision},
    );
    await response.stream.drain<void>().timeout(const Duration(seconds: 20));
  }

  /// Where this server's mashups live on the phone: saved ones in [offline], played ones in a cache the system may
  /// clear.
  Future<Directory> _folder(String? url, {required bool offline}) async {
    final namespace = sha256.convert(utf8.encode(url ?? '')).toString();
    final root = await (offline ? _offlineDirectory : _directory)();
    return Directory('${root.path}/${offline ? 'offline' : 'cache'}/$namespace');
  }

  static bool _revision(String value) => RegExp(r'^[a-f0-9]{64}$').hasMatch(value);

  Future<File?> _local(MashupJob job, String? url, {bool onlyOffline = false}) async {
    if (!job.ready) return null;
    for (final offline in onlyOffline ? [true] : [true, false]) {
      final file = File('${(await _folder(url, offline: offline)).path}/${job.revision}.flac');
      if (await file.exists() && await file.length() == job.bytes) return file;
    }
    return null;
  }

  /// Every copy of this mashup's audio on the phone, saved or cached, whether it exists or not.
  Future<List<String>> localPaths(MashupJob job) async {
    final url = (await _settings()).url;
    return [
      for (final offline in [true, false]) '${(await _folder(url, offline: offline)).path}/${job.revision}.flac',
    ];
  }

  /// Whether this version of the mashup is saved for offline playback.
  Future<bool> isSaved(MashupJob job) async => await _local(job, (await _settings()).url, onlyOffline: true) != null;

  /// The mashup's audio on this phone, downloaded once per version. With [keepOffline] it's saved with the two
  /// songs' details, so it plays without the server.
  Future<File> download(MashupJob job, {bool keepOffline = false, BaseItemDto? singer, BaseItemDto? band}) async {
    if (!job.ready) throw AnalyzerException('This mashup is not ready yet');
    if (keepOffline && (singer == null || band == null)) throw ArgumentError('Saving needs both songs');
    final connection = await _settings();
    final key = '${connection.url}:${job.revision}:$keepOffline';
    if (_deleting.contains(job.revision)) throw AnalyzerException('This mashup is being deleted; try again');
    return _downloads.putIfAbsent(
      key,
      () => _download(job, connection.url, keepOffline)
          .then((file) async {
            if (keepOffline) {
              final details = File('${file.parent.path}/${job.revision}.json');
              await details.writeAsString(
                jsonEncode({
                  'job': job.json,
                  'singer': singer!.toJson(setOffline: false),
                  'band': band!.toJson(setOffline: false),
                }),
                flush: true,
              );
            }
            return file;
          })
          // A block, not an arrow: remove() returns this very future, which whenComplete would then wait for.
          .whenComplete(() {
            _downloads.remove(key);
          }),
    );
  }

  Future<File> _download(MashupJob job, String? url, bool keepOffline) async {
    final existing = await _local(job, url, onlyOffline: keepOffline);
    if (existing != null) return existing;
    final cached = keepOffline ? await _local(job, url) : null;
    final folder = await _folder(url, offline: keepOffline);
    await folder.create(recursive: true);
    final file = File('${folder.path}/${job.revision}.flac');
    final partial = File('${file.path}.part');
    final expected = job.bytes!;
    try {
      if (cached != null) {
        await cached.copy(partial.path);
      } else {
        final response = await _send(
          'GET',
          '${_pair(job.vocals!, job.backing!)}/audio',
          query: {'revision': job.revision},
        );
        final output = partial.openWrite();
        try {
          var received = 0;
          await for (final chunk in response.stream.timeout(const Duration(seconds: 30))) {
            received += chunk.length;
            if (received > expected) throw AnalyzerException('The server returned an oversized mashup');
            output.add(chunk);
            await output.flush();
          }
        } finally {
          await output.close();
        }
      }
      if (await partial.length() != expected) throw AnalyzerException('The mashup download was interrupted; try again');
      await partial.rename(file.path);
      return file;
    } catch (_) {
      if (await partial.exists()) await partial.delete();
      rethrow;
    }
  }

  /// The mashups saved on this phone for the current server, which play without it.
  Future<List<SavedMashup>> saved() async {
    final folder = await _folder((await _settings()).url, offline: true);
    if (!await folder.exists()) return [];
    final result = <SavedMashup>[];
    await for (final entry in folder.list(followLinks: false)) {
      if (entry is! File || !entry.path.endsWith('.json')) continue;
      try {
        final json = jsonDecode(await entry.readAsString()) as Map<String, dynamic>;
        final job = MashupJob.fromJson(Map<String, dynamic>.from(json['job'] as Map));
        final file = File(entry.path.replaceFirst(RegExp(r'\.json$'), '.flac'));
        if (!job.ready || !await file.exists() || await file.length() != job.bytes) continue;
        result.add((
          job: job,
          singer: BaseItemDto.fromJson(Map<String, dynamic>.from(json['singer'] as Map)),
          band: BaseItemDto.fromJson(Map<String, dynamic>.from(json['band'] as Map)),
          file: file,
        ));
      } catch (_) {
        /* A half-written save isn't playable. */
      }
    }
    result.sort((a, b) => (a.singer.name ?? '').compareTo(b.singer.name ?? ''));
    return result;
  }

  /// Removes this mashup's audio and details from the phone; the server's copy stays.
  Future<void> deleteLocal(MashupJob job) async {
    if (!_revision(job.revision)) throw AnalyzerException('Invalid mashup revision');
    if (_downloads.keys.any((key) => key.contains(job.revision))) {
      throw AnalyzerException('Wait for this mashup download to finish before deleting it');
    }
    _deleting.add(job.revision);
    try {
      final url = (await _settings()).url;
      for (final offline in [true, false]) {
        final folder = await _folder(url, offline: offline);
        for (final name in ['${job.revision}.flac', '${job.revision}.json', '${job.revision}.flac.part']) {
          final file = File('${folder.path}/$name');
          if (await file.exists()) await file.delete();
        }
      }
    } finally {
      _deleting.remove(job.revision);
    }
  }
}

typedef SavedMashup = ({MashupJob job, BaseItemDto singer, BaseItemDto band, File file});
