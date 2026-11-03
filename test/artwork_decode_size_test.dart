import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:finamp/hive_registrar.g.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/models/locale_adapter.dart';
import 'package:finamp/models/theme_mode_adapter.dart';
import 'package:finamp/services/album_image_provider.dart';
import 'package:finamp/services/theme_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:palette_generator/palette_generator.dart';

/// A [width] × [height] PNG, [share] of it (from the left) one colour and the rest another.
Future<File> _png(Directory folder, int width, int height, {double share = 1}) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  final split = width * share;
  canvas.drawRect(ui.Rect.fromLTWH(0, 0, split, height.toDouble()), ui.Paint()..color = const ui.Color(0xFFC0392B));
  canvas.drawRect(
    ui.Rect.fromLTWH(split, 0, width - split, height.toDouble()),
    ui.Paint()..color = const ui.Color(0xFF2E86C1),
  );
  final image = await recorder.endRecording().toImage(width, height);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  final file = File('${folder.path}/${width}x${height}_$share.png');
  await file.writeAsBytes(bytes!.buffer.asUint8List());
  return file;
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
  final item = BaseItemDto(id: BaseItemId('a' * 32), name: 'Album', type: 'MusicAlbum');
  late Directory folder;

  setUpAll(() {
    Hive.registerAdapters();
    Hive.registerAdapter(ThemeModeAdapter());
    Hive.registerAdapter(ColorAdapter());
    Hive.registerAdapter(LocaleAdapter());
  });

  setUp(() async {
    folder = await Directory.systemTemp.createTemp('finamp-artwork-size-');
    PaintingBinding.instance.imageCache.clear();
  });

  tearDown(() async {
    PaintingBinding.instance.imageCache.clear();
    await folder.delete(recursive: true);
  });

  group('full-quality artwork', () {
    testWidgets('decodes no larger than the limit, still drawable at four times its size', (tester) async {
      await tester.runAsync(() async {
        final file = await _png(folder, 1600, 1600);
        final info = await _decode(artworkFromFile(file, AlbumImageRequest(item: item), fullLimit: 400));
        expect([info.image.width, info.image.height], [400, 400]);
        expect(info.scale, 0.25);
        info.dispose();
      });
    });

    testWidgets('keeps its shape when it is not square', (tester) async {
      await tester.runAsync(() async {
        final file = await _png(folder, 1600, 800);
        final info = await _decode(artworkFromFile(file, AlbumImageRequest(item: item), fullLimit: 400));
        expect([info.image.width, info.image.height], [400, 200]);
        info.dispose();
      });
    });

    testWidgets('smaller than the limit decodes as it is, not enlarged', (tester) async {
      await tester.runAsync(() async {
        final file = await _png(folder, 300, 300);
        final info = await _decode(artworkFromFile(file, AlbumImageRequest(item: item), fullLimit: 400));
        expect([info.image.width, info.image.height], [300, 300]);
        info.dispose();
      });
    });

    test('is limited to the longest side of the largest screen, and never below 1024', () {
      expect(
        artworkLimit(displays: [(const Size(1080, 2400), 3)], views: [const Size(1080, 2400)], appPixels: false),
        2400,
      );
      expect(
        artworkLimit(displays: [(const Size(600, 800), 2)], views: [const Size(600, 800)], appPixels: false),
        1024,
      );
      expect(artworkLimit(displays: [], views: [], appPixels: false), 2048);
      // A second, larger screen the window can be moved to.
      expect(
        artworkLimit(
          displays: [(const Size(1366, 768), 1), (const Size(5120, 2880), 2)],
          views: [const Size(1366, 768)],
          appPixels: false,
        ),
        5120,
      );
      // Linux sizes screens in scaled pixels: a 3840-pixel one at 200% is 1920 across.
      expect(
        artworkLimit(displays: [(const Size(1920, 1080), 2)], views: [const Size(1600, 900)], appPixels: true),
        3840,
      );
      // A view larger than its screen's reported size.
      expect(
        artworkLimit(displays: [(const Size(1920, 1080), 1)], views: [const Size(3840, 2160)], appPixels: false),
        3840,
      );
    });

    test('counts every screen connected', () {
      var longest = 0.0;
      for (final display in ui.PlatformDispatcher.instance.displays) {
        longest = max(longest, max(display.size.width, display.size.height));
      }
      expect(fullArtworkLimit(), greaterThanOrEqualTo(max(1024, longest.ceil())));
    });
  });

  testWidgets('sized artwork still decodes at twice its size', (tester) async {
    await tester.runAsync(() async {
      final file = await _png(folder, 1600, 1600);
      final request = AlbumImageRequest(item: item, maxWidth: 100, maxHeight: 100);
      final info = await _decode(artworkFromFile(file, request, fullLimit: 400));
      expect([info.image.width, info.image.height], [200, 200]);
      info.dispose();
    });
  });

  group('artwork colours', () {
    testWidgets('are worked out from at most 256 pixels a side', (tester) async {
      await tester.runAsync(() async {
        final large = await _decode(paletteSource(FileImage(await _png(folder, 1600, 1200))));
        expect([large.image.width, large.image.height], [256, 192]);
        large.dispose();
        final small = await _decode(paletteSource(FileImage(await _png(folder, 100, 100))));
        expect([small.image.width, small.image.height], [100, 100]);
        small.dispose();
      });
    });

    testWidgets('are worked out from artwork already sized to be drawn, full-quality or not', (tester) async {
      await tester.runAsync(() async {
        final file = await _png(folder, 1600, 1600);
        for (final request in [
          AlbumImageRequest(item: item),
          AlbumImageRequest(item: item, maxWidth: 100, maxHeight: 100),
        ]) {
          final info = await _decode(paletteSource(artworkFromFile(file, request, fullLimit: 400)));
          expect([info.image.width, info.image.height], [256, 256]);
          info.dispose();
        }
      });
    });

    test('are worked out from artwork from the server as it is cached, not fetched again', () {
      final network = CachedImage(NetworkImage('https://server.test/Items/a/Images/Primary?maxWidth=200'), 'key');
      expect(paletteSource(network), same(network));
      final resized = ResizeImage(NetworkImage('https://server.test/a'), width: 200, height: 200);
      expect(paletteSource(resized), same(resized));
    });

    testWidgets('come out as from the full-size image', (tester) async {
      await tester.runAsync(() async {
        final file = await _png(folder, 1600, 1600, share: .7);
        final full = await _decode(FileImage(file));
        final reduced = await _decode(paletteSource(FileImage(file)));
        final fromFull = await PaletteGenerator.fromImage(full.image, useIsolate: false);
        final fromReduced = await PaletteGenerator.fromImage(reduced.image, useIsolate: false);
        expect(fromReduced.dominantColor?.color, fromFull.dominantColor?.color);
        expect(
          {for (final colour in fromReduced.paletteColors) colour.color},
          {for (final colour in fromFull.paletteColors) colour.color},
        );
        full.dispose();
        reduced.dispose();
      });
    });
  });

  testWidgets('the player artwork is decoded as it is drawn while its colours are worked out', (tester) async {
    await tester.runAsync(() async {
      final file = await _png(folder, 1600, 1600);
      final drawn = artworkFromFile(file, AlbumImageRequest(item: item), fullLimit: 400);
      // The colours fall back to the grey theme meanwhile, which reads the settings.
      Hive.init(folder.path);
      addTearDown(Hive.close);
      final box = await Hive.openBox<FinampSettings>('FinampSettings');
      await box.put(
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
      final providers = ProviderContainer();
      addTearDown(providers.dispose);
      final initial = providers.read(finampThemeFromImageProvider(ThemeColorRequest(drawn, null, false, true)));
      final worked = Completer<void>();
      providers.listen(finampThemeFromImageProvider(ThemeColorRequest(drawn, null, false, true)), (_, next) {
        if (next != initial && !worked.isCompleted) worked.complete();
      });
      await worked.future.timeout(const Duration(seconds: 20));
      // Ready for its song: the very image drawn, not only the small copy the colours came from.
      final key = await drawn.obtainKey(ImageConfiguration.empty);
      for (var i = 0; i < 100 && !PaintingBinding.instance.imageCache.containsKey(key); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(PaintingBinding.instance.imageCache.containsKey(key), isTrue);
    });
  });
}
