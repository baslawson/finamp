import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:finamp/services/karaoke_service.dart';
import 'package:finamp/services/server_hub_service.dart';
import 'package:flutter/foundation.dart';
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

/// Whoever asked for a file has gone (the sheet closed), so its wait or download stopped.
class KaraokeExportCancelled implements Exception {
  const KaraokeExportCancelled();
}

/// A link's stop that got no clear answer: it may or may not have stopped.
class KaraokeStopUnanswered implements Exception {
  const KaraokeStopUnanswered();
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

  /// Changes whenever a link is made or stopped here, so a list of them shown elsewhere can load them again.
  static final linksChanged = ValueNotifier<int>(0);

  /// The links stopped here, so a view still showing one (where it was made, say) can take it away.
  static final stopped = <String>{};

  /// What the hub says when asked to stop a link that already ended.
  @visibleForTesting
  static const linkEnded = 'This link already ended';

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
  /// [cancelled] says when whoever asked has gone (the sheet closed): the wait ends then, the server's conversion
  /// carrying on for next time.
  Future<KaraokeExportFile> prepare(
    String song,
    KaraokePart part,
    int guide,
    KaraokeFileFormat format, {
    bool Function()? cancelled,
  }) async {
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
      if (cancelled?.call() ?? false) throw const KaraokeExportCancelled();
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
  /// [cancelled] says when whoever asked has gone (the sheet closed): the download stops then, its connection
  /// closed and nothing left behind.
  Future<File> download(
    KaraokeExportFile file, {
    void Function(double fraction)? progress,
    bool Function()? cancelled,
  }) async {
    final hub = await _hub();
    final folder = await _directory();
    // Each download gets a folder of its own, keeping the file's name: the same mix downloaded twice at once (the
    // sheet closed and opened again), or two songs with the same artist and title, must not write over a file another
    // app may still be reading.
    final own = Directory('${folder.path}/${DateTime.now().microsecondsSinceEpoch}-${_random.nextInt(1 << 32)}');
    await own.create(recursive: true);
    try {
      return await _downloadInto(hub, own, file, progress, cancelled ?? () => false);
    } catch (_) {
      await own.delete(recursive: true).catchError((Object _) => own);
      rethrow;
    }
  }

  Future<File> _downloadInto(
    ServerHubService hub,
    Directory own,
    KaraokeExportFile file,
    void Function(double fraction)? progress,
    bool Function() cancelled,
  ) async {
    if (cancelled()) throw const KaraokeExportCancelled();
    final target = File('${own.path}/${file.name}');
    final partial = File('${own.path}/.partial');
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
          // Stopping here ends the stream with an error, which closes the connection.
          if (cancelled()) throw const KaraokeExportCancelled();
          received += chunk.length;
          if (total > 0) progress?.call(received / total);
          return chunk;
        }),
      );
      await sink.close();
    } catch (error) {
      await sink.close().catchError((Object _) {});
      if (await partial.exists()) await partial.delete();
      if (error is KaraokeExportCancelled) rethrow;
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
    linksChanged.value++;
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
    // Not sent at all (no server hub, or another account now): a ServerHubException, as the link still works.
    final server = hub ?? await _hub();
    server.checkAccount();
    try {
      await server.request('DELETE', '/api/karaoke/links/$link', serverMessages: true);
    } on ServerHubException catch (error) {
      // Already stopped or expired (404): either way it's gone. Refused by the server, the link still works. A
      // proxy's error, or the account changing as the answer came, says neither: it may have stopped all the same.
      // Only the hub's own 404 says it's gone: a proxy's (while the hub restarts, say) says nothing.
      final status = error.status;
      if (status != 404 || error.message != linkEnded) {
        if (status != null && status < 500 && status != 404) rethrow;
        throw const KaraokeStopUnanswered();
      }
    }
    stopped.add(link);
    linksChanged.value++;
  }

  /// Removes downloads left from earlier saves; the app they were shared with has long finished reading them.
  Future<void> clearOld({Duration age = const Duration(hours: 1)}) async {
    final folder = await _directory();
    if (!await folder.exists()) return;
    await for (final entry in folder.list()) {
      try {
        // Each download's own folder (and a loose file from an older version of the app). A folder's time doesn't
        // change as its file is written, so a download still coming in is told by its file's.
        var used = (await entry.stat()).modified;
        if (entry is Directory) {
          await for (final file in entry.list()) {
            final modified = (await file.stat()).modified;
            if (modified.isAfter(used)) used = modified;
          }
        }
        if (DateTime.now().difference(used) > age) await entry.delete(recursive: true);
      } catch (_) {}
    }
  }
}
