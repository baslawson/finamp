import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:finamp/services/analyzer_service.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/karaoke_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as path;

void main() {
  const song = '0123456789abcdef0123456789abcdef';
  final revision = 'a' * 64;
  late Directory directory;
  late String server;
  var requests = 0;
  late KaraokeService service;
  Map<String, dynamic> ready() => {
    'state': 'ready',
    'revision': revision,
    'mixes': {
      for (final guide in KaraokeService.guideLevels) '$guide': {'bytes': 4, 'version': 1, 'lufs': -17, 'truePeak': -2},
    },
  };

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('finamp-karaoke-test-');
    server = 'http://analyzer.test';
    requests = 0;
    service = KaraokeService(
      directory: () async => directory,
      settings: () async => (url: server, token: 'test-token'),
      client: MockClient((request) async {
        requests++;
        expect(request.headers['X-Api-Key'], 'test-token');
        expect(request.url.toString(), isNot(contains('test-token')));
        if (request.url.path.endsWith('/audio')) return http.Response.bytes([1, 2, 3, 4], 200);
        return http.Response(jsonEncode(ready()), 200);
      }),
    );
  });
  tearDown(() async => directory.delete(recursive: true));

  test('server mixes use auth headers and retain their own loudness measurements', () async {
    final job = await service.status(song);
    expect(job.ready, isTrue);
    expect(job.measurement(25)?.lufs, -17);
    final file = await service.download(song, job, 25);
    expect(await file.readAsBytes(), [1, 2, 3, 4]);
    expect(requests, 2);
  });

  test('cached playback needs no network and explicit offline saving copies the cached mix', () async {
    final job = KaraokeJob.fromJson(ready());
    final cached = await service.download(song, job, 0);
    final saved = await service.download(song, job, 0, keepOffline: true, offline: true);
    expect(saved.path, isNot(cached.path));
    expect(requests, 1);
    final restored = await service.status(song, offline: true);
    expect(restored.revision, revision);
    expect(await service.availableGuides(song, restored, onlyOffline: true), [0]);
    expect(await File('${saved.parent.path}/manifest.json').readAsString(), isNot(contains('test-token')));
  });

  test('offline playback rejects a guide mix that has not been downloaded', () async {
    final job = KaraokeJob.fromJson(ready());
    await expectLater(service.download(song, job, 50, offline: true), throwsA(isA<AnalyzerException>()));
    expect(requests, 0);
  });

  test('cache is isolated between analyzer servers and source revisions', () async {
    final job = KaraokeJob.fromJson(ready());
    await service.download(song, job, 0, keepOffline: true);
    server = 'http://other-server.test';
    expect((await service.status(song, offline: true)).ready, isFalse);
    server = 'http://analyzer.test';
    expect(await service.localMix(song, KaraokeJob.fromJson({...ready(), 'revision': 'b' * 64}), 0), isNull);
  });

  test('short downloads are discarded and can be retried', () async {
    var short = true;
    final client = KaraokeService(
      directory: () async => directory,
      settings: () async => (url: server, token: 'test-token'),
      client: MockClient((_) async => http.Response.bytes(short ? [1, 2] : [1, 2, 3, 4], 200)),
    );
    final job = KaraokeJob.fromJson(ready());
    await expectLater(client.download(song, job, 0), throwsA(isA<AnalyzerException>()));
    expect(await client.localMix(song, job, 0), isNull);
    short = false;
    expect(await (await client.download(song, job, 0)).length(), 4);
  });

  test('concurrent requests download a mix once', () async {
    final job = KaraokeJob.fromJson(ready());
    final results = await Future.wait([service.download(song, job, 0), service.download(song, job, 0)]);
    expect(results[0].path, results[1].path);
    expect(requests, 1);
  });

  test('changing servers during a download keeps the file in its original server cache', () async {
    final started = Completer<void>(), response = Completer<http.Response>();
    final client = KaraokeService(
      directory: () async => directory,
      settings: () async => (url: server, token: 'test-token'),
      client: MockClient((request) {
        expect(request.url.host, 'analyzer.test');
        started.complete();
        return response.future;
      }),
    );
    final job = KaraokeJob.fromJson(ready());
    final download = client.download(song, job, 0);
    await started.future;
    server = 'http://other-server.test';
    response.complete(http.Response.bytes([1, 2, 3, 4], 200));
    final original = await download;
    expect(await client.localMix(song, job, 0), isNull);
    server = 'http://analyzer.test';
    expect((await client.localMix(song, job, 0))?.path, original.path);
  });

  test('oversized responses and redirects never become playable cached files', () async {
    for (final status in [200, 302]) {
      final client = KaraokeService(
        directory: () async => directory,
        settings: () async => (url: server, token: 'test-token'),
        client: MockClient((request) async {
          expect(request.followRedirects, isFalse);
          return http.Response.bytes([1, 2, 3, 4, 5], status);
        }),
      );
      final job = KaraokeJob.fromJson(ready());
      await expectLater(client.download(song, job, 0), throwsA(isA<AnalyzerException>()));
      expect(await client.localMix(song, job, 0), isNull);
    }
  });

  test('corrupt local files are not accepted as offline-ready', () async {
    final job = KaraokeJob.fromJson(ready());
    final file = await service.download(song, job, 0, keepOffline: true);
    await file.writeAsBytes([1]);
    expect((await service.status(song, offline: true)).ready, isFalse);
  });

  test('offline catalogue retains song details and lyrics without an original-song download', () async {
    final job = KaraokeJob.fromJson(ready());
    final cached = await service.download(song, job, 25);
    await service.download(song, job, 25, keepOffline: true);
    final item = BaseItemDto(id: BaseItemId(song), name: 'Saved song', type: 'Audio', artists: ['Singer']);
    await service.saveOfflineDetails(item, LyricDto(lyrics: [LyricLine(text: 'Hello', start: 0)]));
    expect(path.isWithin(directory.absolute.path, cached.parent.absolute.path), isTrue);
    await cached.parent.delete(recursive: true);
    final songs = await service.savedSongs();
    expect(songs.single.item.id.raw, song);
    expect(songs.single.item.name, 'Saved song');
    expect(songs.single.guides, [25]);
    expect((await service.savedLyrics(song))?.lyrics?.single.text, 'Hello');
    expect(requests, 1);
    server = 'http://other-server.test';
    expect(await service.savedSongs(), isEmpty);
  });

  test('rejects paths, unsupported vocal levels and malformed revisions before downloading', () async {
    expect(() => KaraokeService.songId('../music'), throwsA(isA<AnalyzerException>()));
    await expectLater(service.download(song, KaraokeJob.fromJson(ready()), 23), throwsA(isA<AnalyzerException>()));
    await expectLater(
      service.download(song, KaraokeJob.fromJson({...ready(), 'revision': '../x'}), 0),
      throwsA(isA<AnalyzerException>()),
    );
    expect(requests, 0);
  });

  test('phone deletion removes all karaoke levels, revisions and metadata, scoped to song and server', () async {
    final job = KaraokeJob.fromJson(ready());
    final old = KaraokeJob.fromJson({...ready(), 'revision': 'b' * 64});
    final item = BaseItemDto(id: const BaseItemId(song), name: 'Saved', type: 'Audio');
    final cached = await service.download(song, job, 0);
    final saved = await service.download(song, job, 25, keepOffline: true);
    final older = await service.download(song, old, 50, keepOffline: true);
    await service.saveOfflineDetails(item, LyricDto(lyrics: [LyricLine(text: 'hello', start: 0)]));
    await service.saveLyrics(song, LyricDto(lyrics: [LyricLine(text: 'cached', start: 0)]));
    final otherSong = await service.download('f' * 32, job, 0, keepOffline: true);
    server = 'http://other-server.test';
    final otherServer = await service.download(song, job, 0, keepOffline: true);
    server = 'http://analyzer.test';
    final before = requests;
    await service.deleteLocal(song);
    expect(requests, before);
    for (final file in [cached, saved, older]) {
      expect(await file.parent.exists(), isFalse);
    }
    expect(await otherSong.exists(), isTrue);
    expect(await otherServer.exists(), isTrue);
    expect(await service.savedSongs(), isEmpty);
    expect(await service.savedLyrics(song), isNull);
    expect((await service.status(song, offline: true)).ready, isFalse);
    await service.deleteLocal(song); // Already deleted is safe.
    expect(await (await service.download(song, job, 0)).length(), 4);
  });

  test('phone deletion refuses active downloads and succeeds after completion', () async {
    final started = Completer<void>(), response = Completer<http.Response>();
    final client = KaraokeService(
      directory: () async => directory,
      settings: () async => (url: server, token: 'test-token'),
      client: MockClient((_) {
        started.complete();
        return response.future;
      }),
    );
    final download = client.download(song, KaraokeJob.fromJson(ready()), 0);
    await started.future;
    await expectLater(client.deleteLocal(song), throwsA(isA<AnalyzerException>()));
    response.complete(http.Response.bytes([1, 2, 3, 4], 200));
    final file = await download;
    await client.deleteLocal(song);
    expect(await file.exists(), isFalse);
  });

  test('server deletion authenticates, checks revision and preserves local copies', () async {
    final job = KaraokeJob.fromJson(ready());
    final saved = await service.download(song, job, 0, keepOffline: true);
    final client = KaraokeService(
      directory: () async => directory,
      settings: () async => (url: server, token: 'test-token'),
      client: MockClient((request) async {
        expect(request.method, 'DELETE');
        expect(request.url.path, '/karaoke/$song');
        expect(request.url.queryParameters, {'revision': revision});
        expect(request.headers['X-Api-Key'], 'test-token');
        expect(request.followRedirects, isFalse);
        return http.Response('{"state":"missing"}', 200);
      }),
    );
    await client.deleteServer(song, job);
    expect(await saved.exists(), isTrue);
  });

  test('local writes cannot recreate files during phone deletion', () async {
    final entered = Completer<void>(), release = Completer<void>();
    final client = KaraokeService(
      directory: () async {
        if (!entered.isCompleted) entered.complete();
        await release.future;
        return directory;
      },
      settings: () async => (url: server, token: 'test-token'),
    );
    final deletion = client.deleteLocal(song);
    await entered.future;
    await expectLater(client.download(song, KaraokeJob.fromJson(ready()), 0), throwsA(isA<AnalyzerException>()));
    await expectLater(client.saveLyrics(song, LyricDto(lyrics: [])), throwsA(isA<AnalyzerException>()));
    await expectLater(
      client.saveOfflineDetails(BaseItemDto(id: const BaseItemId(song)), null),
      throwsA(isA<AnalyzerException>()),
    );
    release.complete();
    await deletion;
    expect(await directory.list(recursive: true).toList(), isEmpty);
  });

  test('server deletion reports conflicts, unsupported servers and redirects', () async {
    for (final code in [401, 404, 405, 409, 302, 500]) {
      final client = KaraokeService(
        settings: () async => (url: server, token: 'test-token'),
        client: MockClient((_) async => http.Response('{"detail":"Cannot delete ($code)"}', code)),
      );
      await expectLater(client.deleteServer(song, KaraokeJob.fromJson(ready())), throwsA(isA<AnalyzerException>()));
    }
    await expectLater(service.deleteLocal('../music'), throwsA(isA<AnalyzerException>()));
    await expectLater(
      service.deleteServer(song, KaraokeJob.fromJson({'revision': '../music'})),
      throwsA(isA<AnalyzerException>()),
    );
  });
}
