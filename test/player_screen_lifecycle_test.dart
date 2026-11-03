import 'dart:async';
import 'dart:io';

import 'package:finamp/hive_registrar.g.dart';
import 'package:finamp/l10n/app_localizations.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/locale_adapter.dart';
import 'package:finamp/models/theme_mode_adapter.dart';
import 'package:finamp/screens/player_screen.dart';
import 'package:finamp/services/current_album_image_provider.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:finamp/services/theme_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:rxdart/rxdart.dart';

class _Subscription<T> implements StreamSubscription<T> {
  _Subscription(this.inner, this.closed);
  final StreamSubscription<T> inner;
  final void Function() closed;
  bool cancelled = false;
  @override
  Future<void> cancel() {
    if (!cancelled) {
      cancelled = true;
      closed();
    }
    return inner.cancel();
  }

  @override
  Future<E> asFuture<E>([E? futureValue]) => inner.asFuture(futureValue);
  @override
  bool get isPaused => inner.isPaused;
  @override
  void onData(void Function(T)? handleData) => inner.onData(handleData);
  @override
  void onDone(void Function()? handleDone) => inner.onDone(handleDone);
  @override
  void onError(Function? handleError) => inner.onError(handleError);
  @override
  void pause([Future<void>? resumeSignal]) => inner.pause(resumeSignal);
  @override
  void resume() => inner.resume();
}

class _QueueStream extends Fake implements BehaviorSubject<FinampQueueInfo?> {
  final events = StreamController<FinampQueueInfo?>.broadcast();
  int listeners = 0;
  @override
  StreamSubscription<FinampQueueInfo?> listen(
    void Function(FinampQueueInfo?)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    listeners++;
    return _Subscription(
      events.stream.listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError),
      () => listeners--,
    );
  }
}

class _Queue extends Fake implements QueueService {
  final events = _QueueStream();
  final tracks = BehaviorSubject<FinampQueueItem?>.seeded(null);
  @override
  BehaviorSubject<FinampQueueInfo?> getQueueStream() => events;
  @override
  BehaviorSubject<FinampQueueItem?> getCurrentTrackStream() => tracks;
  @override
  List<FinampQueueItem> peekQueue({int? next, int previous = 0, bool current = false}) => [];
  @override
  FinampQueueInfo getQueue() => FinampQueueInfo(
    id: 'loading',
    previousTracks: [],
    currentTrack: null,
    nextUp: [],
    queue: [],
    source: const QueueItemSource.rawId(
      type: QueueItemSourceType.unknown,
      id: 'test',
      name: QueueItemSourceName(type: QueueItemSourceNameType.preTranslated, pretranslatedName: 'Test'),
    ),
    saveState: SavedQueueState.loading,
    sourceLibrary: null,
  );
}

class _Artwork extends StateNotifier<FinampImage> {
  _Artwork() : super(const FinampImage.empty());
}

void main() {
  testWidgets('player rebuilds and repeated visits do not accumulate queue listeners', (tester) async {
    final folder = (await tester.runAsync(() => Directory.systemTemp.createTemp('finamp-player-lifecycle-')))!;
    await tester.runAsync(() async {
      Hive.init(folder.path);
      Hive.registerAdapters();
      Hive.registerAdapter(ThemeModeAdapter());
      Hive.registerAdapter(ColorAdapter());
      Hive.registerAdapter(LocaleAdapter());
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
    });
    final queue = _Queue();
    GetIt.instance.registerSingleton<QueueService>(queue);
    final revision = ValueNotifier(0);
    addTearDown(() async {
      revision.dispose();
      await tester.runAsync(() async {
        await queue.events.events.close();
        await queue.tracks.close();
        await GetIt.instance.reset();
        await Hive.close();
        await folder.delete(recursive: true);
      });
    });
    Widget app() => ProviderScope(
      overrides: [currentAlbumImageProvider.overrideWith((ref) => _Artwork())],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ValueListenableBuilder<int>(
          valueListenable: revision,
          builder: (_, _, _) => PlayerScreen(key: const ValueKey('player')),
        ),
      ),
    );
    await tester.pumpWidget(app());
    await tester.pump();
    expect(queue.events.listeners, 2);
    for (var i = 1; i <= 30; i++) {
      revision.value = i;
      await tester.pump();
      expect(queue.events.listeners, 2, reason: 'A rebuild must not add another navigation subscription');
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(queue.events.listeners, 0, reason: 'Closing the player must release subscriptions immediately');
    for (var i = 0; i < 5; i++) {
      await tester.pumpWidget(app());
      await tester.pump();
      expect(queue.events.listeners, 2);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(queue.events.listeners, 0);
    }
    expect(tester.takeException(), isNull);
  });
}
