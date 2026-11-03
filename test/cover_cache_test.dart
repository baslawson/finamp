import 'dart:async';
import 'dart:io' as io;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file/local.dart';
import 'package:finamp/hive_registrar.g.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/models/locale_adapter.dart';
import 'package:finamp/models/theme_mode_adapter.dart';
import 'package:finamp/services/album_image_provider.dart';
import 'package:finamp/services/artwork_file_cache.dart';
import 'package:finamp/services/cover_cache.dart';
import 'package:finamp/services/downloads_service.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:finamp/services/jellyfin_api_helper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

const _url = 'https://server.test/Items/a/Images/Primary?maxWidth=200';

class _Api extends Fake implements JellyfinApiHelper {}

class _Downloads extends Fake implements DownloadsService {
  @override
  DownloadItem? getImageDownload({BaseItemDto? item, String? blurHash}) => null;
}

/// A phone too full to save a setting.
final class _FullPhone extends InMemorySharedPreferencesAsync {
  _FullPhone() : super.empty();

  @override
  Future<bool> setBool(String key, bool value, SharedPreferencesOptions options) async =>
      throw const io.FileSystemException('No space left on device');
}

Future<ImageInfo> _decode(ImageProvider provider) {
  final done = Completer<ImageInfo>();
  final stream = provider.resolve(ImageConfiguration.empty);
  late final ImageStreamListener listener;
  listener = ImageStreamListener(
    (info, _) {
      stream.removeListener(listener);
      done.complete(info);
    },
    onError: (Object error, StackTrace? stack) {
      stream.removeListener(listener);
      done.completeError(error, stack);
    },
  );
  stream.addListener(listener);
  return done.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late io.Directory folder;
  late SharedPreferencesAsyncPlatform? previous;
  late ArtworkFileCache original;
  late Future<void> Function(String) originalKeep;
  late Future<void> Function() originalEmpty;
  late Future<void> Function(String) originalForget;
  var downloads = 0;
  final kept = <String>[];
  FileInfo? saved;

  /// A 4 × 4 PNG, as the server would send a cover.
  Future<FileInfo> cover(FileSource source) async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawRect(const Rect.fromLTWH(0, 0, 4, 4), ui.Paint()..color = const ui.Color(0xFFC0392B));
    final image = await recorder.endRecording().toImage(4, 4);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final file = const LocalFileSystem().file('${folder.path}/cover.png');
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    return FileInfo(file, source, DateTime.now().add(const Duration(days: 7)), _url);
  }

  /// A fresh cache, as after Finamp restarts: memory gone, only what was saved on the phone is left.
  void restart() {
    PaintingBinding.instance.imageCache.clear();
    CoverCache.files = ArtworkFileCache(
      read: (_) async => saved,
      download: (_, _) async {
        downloads++;
        return saved = await cover(FileSource.Online);
      },
    );
  }

  setUpAll(() {
    Hive.registerAdapters();
    Hive.registerAdapter(ThemeModeAdapter());
    Hive.registerAdapter(ColorAdapter());
    Hive.registerAdapter(LocaleAdapter());
  });

  setUp(() async {
    folder = await io.Directory.systemTemp.createTemp('finamp-cover-cache-');
    previous = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    original = CoverCache.files;
    originalKeep = CoverCache.keepForAYear;
    originalEmpty = CoverCache.empty;
    originalForget = CoverCache.forget;
    CoverCache.forget = (_) async => fail('only a cover saved while turned off is deleted');
    CoverCache.forgetStuckStorage();
    CoverCache.keepForAYear = (key) async => kept.add(key);
    CoverCache.enabled = true;
    downloads = 0;
    kept.clear();
    saved = null;
    restart();
  });

  tearDown(() async {
    PaintingBinding.instance.imageCache.clear();
    CoverCache.files = original;
    CoverCache.keepForAYear = originalKeep;
    CoverCache.empty = originalEmpty;
    CoverCache.forget = originalForget;
    CoverCache.enabled = true;
    SharedPreferencesAsyncPlatform.instance = previous;
    await folder.delete(recursive: true);
  });

  testWidgets('a cover is saved on the phone and shown from there after a restart', (tester) async {
    await tester.runAsync(() async {
      final first = await _decode(CachedImage(NetworkImage(_url, scale: 0.25), 'cover200200', stable: true));
      expect([first.image.width, first.image.height], [4, 4]);
      first.dispose();
      expect(downloads, 1);
      expect(kept, ['cover200200'], reason: 'a blurhash cover is kept a year');

      restart();
      final again = await _decode(CachedImage(NetworkImage(_url, scale: 0.25), 'cover200200', stable: true));
      expect([again.image.width, again.image.height], [4, 4]);
      again.dispose();
      expect(downloads, 1, reason: 'not fetched from the server again');
    });
  });

  testWidgets("a cover that isn't found by its blurhash keeps the server's validity", (tester) async {
    await tester.runAsync(() async {
      (await _decode(CachedImage(NetworkImage(_url, scale: 0.25), 'image200200'))).dispose();
      expect(downloads, 1);
      expect(kept, isEmpty);
    });
  });

  testWidgets('turned off, covers are not saved on the phone', (tester) async {
    CoverCache.enabled = false;
    await tester.runAsync(() async {
      // The test environment answers every network request with an error, so the plain network image fails.
      await expectLater(_decode(CachedImage(NetworkImage(_url, scale: 0.25), 'cover200200')), throwsA(anything));
    });
    expect(downloads, 0);
  });

  test('the setting is remembered, on by default, and turning it off deletes the saved covers', () async {
    var emptied = 0;
    CoverCache.empty = () async => emptied++;
    expect(await CoverCache.load(), isTrue);
    expect(emptied, 0);
    await CoverCache.setEnabled(false);
    expect(emptied, 1);
    CoverCache.enabled = true;
    expect(await CoverCache.load(), isFalse);
    await pumpEventQueue();
    expect(emptied, 2, reason: 'covers saved after turning it off go at the next start');
    await CoverCache.setEnabled(true);
    expect(emptied, 2);
    expect(await CoverCache.load(), isTrue);
  });

  test("turning it off deletes the saved covers even when the phone is too full to save the setting", () async {
    var emptied = 0;
    CoverCache.empty = () async => emptied++;
    SharedPreferencesAsyncPlatform.instance = _FullPhone();
    await expectLater(CoverCache.setEnabled(false), throwsA(isA<io.FileSystemException>()));
    expect(emptied, 1);
    expect(CoverCache.enabled, isFalse);
  });

  for (final turnedOff in [false, true]) {
    test(
      "a slow covers database doesn't hold up a cover already downloaded${turnedOff ? ', turned off' : ''}",
      () async {
        CoverCache.keepForAYear = (_) => Completer<void>().future;
        CoverCache.forget = (_) => Completer<void>().future;
        CoverCache.files = ArtworkFileCache(
          read: (_) async => null,
          download: (_, _) async {
            // Turned off while it downloaded, so the cover isn't kept.
            if (turnedOff) CoverCache.enabled = false;
            return cover(FileSource.Online);
          },
        );
        final shown = await _decode(
          CachedImage(NetworkImage(_url, scale: 0.25), 'cover200200', stable: true),
        ).timeout(const Duration(seconds: 5));
        expect(shown.image.width, 4);
        shown.dispose();
      },
    );
  }

  // A plain test: the files need real time, which a widget test's clock doesn't give.
  test('offline, a cover downloaded earlier in the session shows from the phone', () async {
    final settings = FinampSettings(
      downloadLocations: [],
      downloadLocationsMap: {},
      tabSortBy: {},
      tabSortOrder: {},
      homeScreenConfiguration: const FinampHomeScreenConfiguration(actions: [], sections: []),
      gridImageSize: 130,
      homeScreenImageSize: 90,
      deviceId: 'test',
      isOffline: true,
    );
    GetIt.instance.registerSingleton<JellyfinApiHelper>(_Api());
    GetIt.instance.registerSingleton<DownloadsService>(_Downloads());
    addTearDown(GetIt.instance.reset);
    // Still in memory as it was downloaded, before Finamp went offline.
    final file = await cover(FileSource.Online);
    CoverCache.files = ArtworkFileCache(read: (_) async => file, download: (_, _) async => fail('offline'));
    final container = ProviderContainer(
      overrides: [finampSettingsProvider.overrideWith((ref) => Stream.value(settings))],
    );
    addTearDown(container.dispose);
    await container.read(finampSettingsProvider.future);
    final request = AlbumImageRequest(
      item: BaseItemDto(
        id: const BaseItemId('album'),
        name: 'Album',
        type: 'MusicAlbum',
        imageTags: {'Primary': 'tag'},
        imageBlurHashes: ImageBlurHashes(primary: {'tag': 'bh'}),
      ),
      maxWidth: 100,
      maxHeight: 100,
    );
    final images = <AlbumImageInfo>[];
    container.listen(albumImageProvider(request), (_, next) => images.add(next), fireImmediately: true);
    for (var i = 0; i < 100 && images.last.image == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(images.last.image, isNotNull);
    expect(images.last.uri, Uri.file(file.file.path));
  });

  test("with the phone's storage failing, the cover still comes from the server", () async {
    final png = await (await cover(FileSource.Online)).file.readAsBytes();
    final fetched = <String>[];
    final originalFetch = CoverCache.fetcher;
    CoverCache.fetcher = (url) async {
      fetched.add(url);
      return png;
    };
    addTearDown(() => CoverCache.fetcher = originalFetch);
    CoverCache.files = ArtworkFileCache(
      read: (_) async => throw const io.FileSystemException('No space left on device'),
      download: (_, _) async => throw const io.FileSystemException('No space left on device'),
    );
    final shown = await _decode(CachedImage(NetworkImage(_url, scale: 0.25), 'cover200200', stable: true));
    expect([shown.image.width, shown.image.height], [4, 4]);
    shown.dispose();
    expect(fetched, [_url]);
    expect(kept, isEmpty);
  });

  test("with the saved covers not answering at all, covers come from the server, and later ones don't wait", () async {
    final png = await (await cover(FileSource.Online)).file.readAsBytes();
    final fetched = <String>[];
    final originalFetch = CoverCache.fetcher;
    CoverCache.fetcher = (url) async {
      fetched.add(url);
      return png;
    };
    CoverCache.lookupLimit = const Duration(milliseconds: 50);
    addTearDown(() {
      CoverCache.fetcher = originalFetch;
      CoverCache.lookupLimit = const Duration(seconds: 3);
    });
    var reads = 0;
    final never = Completer<FileInfo?>();
    CoverCache.files = ArtworkFileCache(
      read: (_) {
        reads++;
        return never.future;
      },
      download: (_, _) async => fail('the saved covers are stuck'),
    );
    for (final key in ['first200200', 'second200200']) {
      final clock = Stopwatch()..start();
      final shown = await _decode(CachedImage(NetworkImage(_url, scale: 0.25), key));
      shown.dispose();
      if (key == 'second200200') expect(clock.elapsedMilliseconds, lessThan(50), reason: "it doesn't wait again");
    }
    expect(fetched, hasLength(2));
    expect(reads, 1);
    expect(await CoverCache.saved('first200200'), isNull);
  });

  for (final (name, error) in [
    ('the server answering with an error', HttpExceptionWithStatus(404, 'Not found')),
    ('no connection', const io.SocketException('Connection refused')),
  ]) {
    test("with $name, the cover isn't asked for a second time directly", () async {
      final originalFetch = CoverCache.fetcher;
      CoverCache.fetcher = (_) async => fail('only a storage failure is fetched directly');
      addTearDown(() => CoverCache.fetcher = originalFetch);
      CoverCache.files = ArtworkFileCache(read: (_) async => null, download: (_, _) async => throw error);
      await expectLater(_decode(CachedImage(NetworkImage(_url, scale: 0.25), 'cover200200')), throwsA(same(error)));
    });
  }

  test("a fetched answer that isn't an image doesn't delete a cover kept on the phone", () async {
    final forgotten = <String>[];
    CoverCache.forget = (key) async => forgotten.add(key);
    final originalFetch = CoverCache.fetcher;
    CoverCache.fetcher = (_) async => Uint8List.fromList('<html>Bad gateway</html>'.codeUnits);
    addTearDown(() => CoverCache.fetcher = originalFetch);
    CoverCache.files = ArtworkFileCache(
      read: (_) async => throw const io.FileSystemException('Storage busy'),
      download: (_, _) async => throw const io.FileSystemException('Storage busy'),
    );
    await expectLater(_decode(CachedImage(NetworkImage(_url, scale: 0.25), 'cover200200')), throwsA(anything));
    expect(forgotten, isEmpty);
  });

  test("a saved answer that isn't an image is deleted, so the server is asked again next time", () async {
    final forgotten = <String>[];
    CoverCache.forget = (key) async => forgotten.add(key);
    final broken = const LocalFileSystem().file('${folder.path}/broken');
    await broken.writeAsString('<html>Bad gateway</html>');
    CoverCache.files = ArtworkFileCache(
      read: (_) async => null,
      download: (_, _) async {
        downloads++;
        return FileInfo(broken, FileSource.Online, DateTime.now().add(const Duration(days: 7)), _url);
      },
    );
    await expectLater(_decode(CachedImage(NetworkImage(_url, scale: 0.25), 'cover200200')), throwsA(anything));
    await pumpEventQueue();
    expect(forgotten, ['cover200200']);
    expect(CoverCache.files.peek('cover200200'), isNull);

    // With the server answering properly again, the same cover shows without Finamp restarting.
    CoverCache.files = ArtworkFileCache(read: (_) async => null, download: (_, _) async => cover(FileSource.Online));
    final again = await _decode(CachedImage(NetworkImage(_url, scale: 0.25), 'cover200200'));
    expect(again.image.width, 4);
    again.dispose();
  });

  test('a kept cover cut off partway, which only fails as it is drawn, is deleted too', () async {
    final forgotten = <String>[];
    CoverCache.forget = (key) async => forgotten.add(key);
    // A noisy picture, so its compressed data is long enough to cut partway.
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    for (var i = 0; i < 64 * 64; i++) {
      canvas.drawRect(
        Rect.fromLTWH((i % 64).toDouble(), (i ~/ 64).toDouble(), 1, 1),
        ui.Paint()..color = ui.Color(0xFF000000 | (i * 2654435761) & 0xFFFFFF),
      );
    }
    final image = await recorder.endRecording().toImage(64, 64);
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
    image.dispose();
    final cut = const LocalFileSystem().file('${folder.path}/cut.png');
    // The header is whole; half the picture data and the end are missing.
    await cut.writeAsBytes(bytes.sublist(0, bytes.length ~/ 2));
    CoverCache.files = ArtworkFileCache(
      read: (_) async => null,
      download: (_, _) async => FileInfo(cut, FileSource.Online, DateTime.now().add(const Duration(days: 7)), _url),
    );
    await expectLater(_decode(CachedImage(NetworkImage(_url, scale: 0.25), 'cover200200')), throwsA(anything));
    await pumpEventQueue();
    expect(forgotten, ['cover200200']);
  });

  test('resetting the download settings turns keeping covers back on, and the switch follows', () async {
    Hive.init(folder.path);
    await Hive.openBox<FinampSettings>('FinampSettings');
    await Hive.box<FinampSettings>('FinampSettings').put(
      'FinampSettings',
      FinampSettings(
        downloadLocations: [],
        downloadLocationsMap: {},
        tabSortBy: {},
        tabSortOrder: {},
        homeScreenConfiguration: const FinampHomeScreenConfiguration(actions: [], sections: []),
        gridImageSize: 130,
        homeScreenImageSize: 90,
        deviceId: 'test',
      ),
    );
    addTearDown(Hive.close);
    CoverCache.empty = () async {};
    await CoverCache.setEnabled(false);
    final seen = <bool>[];
    void listener() => seen.add(CoverCache.changes.value);
    CoverCache.changes.addListener(listener);
    addTearDown(() => CoverCache.changes.removeListener(listener));
    FinampSettingsHelper.resetDownloadSettings();
    await pumpEventQueue();
    expect(seen, [true]);
    expect(await CoverCache.load(), isTrue);
  });

  test('a cover still downloading as it is turned off is shown, but not kept', () async {
    final gate = Completer<void>();
    final forgotten = <String>[];
    CoverCache.forget = (key) async => forgotten.add(key);
    CoverCache.files = ArtworkFileCache(
      read: (_) async => null,
      download: (_, _) async {
        await gate.future;
        return cover(FileSource.Online);
      },
    );
    final shown = _decode(CachedImage(NetworkImage(_url, scale: 0.25), 'cover200200', stable: true));
    await Future<void>.delayed(Duration.zero);
    CoverCache.enabled = false;
    gate.complete();
    (await shown.timeout(const Duration(seconds: 10))).dispose();
    expect(forgotten, ['cover200200']);
    expect(kept, isEmpty);
  });
}
