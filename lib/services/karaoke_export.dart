import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:finamp/services/karaoke_service.dart';
import 'package:finamp/services/server_hub_service.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// The formats the server converts karaoke mixes to.
enum KaraokeFileFormat {
  flac('audio/flac'),
  wav('audio/wav'),
  mp3('audio/mpeg');

  const KaraokeFileFormat(this.mimeType);
  final String mimeType;
}

/// How long a shared download link works, in hours as the server takes them.
enum KaraokeLinkLength {
  hour(1),
  day(24),
  week(168);

  const KaraokeLinkLength(this.hours);
  final int hours;
}

/// A mix converted on the server, ready to download with [ticket] for a few minutes.
typedef KaraokeExportFile = ({String name, String ticket, int bytes});

class KaraokeLink {
  KaraokeLink.fromJson(Map<String, dynamic> json)
    : id = json['id'] as String,
      name = json['name'] as String,
      format = KaraokeFileFormat.values.firstWhere(
        (format) => format.name == json['format'],
        orElse: () => KaraokeFileFormat.mp3,
      ),
      url = json['url'] as String,
      downloads = (json['downloads'] as num?)?.toInt() ?? 0,
      expires = DateTime.fromMillisecondsSinceEpoch(((json['expires'] as num) * 1000).round());

  final String id, name, url;
  final KaraokeFileFormat format;
  final int downloads;
  final DateTime expires;
}

/// Karaoke mixes as files: converted on the server, then saved on this device or shared as a link that expires.
class KaraokeExport {
  KaraokeExport({
    Future<ServerHubService?> Function()? connect,
    Future<Directory> Function()? directory,
    this.poll = const Duration(seconds: 2),
    this.patience = const Duration(minutes: 5),
    this.stall = const Duration(seconds: 30),
  }) : _connect = connect ?? ServerHubService.connect,
       _directory = directory ?? (() async => Directory('${(await getTemporaryDirectory()).path}/karaoke-exports'));

  final Future<ServerHubService?> Function() _connect;
  final Future<Directory> Function() _directory;

  /// How often a conversion under way is looked at, and how long it's waited for.
  final Duration poll, patience;

  /// How long a download may wait for the server to start, or to send more, before it's dropped.
  final Duration stall;

  static final _random = Random();

  Future<ServerHubService> _hub() async {
    final hub = await _connect();
    if (hub == null) throw const ServerHubException('Set up your Finamp+ analyzer in Settings first.');
    return hub;
  }

  static Map<String, Object> _choice(String song, KaraokePart part, int guide, KaraokeFileFormat format) => {
    'song': song.replaceAll('-', ''),
    'part': part.name,
    'guide': guide,
    'format': format.name,
  };

  static KaraokeExportFile _file(Map<String, dynamic> answer) =>
      (name: answer['name'] as String, ticket: answer['ticket'] as String, bytes: (answer['bytes'] as num).toInt());

  /// Has the server convert [song]'s mix (its [part] at [guide]) to [format], waiting while it does.
  Future<KaraokeExportFile> prepare(String song, KaraokePart part, int guide, KaraokeFileFormat format) async {
    final hub = await _hub();
    final choice = _choice(song, part, guide, format);
    var answer = Map<String, dynamic>.from(
      await hub.request('POST', '/api/karaoke/exports', body: choice, serverMessages: true) as Map,
    );
    final query = Uri(queryParameters: {for (final entry in choice.entries) entry.key: '${entry.value}'}).query;
    final waited = Stopwatch()..start();
    var asked = false;
    while (answer['state'] != 'ready') {
      switch (answer['state']) {
        case 'failed':
          throw ServerHubException(answer['message'] as String? ?? 'The server could not convert this mix.');
        // The job is gone without a file (the server restarted, say): asked for once more.
        case 'missing' when !asked:
          asked = true;
          answer = Map<String, dynamic>.from(
            await hub.request('POST', '/api/karaoke/exports', body: choice, serverMessages: true) as Map,
          );
          continue;
        case 'missing':
          throw const ServerHubException('The server could not convert this mix. Try again.');
      }
      if (waited.elapsed + poll > patience) {
        throw const ServerHubException('The server is still converting this mix. Try again in a minute.');
      }
      await Future<void>.delayed(poll);
      answer = Map<String, dynamic>.from(
        await hub.request('GET', '/api/karaoke/exports?$query', serverMessages: true) as Map,
      );
    }
    return _file(answer);
  }

