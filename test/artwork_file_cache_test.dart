import 'dart:async';
import 'dart:io';

import 'package:file/local.dart';
import 'package:finamp/services/artwork_file_cache.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory folder;
  late DateTime now;
  setUp(() async {
    folder = await Directory.systemTemp.createTemp('finamp-artwork-cache-');
    now = DateTime(2026, 10, 21);
  });
  tearDown(() => folder.delete(recursive: true));

  Future<FileInfo> info([String name = 'cover']) async {
    final file = const LocalFileSystem().file('${folder.path}/$name');
    await file.writeAsBytes([1, 2, 3]);
    return FileInfo(file, FileSource.Cache, now.add(const Duration(hours: 1)), 'https://server/$name');
  }

  test('simultaneous player, prefetch and theme requests share one disk lookup and download', () async {
    final gate = Completer<FileInfo>();
    var reads = 0, downloads = 0;
    final cache = ArtworkFileCache(
      read: (_) async {
        reads++;
        return null;
      },
      download: (_, _) {
        downloads++;
        return gate.future;
      },
      now: () => now,
    );
    final requests = List.generate(30, (_) => cache.load('album', 'https://server/album'));
    await Future<void>.delayed(Duration.zero);
    expect(reads, 1);
    expect(downloads, 1);
    gate.complete(await info());
    final files = await Future.wait(requests);
    expect(files.every((file) => identical(file, files.first)), isTrue);
    await cache.load('album', 'https://server/album');
    expect(reads, 1);
    expect(downloads, 1);
  });

  test('a valid persistent file is reused without a network request or a startup cache scan', () async {
    final file = await info();
    var reads = 0;
    final cache = ArtworkFileCache(
      read: (_) async {
        reads++;
        return file;
      },
      download: (_, _) async => fail('A valid disk entry must not be downloaded'),
      now: () => now,
    );
    expect(await cache.load('album', 'https://server/album'), same(file));
    expect(cache.peek('album'), same(file));
    expect(reads, 1);
  });

  test('a long browsing session keeps at most 128 metadata entries and recently used files survive', () async {
    final file = await info();
    final cache = ArtworkFileCache(read: (_) async => file, download: (_, _) async => file, now: () => now);
    for (var i = 0; i < 5000; i++) {
      await cache.load('$i', 'https://server/$i');
    }
    expect(cache.length, 128);
    expect(cache.peek('0'), isNull);
    expect(cache.peek('4872'), same(file));
    await cache.load('5000', 'https://server/5000');
    expect(cache.peek('4872'), same(file));
    expect(cache.peek('4873'), isNull);
  });

  test('cold offline lookups share disk work and never download absent or expired artwork', () async {
    final file = await info();
    var reads = 0;
    final cache = ArtworkFileCache(
      read: (key) async {
        reads++;
        return key == 'album' ? file : null;
      },
      download: (_, _) async => fail('An offline lookup must not access the network'),
      now: () => now,
    );
    final files = await Future.wait(List.generate(30, (_) => cache.readCached('album')));
    expect(files.every((value) => identical(value, file)), isTrue);
    expect(reads, 1);
    expect(await cache.readCached('missing'), isNull);
    now = now.add(const Duration(hours: 2));
    expect(await cache.readCached('album'), isNull);
  });

  test('expired and OS-deleted temporary files are refreshed rather than returning broken artwork', () async {
    var current = await info();
    var downloads = 0;
    final cache = ArtworkFileCache(
      read: (_) async => current,
      download: (_, _) async {
        downloads++;
        return current = await info();
      },
      now: () => now,
    );
    await cache.load('album', 'https://server/album');
    now = now.add(const Duration(hours: 2));
    await cache.load('album', 'https://server/album');
    expect(downloads, 1);
    await current.file.delete();
    await cache.load('album', 'https://server/album');
    expect(downloads, 2);
  });

  test('a failed download releases its in-flight entry so the next request can retry', () async {
    var calls = 0;
    final cache = ArtworkFileCache(
      read: (_) async => null,
      download: (_, _) async {
        if (++calls == 1) throw const HttpException('unavailable');
        return info();
      },
      now: () => now,
    );
    await expectLater(cache.load('album', 'https://server/album'), throwsA(isA<HttpException>()));
    expect(await cache.load('album', 'https://server/album'), isNotNull);
    expect(calls, 2);
  });
}
