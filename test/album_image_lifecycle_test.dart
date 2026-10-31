import 'package:finamp/components/album_image.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/theme_provider.dart';
import 'package:finamp/services/current_album_image_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('a lazy artwork refresh does not rebuild its parent during a child build', (tester) async {
    var version = 0;
    final image = Provider<FinampImage>(
      (ref) => FinampThemeImage.empty(ThemeInfo(BaseItemDto(id: BaseItemId('image-$version'), name: 'Image $version'))),
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    var invalidated = false;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) {
              final latest = ref.watch(image);
              return Column(
                children: [
                  Text(latest.item!.name!),
                  Builder(
                    builder: (_) {
                      if (!invalidated) {
                        invalidated = true;
                        version++;
                        container.invalidate(image);
                      }
                      return const SizedBox.shrink();
                    },
                  ),
                  SizedBox(width: 100, height: 100, child: BareAlbumImage(imageListenable: image, onZoomRoute: false)),
                ],
              );
            },
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('Image 1'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('artwork listeners are released when the source changes or the widget closes', (tester) async {
    final released = <String>[];
    AutoDisposeProvider<FinampImage> image(String name) => Provider.autoDispose<FinampImage>((ref) {
      ref.onCancel(() => released.add(name));
      return const FinampImage.empty();
    });
    final first = image('first'), second = image('second');
    final container = ProviderContainer();
    addTearDown(container.dispose);
    Future<void> show(AutoDisposeProvider<FinampImage> source) => tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: BareAlbumImage(imageListenable: source, onZoomRoute: false)),
      ),
    );
    await show(first);
    await tester.pump();
    await show(second);
    await tester.pump();
    expect(released, ['first']);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(released, ['first', 'second']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('player themes receive the latest artwork without synchronous source notifications', (tester) async {
    var version = 0;
    final source = Provider<FinampImage>(
      (ref) => FinampThemeImage.empty(ThemeInfo(BaseItemDto(id: BaseItemId('theme-$version'), name: 'Theme $version'))),
    );
    final image = deferredArtworkProvider(source);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    var invalidated = false;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Consumer(
            builder: (_, ref, _) => Column(
              children: [
                Text(ref.watch(image).item?.name ?? 'Loading'),
                Builder(
                  builder: (_) {
                    if (!invalidated) {
                      invalidated = true;
                      version++;
                      container.invalidate(source);
                    }
                    return Consumer(builder: (_, ref, _) => Text(ref.watch(image).item?.id.raw ?? 'Empty'));
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('Theme 1'), findsOneWidget);
    expect(find.text('theme-1'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