  /// Downloads a converted [file] into this app's temporary folder, telling [progress] how far it got.
  Future<File> download(KaraokeExportFile file, {void Function(double fraction)? progress}) async {
    final hub = await _hub();
    final folder = await _directory();
    await folder.create(recursive: true);
    final target = File('${folder.path}/${file.name}');
    // Each download writes its own file: the same mix downloaded twice at once (the sheet closed and opened again,
    // say) must not write over itself.
    final partial = File(
      '${folder.path}/.${DateTime.now().microsecondsSinceEpoch}-${_random.nextInt(1 << 32)}.partial',
    );
    final http.StreamedResponse response;
    try {
      response = await hub.download('/api/karaoke/exports/file/${file.ticket}', timeout: stall);
    } on TimeoutException {
      throw const ServerHubException('The server did not start the download. Try again.');
    }
    if (response.statusCode != 200) {
      await response.stream.drain<void>();
      throw ServerHubException(switch (response.statusCode) {
        401 => 'The download expired. Try again.',
        404 => 'The server no longer has this file. Try again.',
        _ => 'The download failed. Try again.',
      }, response.statusCode);
    }
    // The size the server gave when the conversion finished: a connection cut short (or a proxy's own length) can't
    // pass for the whole file.
    final total = file.bytes > 0 ? file.bytes : response.contentLength ?? 0;
    var received = 0;
    final sink = partial.openWrite();
    try {
      // Written as fast as storage takes it, the connection waiting meanwhile, so a fast download doesn't pile up in
      // memory. One that stops sending for [stall] has dropped (the wait for storage doesn't count).
      await sink.addStream(
        response.stream.timeout(stall).map((chunk) {
          received += chunk.length;
          if (total > 0) progress?.call(received / total);
          return chunk;
        }),
      );
      await sink.close();
    } catch (_) {
      await sink.close().catchError((Object _) {});
      if (await partial.exists()) await partial.delete();
      throw const ServerHubException('The download was interrupted. Try again.');
    }
    if (total > 0 && received != total) {
      await partial.delete();
      throw const ServerHubException('The download was incomplete. Try again.');
    }
    return partial.rename(target.path);
  }

  /// A link anyone can download the converted mix from for [length]. The mix must have been [prepare]d.
  Future<({KaraokeLink link, bool public})> share(
    String song,
    KaraokePart part,
    int guide,
    KaraokeFileFormat format,
    KaraokeLinkLength length,
  ) async {
    final hub = await _hub();
    final answer = Map<String, dynamic>.from(
      await hub.request(
            'POST',
            '/api/karaoke/links',
            body: {..._choice(song, part, guide, format), 'hours': length.hours},
            serverMessages: true,
          )
          as Map,
    );
    return (link: KaraokeLink.fromJson(answer), public: answer['public'] == true);
  }

  /// This account's links that still work, and whether they work away from home.
  Future<({List<KaraokeLink> links, bool public})> links({ServerHubService? hub}) async {
    final answer = Map<String, dynamic>.from(
      await (hub ?? await _hub()).request('GET', '/api/karaoke/links', serverMessages: true) as Map,
    );
    return (
      links: [for (final link in answer['links'] as List) KaraokeLink.fromJson(Map<String, dynamic>.from(link as Map))],
      public: answer['public'] == true,
    );
  }

  Future<void> stop(String link, {ServerHubService? hub}) async {
    try {
      await (hub ?? await _hub()).request('DELETE', '/api/karaoke/links/$link', serverMessages: true);
    } on ServerHubException catch (error) {
      // Already stopped or expired: either way it's gone.
      if (error.status != 404) rethrow;
    }
  }

  /// Removes downloads left from earlier saves; the app they were shared with has long finished reading them.
  Future<void> clearOld({Duration age = const Duration(hours: 1)}) async {
    final folder = await _directory();
    if (!await folder.exists()) return;
    await for (final entry in folder.list()) {
      if (entry is File && DateTime.now().difference(await entry.lastModified()) > age) {
        await entry.delete().catchError((Object _) => entry);
      }
    }
  }
}
