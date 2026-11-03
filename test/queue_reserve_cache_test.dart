import 'dart:io';
import 'dart:convert';

import 'package:finamp/services/queue_reserve_cache.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  late QueueReserveCache cache;
  late HttpServer remote;
  late Uri base;
  late HttpClient client;
  const key = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  setUp(() async {
    root = await Directory.systemTemp.createTemp('finamp-reserve-test-');
    cache = QueueReserveCache(root, maxFileBytes: 1024);
    remote = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = Uri.parse('http://127.0.0.1:${remote.port}');
    client = HttpClient();
    remote.listen((request) async {
      final response = request.response;
      switch (request.uri.path) {
        case '/audio':
          response.headers.contentType = ContentType('audio', 'ogg');
          response.add(List.generate(100, (i) => i));
        case '/big':
          response.headers.contentType = ContentType('audio', 'ogg');
          response.add(List.filled(2048, 1));
        case '/error':
          response.statusCode = 401;
          response.write('secret must not become audio');
        case '/html':
          response.headers.contentType = ContentType.html;
          response.write('<html>Login</html>');
        case '/main.m3u8':
          response.headers.contentType = ContentType('application', 'vnd.apple.mpegurl');
          response.write(
            '#EXTM3U\n#EXT-X-TARGETDURATION:5\n#EXT-X-MAP:URI="init?session=a"\n#EXTINF:5,\naudio?session=a\n#EXT-X-ENDLIST\n',
          );
        case '/master.m3u8':
          response.headers.contentType = ContentType('application', 'vnd.apple.mpegurl');
          response.write('#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\nmain.m3u8\n');
        case '/live.m3u8':
          response.headers.contentType = ContentType('application', 'vnd.apple.mpegurl');
          response.write('#EXTM3U\n#EXTINF:5,\naudio\n');
        case '/init':
          response.add([9, 8, 7]);
        default:
          response.statusCode = 404;
      }
      await response.close();
    });
  });
  tearDown(() async {
    client.close(force: true);
    await cache.close();
    await remote.close(force: true);
    await root.delete(recursive: true);
  });
  test('a complete file downloaded after queue creation is served locally with seek ranges', () async {
    final uri = await cache.source(key, base.resolve('/audio'));
    expect(await cache.download(key, base.resolve('/audio'), wanted: () => true), true);
    await remote.close(force: true);
    final request = await client.getUrl(uri);
    request.headers.set('Range', 'bytes=10-19');
    final response = await request.close();
    expect(response.statusCode, 206);
    expect(response.headers.value('Content-Range'), 'bytes 10-19/100');
    expect(await response.expand((chunk) => chunk).toList(), List.generate(10, (i) => i + 10));
  });
  test('main and crossfade copies pin the same rendition when a reserve finishes between requests', () async {
    final secondary = await cache.source(key, base.resolve('/audio?second=1'), playbackId: 'same-track');
    var request = await client.getUrl(secondary);
    request.followRedirects = false;
    var response = await request.close();
    expect(response.statusCode, 307);
    await response.drain<void>();
    expect(await cache.download(key, base.resolve('/audio'), wanted: () => true), true);
    final main = await cache.source(key, base.resolve('/audio?main=1'), playbackId: 'same-track');
    request = await client.getUrl(main);
    request.followRedirects = false;
    response = await request.close();
    expect(response.statusCode, 307);
    expect(response.headers.value('Location'), contains('main=1'));
    await response.drain<void>();
    final newPlay = await cache.source(key, base.resolve('/audio'), playbackId: 'later-listen');
    response = await (await client.getUrl(newPlay)).close();
    expect(response.statusCode, 200);
    await response.drain<void>();
  });
  test('HLS keeps its source type and is wholly local, including init segments and master playlists', () async {
    final uri = await cache.source(key, base.resolve('/main.m3u8'));
    expect(uri.path, endsWith('.m3u8'));
    expect(await cache.download(key, base.resolve('/master.m3u8'), wanted: () => true), true);
    await remote.close(force: true);
    final response = await (await client.getUrl(uri)).close();
    final manifest = await utf8.decoder.bind(response).join();
    expect(manifest, contains('#EXT-X-ENDLIST'));
    expect(manifest, isNot(contains('session=')));
    for (final path in ['segment-0', 'segment-1']) {
      final segment = await (await client.getUrl(uri.resolve(path))).close();
      final bytes = await segment.expand((chunk) => chunk).toList();
      expect(bytes, path == 'segment-0' ? [9, 8, 7] : List.generate(100, (i) => i));
    }
  });
  test('live playlists, HTTP failures, HTML and oversized files never become playable', () async {
    for (final path in ['/live.m3u8', '/error', '/html', '/big']) {
      expect(await cache.download(key, base.resolve(path), wanted: () => true), false, reason: path);
      expect(await cache.contains(key), false);
      expect(await File('${cache.file(key).path}.part').exists(), false);
    }
  });
  test('cancellation removes partial audio and HLS assets', () async {
    for (final path in ['/audio', '/main.m3u8']) {
      expect(await cache.download(key, base.resolve(path), wanted: () => false), false);
      expect(await cache.contains(key), false);
    }
    expect(await root.list().where((e) => e.path.contains('segment-')).toList(), isEmpty);
  });
  test('cleanup removes only owned stale reserve files and preserves selected tracks', () async {
    await cache.download(key, base.resolve('/main.m3u8'), wanted: () => true);
    final unrelated = File('${root.path}/user-download.opus');
    await unrelated.writeAsString('keep');
    await cache.trim({key});
    expect(await cache.contains(key), true);
    await cache.trim({});
    expect(await cache.contains(key), false);
    expect(await unrelated.exists(), true);
    expect(await root.list().toList(), hasLength(1));
  });
  test('unknown URLs and malformed byte ranges do not expose files or remote URLs', () async {
    final uri = await cache.source(key, base.resolve('/audio'));
    await cache.download(key, base.resolve('/audio'), wanted: () => true);
    final denied = await (await client.getUrl(uri.replace(path: '/not-the-token/anything/audio'))).close();
    expect(denied.statusCode, 404);
    await denied.drain<void>();
    final request = await client.getUrl(uri);
    request.headers.set('Range', 'bytes=999-');
    final response = await request.close();
    expect(response.statusCode, 416);
    await response.drain<void>();
    expect(() => cache.file('../outside'), throwsArgumentError);
  });
  test('range parser handles suffix and open ranges and rejects invalid/multiple ranges', () {
    expect(QueueReserveCache.byteRange('bytes=-5', 100), (95, 100));
    expect(QueueReserveCache.byteRange('bytes=95-', 100), (95, 100));
    expect(QueueReserveCache.byteRange('bytes=90-999', 100), (90, 100));
    for (final range in ['bytes=-', 'bytes=-0', 'bytes=10-5', 'bytes=0-1,3-4', 'foo']) {
      expect(QueueReserveCache.byteRange(range, 100), isNull);
    }
  });
  test('turning reserve off keeps active HLS segments until the song finishes', () async {
    await cache.download(key, base.resolve('/main.m3u8'), wanted: () => true);
    final uri = await cache.source(key, base.resolve('/main.m3u8'), playbackId: 'playing');
    cache.activePlaybacks({'playing'});
    final manifest = await (await client.getUrl(uri)).close();
    await manifest.drain<void>();
    await cache.trim({});
    expect(await cache.contains(key), true);
    await remote.close(force: true);
    final segment = await (await client.getUrl(uri.resolve('segment-1'))).close();
    expect(await segment.expand((v) => v).toList(), hasLength(100));
    cache.activePlaybacks({});
    cache.retainPlaybacks({});
    await cache.trim({});
    expect(await cache.hasOwnedFiles, false);
  });
  test('a song started from the reserve after a cleanup took its view of the queue is kept by that cleanup', () async {
    await cache.download(key, base.resolve('/main.m3u8'), wanted: () => true);
    cache.activePlaybacks({}); // Taken while the queue was being replaced, so without the restored song.
    final uri = await cache.source(key, base.resolve('/main.m3u8'), playbackId: 'restored');
    await (await (await client.getUrl(uri)).close()).drain<void>();
    await cache.trim({});
    expect(await cache.contains(key), true);
    await remote.close(force: true);
    final segment = await (await client.getUrl(uri.resolve('segment-1'))).close();
    expect(await segment.expand((v) => v).toList(), hasLength(100));
    cache.activePlaybacks({}); // The next cleanup knows the song isn't playing any more.
    await cache.trim({});
    expect(await cache.hasOwnedFiles, false);
  });
  test('a missing piece of a saved playlist is not answered with the song\'s server address', () async {
    await cache.download(key, base.resolve('/main.m3u8'), wanted: () => true);
    final local = await cache.source(key, base.resolve('/main.m3u8'));
    await (await (await client.getUrl(local)).close()).drain<void>();
    await File('${cache.file(key).path}.segment-1').delete();
    const other = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
    final uncached = await cache.source(other, base.resolve('/main.m3u8'));
    for (final uri in [local, uncached]) {
      final request = await client.getUrl(uri.resolve('segment-1'));
      request.followRedirects = false;
      final response = await request.close();
      expect(response.statusCode, 404, reason: '$uri');
      expect(response.headers.value('Location'), isNull);
      await response.drain<void>();
    }
  });
  test('a song being removed is never chosen as saved, and is never saved again meanwhile', () async {
    await cache.download(key, base.resolve('/main.m3u8'), wanted: () => true);
    final uri = await cache.source(key, base.resolve('/main.m3u8'), playbackId: 'restored');
    cache.onEvicting = (removed) async {
      expect(removed, key);
      expect(await cache.contains(key), false);
      expect(await cache.download(key, base.resolve('/main.m3u8'), wanted: () => true), false);
      // The playlist is still there, but the player is sent to the server's copy.
      final request = await client.getUrl(uri);
      request.followRedirects = false;
      final response = await request.close();
      expect(response.statusCode, 307);
      await response.drain<void>();
    };
    await cache.trim({});
    expect(await cache.hasOwnedFiles, false);
    // Chosen as the server's copy, the song stays there although it is saved again.
    cache.onEvicting = null;
    expect(await cache.download(key, base.resolve('/main.m3u8'), wanted: () => true), true);
    final request = await client.getUrl(uri);
    request.followRedirects = false;
    final response = await request.close();
    expect(response.statusCode, 307);
    await response.drain<void>();
  });
  test('a removal cut short leaves loose pieces, never a song that looks complete', () async {
    await cache.download(key, base.resolve('/main.m3u8'), wanted: () => true);
    cache.onEvicting = (_) async {
      // A piece that can't be removed, in place of a file still open elsewhere.
      await File('${cache.file(key).path}.segment-1').delete();
      await Directory('${cache.file(key).path}.segment-1').create();
    };
    await expectLater(cache.trim({}), throwsA(isA<FileSystemException>()));
    expect(await cache.contains(key), false);
  });
  test('the total music budget includes older active songs and partial HLS assets', () async {
    final bounded = QueueReserveCache(root, maxTotalBytes: 150);
    expect(await bounded.download(key, base.resolve('/audio'), wanted: () => true), true);
    const other = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
    expect(await bounded.download(other, base.resolve('/audio'), wanted: () => true), false);
    expect(await bounded.contains(other), false);
    expect(await bounded.contains(key), true);
  });
  test('a voice-copy lease prevents cleanup from deleting the source during a copy', () async {
    final voice = File('${root.path}/$key.voice.wav');
    await voice.writeAsString('voice');
    await cache.withRead(key, () async {
      await cache.trim({});
      expect(await voice.exists(), true);
    });
    await cache.trim({});
    expect(await voice.exists(), false);
  });
}
