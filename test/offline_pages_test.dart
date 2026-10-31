import 'dart:async';
import 'dart:io';

import 'package:finamp/components/MusicScreen/sort_and_filter_row.dart';
import 'package:finamp/services/artist_content_provider.dart';
import 'package:finamp/hive_registrar.g.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/models/locale_adapter.dart';
import 'package:finamp/models/music_models.dart';
import 'package:finamp/models/music_slices.dart';
import 'package:finamp/models/theme_mode_adapter.dart';
import 'package:finamp/services/downloads_service.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:finamp/services/finamp_user_helper.dart';
import 'package:finamp/services/jellyfin_api_helper.dart';
import 'package:finamp/services/music_providers.dart';
import 'package:finamp/services/music_screen_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:infinite_scroll_pagination/infinite_scroll_pagination.dart';
import 'package:hive_ce_flutter/adapters.dart';

/// Downloaded albums, counting how often the whole list is read.
class _Downloads extends Fake implements DownloadsService {
  _Downloads(this.albums);
  final List<DownloadStub> albums;

  /// Which library each album is in, when that matters.
  final Map<DownloadStub, BaseItemId> libraries = {};
  int reads = 0;

  /// When set, reading the downloads waits for it, like a slow phone.
  Completer<void>? slow;
  final changes = StreamController<void>.broadcast();

  @override
  Stream<void> get catalogChanges => changes.stream;

  /// The tracks of each downloaded album.
  final Map<BaseItemId, List<BaseItemDto>> albumTracks = {};

  @override
  Future<List<BaseItemDto>> getCollectionTracks(
    BaseItemDto item, {
    bool playable = true,
    BaseItemId? genreFilter,
    bool onlyFavorites = false,
  }) async => List.of(albumTracks[item.id] ?? []);

  /// Downloaded tracks, for the tracks tab.
  final List<DownloadStub> tracks = [];

  @override
  Future<List<DownloadStub>> getAllTracks({
    String? nameFilter,
    BaseItemDto? relatedTo,
    BaseItemId? viewFilter,
    bool nullableViewFilters = true,
    bool onlyFavorites = false,
    BaseItemId? genreFilter,
  }) async {
    reads++;
    await slow?.future;
    return List.of(tracks);
  }

  @override
  Future<List<DownloadStub>> getAllCollections({
    String? nameFilter,
    List<BaseItemDtoType> includeItemTypes = const [],
    BaseItemDto? relatedTo,
    bool fullyDownloaded = false,
    BaseItemId? viewFilter,
    BaseItemId? childViewFilter,
    bool nullableViewFilters = true,
    bool onlyFavorites = false,
    BaseItemDtoType? infoForType,
    ArtistType? artistType,
    BaseItemId? genreFilter,
  }) async {
    reads++;
    await slow?.future;
    return [
      for (final album in albums)
        if (viewFilter == null || album.viewId == viewFilter) album,
    ];
  }
}

/// Never asked anything offline, but the artist lists look for it.
class _Server extends Fake implements JellyfinApiHelper {}

extension on DownloadStub {
  BaseItemId? get viewId => (GetIt.instance<DownloadsService>() as _Downloads).libraries[this];
}

/// Who's signed in, and so which library is the current one.
final _user = StateProvider<FinampUser?>((ref) => null);

FinampUser _userIn(String library) => FinampUser(
  id: 'user',
  publicAddress: 'http://server',
  localAddress: 'http://server',
  preferLocalNetwork: false,
  isLocal: false,
  accessToken: 'token',
  serverId: 'server',
  currentViewId: BaseItemId(library),
  views: {
    for (final id in ['A', 'B']) BaseItemId(id): BaseItemDto(id: BaseItemId(id), name: id, type: 'CollectionFolder'),
  },
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory folder;
  late ProviderContainer container;
  late _Downloads downloads;

  setUpAll(() {
    Hive.registerAdapters();
    Hive.registerAdapter(ThemeModeAdapter());
    Hive.registerAdapter(ColorAdapter());
    Hive.registerAdapter(LocaleAdapter());
  });

  setUp(() async {
    folder = await Directory.systemTemp.createTemp('finamp-offline-pages-');
    Hive.init(folder.path);
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
        isOffline: true,
      ),
    );
    downloads = _Downloads([
      for (var i = 0; i < 250; i++)
        DownloadStub.fromItem(
          type: DownloadItemType.collection,
          item: BaseItemDto(
            id: BaseItemId('album$i'),
            name: 'Album ${i.toString().padLeft(3, '0')}',
            type: 'MusicAlbum',
          ),
        ),
    ]);
    container = ProviderContainer(
      overrides: [FinampUserHelper.finampCurrentUserProvider.overrideWith((ref) => ref.watch(_user))],
    );
    GetIt.instance.registerSingleton<ProviderContainer>(container);
    GetIt.instance.registerSingleton<DownloadsService>(downloads);
    GetIt.instance.registerSingleton<JellyfinApiHelper>(_Server());
    await container.read(finampSettingsProvider.future);
  });

  tearDown(() async {
    container.dispose();
    await GetIt.instance.reset();
    await Hive.close();
    await folder.delete(recursive: true);
  });

  MusicScreenPlayable albums(
    SortBy sortBy, {
    LibraryId library = allLibraryPlaceholder,
    ContentType tab = ContentType.albums,
  }) {
    final controller = SortAndFilterController(
      contentType: tab,
      startingConfig: SortAndFilterConfiguration(sortBy: sortBy, sortOrder: SortOrder.ascending, filters: {}),
      skipResolving: true,
    );
    return MusicScreenPlayable(
      tab: tab,
      library: library,
      source: QueueItemSource.rawId(
        type: QueueItemSourceType.allTracks,
        name: const QueueItemSourceName(type: QueueItemSourceNameType.preTranslated, pretranslatedName: 'Albums'),
        id: 'albums',
      ),
      sortConfig: container.read(resolveSortProvider(controller)),
    );
  }

  /// Loads the first [pages] pages of 100, kept open as the music screen keeps them.
  Future<List<String>> load(MusicScreenPlayable request, int pages) async {
    final names = <String>[];
    for (var page = 0; page < pages; page++) {
      final provider = loadHomeSectionItemsProvider(request: request, startIndex: page * 100, limit: 100);
      container.listen(provider, (_, _) {});
      names.addAll([for (final item in (await container.read(provider.future))!) item.name!]);
    }
    return names;
  }

  test('scrolling through downloads offline reads and sorts the library once, not once a page', () async {
    final names = await load(albums(SortBy.sortName), 3);
    expect(names, [for (var i = 0; i < 250; i++) 'Album ${i.toString().padLeft(3, '0')}']);
    expect(downloads.reads, 1);
    expect(await container.read(musicScreenItemCountProvider(albums(SortBy.sortName)).future), 250);
    expect(downloads.reads, 1, reason: 'the count uses the same list');
  });

  test('a random order offline never repeats or loses an album from page to page', () async {
    final names = await load(albums(SortBy.random), 3);
    expect(names.length, 250);
    expect(names.toSet().length, 250);
    expect(downloads.reads, 1);
  });

  test('refreshing reads the downloads again', () async {
    final request = albums(SortBy.sortName);
    await load(request, 2);
    container.invalidate(offlineHomeSectionItemsProvider(request));
    await load(request, 1);
    expect(downloads.reads, 2);
  });

  test(
    'refreshing a random list by hand shuffles it again; a download change or other rebuild keeps its order',
    () async {
      final request = albums(SortBy.random);
      final paged = pagedContentProvider(request);
      container.listen(paged, (_, _) {});
      final before = await load(request, 1);
      container.invalidate(offlineHomeSectionItemsProvider(request));
      expect(await load(request, 1), before, reason: 'rebuilt for something else, such as a setting');
      container.read(paged.notifier).refresh();
      await pumpEventQueue();
      expect(await load(request, 1), before, reason: 'refreshed after a download was deleted');
      container.read(paged.notifier).refresh(byHand: true);
      await pumpEventQueue();
      final refreshed = await load(request, 1);
      expect(refreshed, isNot(before), reason: 'refreshed by hand');
      downloads.albums.removeLast();
      downloads.changes.add(null);
      await pumpEventQueue();
      final changed = await load(request, 1);
      expect(changed.take(99), refreshed.where((name) => name != 'Album 249').take(99));
    },
  );

  test(
    'a random list keeps its order through the refresh after a download is deleted, with no page held open',
    () async {
      final paged = pagedContentProvider(albums(SortBy.random));
      container.listen(paged, (_, _) {});
      Future<List<String>> firstPage() async {
        container.read(paged.notifier).newPage();
        await pumpEventQueue();
        return [for (final item in container.read(paged).items!) (item as FinampPlayableDto).item.name!];
      }

      final before = await firstPage();
      container.read(paged.notifier).refresh();
      await pumpEventQueue();
      expect(await firstPage(), before);
    },
  );

  test("an artist's tracks offline show a download removed or added, and after a refresh", () async {
    final artist = BaseItemDto(id: const BaseItemId('artist'), name: 'Artist', type: 'MusicArtist');
    const album = BaseItemId('album');
    downloads.albums
      ..clear()
      ..add(
        DownloadStub.fromItem(
          type: DownloadItemType.collection,
          item: BaseItemDto(id: album, name: 'Album', type: 'MusicAlbum'),
        ),
      );
    BaseItemDto track(int i) => BaseItemDto(id: BaseItemId('Track $i'), name: 'Track $i', type: 'Audio');
    downloads.albumTracks[album] = [for (var i = 0; i < 30; i++) track(i)];
    final paged = pagedContentProvider(
      MusicScreenPlayable(
        tab: ContentType.tracks,
        library: allLibraryPlaceholder,
        source: QueueItemSource.rawId(
          type: QueueItemSourceType.allTracks,
          name: const QueueItemSourceName(type: QueueItemSourceNameType.preTranslated, pretranslatedName: 'Test'),
          id: 'test',
        ),
        sortConfig: ResolvedSortConfig.skipResolving(
          SortAndFilterConfiguration(
            sortBy: SortBy.sortName,
            sortOrder: SortOrder.ascending,
            filters: {ItemFilter(type: ItemFilterType.artistFilter, extras: artist)},
          ),
        ),
      ),
    );
    container.listen(paged, (_, _) {});
    Future<int> shown() async {
      container.read(paged.notifier).newPage();
      await pumpEventQueue();
      return container.read(paged).items!.length;
    }

    expect(await shown(), 30);
    downloads.albumTracks[album]!.removeLast();
    downloads.changes.add(null);
    await pumpEventQueue();
    expect(container.read(paged).items!.length, 29, reason: 'one deleted');
    container.read(paged.notifier).refresh(byHand: true);
    await pumpEventQueue();
    expect(await shown(), 29, reason: 'still gone after a refresh');
    downloads.albumTracks[album]!.addAll([track(30), track(31)]);
    downloads.changes.add(null);
    await pumpEventQueue();
    expect(container.read(paged).items!.length, 31, reason: 'two downloaded');
  });

  group("an artist's tracks opened on their own, as from the home screen", () {
    late Artist<Track> artist;
    setUp(() {
      const album = BaseItemId('album');
      downloads.albums
        ..clear()
        ..add(
          DownloadStub.fromItem(
            type: DownloadItemType.collection,
            item: BaseItemDto(id: album, name: 'Album', type: 'MusicAlbum'),
          ),
        );
      downloads.albumTracks[album] = [
        for (var i = 0; i < 30; i++)
          BaseItemDto(id: BaseItemId('Track ${i.toString().padLeft(2, '0')}'), name: 'Track $i', type: 'Audio'),
      ];
      artist = Artist<Track>(
        BaseItemDto(id: const BaseItemId('artist'), name: 'Artist', type: 'MusicArtist'),
        source: QueueItemSource.rawId(
          type: QueueItemSourceType.artist,
          name: const QueueItemSourceName(type: QueueItemSourceNameType.preTranslated, pretranslatedName: 'Artist'),
          id: 'artist',
        ),
        sortConfig: ResolvedSortConfig.defaultSort,
        type: ArtistChildType.tracks,
        library: allLibraryPlaceholder,
      );
    });

    test('the track chosen plays, though one above it was deleted since', () async {
      container.listen(getChildTracksProvider(item: artist), (_, _) {});
      await container.read(getChildTracksProvider(item: artist).future);
      downloads.albumTracks[const BaseItemId('album')]!.removeAt(0);
      downloads.changes.add(null);
      await pumpEventQueue();
      final slice =
          await container.read(
                getPlayableSliceProvider(item: artist, startingOffset: 5, chosen: const BaseItemId('Track 05')).future,
              )
              as BasePlayableSlice;
      expect(slice.items[slice.startingIndex].id, const BaseItemId('Track 05'));
    });

    test('a track that is in the list twice: the one tapped plays, not the first', () async {
      BaseItemDto track(String id) => BaseItemDto(id: BaseItemId(id), name: id, type: 'Audio');
      final list = PrecalculatedPlayable(
        source: QueueItemSource.rawId(
          type: QueueItemSourceType.playlist,
          name: const QueueItemSourceName(type: QueueItemSourceNameType.preTranslated, pretranslatedName: 'List'),
          id: 'list',
        ),
        tracks: [track('A'), track('B'), track('A'), track('C')],
      );
      final slice =
          await container.read(
                getPlayableSliceProvider(item: list, startingOffset: 2, chosen: const BaseItemId('A')).future,
              )
              as BasePlayableSlice;
      expect(slice.startingIndex, 2);
    });

    test("switching library doesn't keep the old library's rows on show", () async {
      downloads.albums
        ..clear()
        ..addAll([
          for (final library in ['A', 'B'])
            DownloadStub.fromItem(
              type: DownloadItemType.collection,
              item: BaseItemDto(id: BaseItemId('album $library'), name: 'Album $library', type: 'MusicAlbum'),
            ),
        ]);
      for (final album in downloads.albums) {
        final library = album.baseItem!.name!.substring(6);
        downloads.libraries[album] = BaseItemId(library);
        downloads.albumTracks[album.baseItem!.id] = [
          for (var i = 0; i < 10; i++) BaseItemDto(id: BaseItemId('$library$i'), name: '$library $i', type: 'Audio'),
        ];
      }
      container.read(_user.notifier).state = _userIn('A');
      final inLibrary = Artist<Track>(
        artist.item,
        source: artist.source,
        sortConfig: ResolvedSortConfig.defaultSort,
        type: ArtistChildType.tracks,
        library: currentLibraryPlaceholder,
      );
      final paged = pagedContentProvider(inLibrary);
      final states = <PagingState<int, FinampDisplayableOrPlayable>>[];
      container.listen(paged, (_, next) => states.add(next), fireImmediately: true);
      container.read(paged.notifier).newPage();
      await pumpEventQueue();
      String libraryOf(FinampDisplayableOrPlayable item) => (item as Track).item.name!.substring(0, 1);
      expect({for (final item in container.read(paged).items!) libraryOf(item)}, {'A'});

      states.clear();
      downloads.slow = Completer();
      container.read(_user.notifier).state = _userIn('B');
      await pumpEventQueue();
      downloads.slow!.complete();
      await pumpEventQueue();
      for (final state in states) {
        final shown = {for (final item in state.items ?? <FinampDisplayableOrPlayable>[]) libraryOf(item)};
        expect(shown, isNot(contains('A')));
      }
      expect({for (final item in container.read(paged).items!) libraryOf(item)}, {'B'});
    });

    test(
      "its albums in random order keep it when the downloads change, and are shuffled afresh by a refresh",
      () async {
        downloads.albums
          ..clear()
          ..addAll([
            for (var i = 0; i < 250; i++)
              DownloadStub.fromItem(
                type: DownloadItemType.collection,
                item: BaseItemDto(id: BaseItemId('Album $i'), name: 'Album $i', type: 'MusicAlbum'),
              ),
          ]);
        final albums = Artist<Album>(
          artist.item,
          source: artist.source,
          sortConfig: ResolvedSortConfig.skipResolving(
            SortAndFilterConfiguration(sortBy: SortBy.random, sortOrder: SortOrder.ascending, filters: <ItemFilter>{}),
          ),
          type: ArtistChildType.albumsFromArtist,
          library: allLibraryPlaceholder,
        );
        final paged = pagedContentProvider(albums);
        container.listen(paged, (_, _) {});
        container.read(paged.notifier).newPage();
        await pumpEventQueue();
        List<String> shown() => [for (final item in container.read(paged).items!) (item as Album).item.name!];
        final before = shown();
        expect(before, hasLength(250));
        downloads.albums.removeAt(0);
        downloads.changes.add(null);
        await pumpEventQueue();
        final kept = shown();
        expect(kept, before.where((name) => name != 'Album 0').toList());
        // As pulling the artist screen to refresh does.
        container.read(artistReshufflesProvider.notifier).state++;
        await pumpEventQueue();
        expect(shown(), isNot(kept), reason: 'shuffled afresh');
        expect(shown().toSet(), kept.toSet());
      },
    );

    test(
      'its tracks, with their albums in random order, keep that order when the downloads change, not a refresh',
      () async {
        downloads.albums.clear();
        for (var i = 0; i < 40; i++) {
          final album = BaseItemDto(id: BaseItemId('Album $i'), name: 'Album $i', type: 'MusicAlbum');
          downloads.albums.add(DownloadStub.fromItem(type: DownloadItemType.collection, item: album));
          downloads.albumTracks[album.id] = [
            BaseItemDto(id: BaseItemId('Track $i'), name: 'Track $i', albumId: album.id, type: 'Audio'),
          ];
        }
        FinampSetters.setTabSortBy(ContentType.inAlbumArtistAlbums, SortBy.random);
        await pumpEventQueue();
        final paged = pagedContentProvider(artist);
        container.listen(paged, (_, _) {});
        // Kept open besides, as a row tapped keeps its songs.
        container.listen(getChildTracksProvider(item: artist), (_, _) {});
        container.read(paged.notifier).newPage();
        await pumpEventQueue();
        List<BaseItemId> shown() => [for (final track in container.read(paged).items!) (track as Track).item.id];
        final before = shown();
        downloads.changes.add(null);
        await pumpEventQueue();
        expect(shown(), before);
        container.read(paged.notifier).refresh(byHand: true);
        await pumpEventQueue();
        container.read(paged.notifier).newPage();
        await pumpEventQueue();
        expect(shown(), isNot(before), reason: 'refreshed by hand, so shuffled afresh');
        expect(shown().toSet(), before.toSet());
      },
    );

    test('a steady random order: the same for the same seed, keeping its order with one gone, new for a new seed', () {
      final items = [for (var i = 0; i < 40; i++) BaseItemDto(id: BaseItemId('$i'), name: '$i', type: 'MusicAlbum')];
      List<String> order(List<BaseItemDto> items, int seed) => [
        for (final item in sortSteadily(items, SortBy.random, SortOrder.ascending, seed)) item.id.raw,
      ];
      final first = order(items, 1);
      expect(order(items.reversed.toList(), 1), first, reason: 'whatever order they come in');
      expect(order(items.skip(1).toList(), 1), first.where((id) => id != '0').toList());
      expect(order(items, 2), isNot(first));
      expect(order(items, 2).toSet(), first.toSet());
    });

    test('listed again for many download changes, it makes no more sort providers', () async {
      final paged = pagedContentProvider(artist);
      container.listen(paged, (_, _) {});
      container.read(paged.notifier).newPage();
      await pumpEventQueue();
      // Those following the settings, as the app makes; checks in debug builds make others, each for a moment.
      int sorts() => container
          .getAllProviderElements()
          .where((e) => e.origin.from == resolveSortProvider && e.origin.argument is TrackingSortAndFilterController)
          .length;
      final before = sorts();
      for (var i = 0; i < 10; i++) {
        downloads.changes.add(null);
        await pumpEventQueue();
      }
      expect(sorts(), before);
    });

    test('its rows stay on show while it is listed again for a download change', () async {
      final paged = pagedContentProvider(artist);
      container.listen(paged, (_, _) {});
      container.read(paged.notifier).newPage();
      await pumpEventQueue();
      expect(container.read(paged).items, hasLength(30));
      downloads.slow = Completer();
      downloads.changes.add(null);
      await pumpEventQueue();
      expect(container.read(paged).items, hasLength(30), reason: 'kept while it is listed again');
      expect(container.read(paged).isLoading, isTrue);
      downloads.slow!.complete();
      await pumpEventQueue();
      expect(container.read(paged).items, hasLength(30));
      expect(container.read(paged).isLoading, isFalse);
    });
  });

  test("an artist's tracks in random order keep it when the downloads change, though their list is shared", () async {
    final artist = BaseItemDto(id: const BaseItemId('artist'), name: 'Artist', type: 'MusicArtist');
    final shared = [
      for (var i = 0; i < 250; i++) BaseItemDto(id: BaseItemId('Track $i'), name: 'Track $i', type: 'Audio'),
    ];
    final type = container.read(finampSettingsProvider.defaultArtistType);
    final withArtist = ProviderContainer(
      overrides: [
        getArtistTracksProvider(artist: artist, filterOfflineArtistType: type).overrideWith((ref) async => shared),
      ],
    );
    addTearDown(withArtist.dispose);
    final request = MusicScreenPlayable(
      tab: ContentType.tracks,
      library: allLibraryPlaceholder,
      source: QueueItemSource.rawId(
        type: QueueItemSourceType.allTracks,
        name: const QueueItemSourceName(type: QueueItemSourceNameType.preTranslated, pretranslatedName: 'Test'),
        id: 'test',
      ),
      sortConfig: ResolvedSortConfig.skipResolving(
        SortAndFilterConfiguration(
          sortBy: SortBy.random,
          sortOrder: SortOrder.ascending,
          filters: {ItemFilter(type: ItemFilterType.artistFilter, extras: artist)},
        ),
      ),
    );
    final list = offlineHomeSectionItemsProvider(request);
    withArtist.listen(list, (_, _) {});
    final before = [for (final item in (await withArtist.read(list.future))!) item.id];
    downloads.changes.add(null);
    await pumpEventQueue();
    expect([for (final item in (await withArtist.read(list.future))!) item.id], before);
  });

  test('a download finished or removed while a list is open shows on the next pages and in the count', () async {
    final request = albums(SortBy.sortName);
    await load(request, 1);
    final count = musicScreenItemCountProvider(request);
    container.listen(count, (_, _) {});
    expect(await container.read(count.future), 250);
    downloads.albums.removeLast();
    downloads.changes.add(null);
    await Future<void>.delayed(Duration.zero);
    final third = loadHomeSectionItemsProvider(request: request, startIndex: 200, limit: 100);
    container.listen(third, (_, _) {});
    expect((await container.read(third.future))!.length, 49);
    expect(await container.read(count.future), 249);
    expect(downloads.reads, 2, reason: 'read again once, for the change');
  });

  test('a random order keeps its place when the downloads change, with new ones at the end', () {
    BaseItemDto album(String id) => BaseItemDto(id: BaseItemId(id), name: id, type: 'MusicAlbum');
    final previous = [album('c'), album('a'), album('d'), album('b')];
    final now = [album('e'), album('b'), album('a'), album('c')];
    expect([for (final item in keepRandomOrder(previous, now)) item.id.raw], ['c', 'a', 'b', 'e']);
  });

  test('the open list keeps its pages while it rebuilds for a download change, so it stays where you were', () async {
    final request = albums(SortBy.sortName);
    final paged = pagedContentProvider(request);
    final states = <PagingState<int, FinampDisplayableOrPlayable>>[];
    container.listen(paged, (_, next) => states.add(next), fireImmediately: true);
    for (var page = 0; page < 2; page++) {
      container.read(paged.notifier).newPage();
      await pumpEventQueue();
    }
    expect(container.read(paged).pages?.length, 2);

    states.clear();
    downloads.slow = Completer();
    downloads.albums.removeAt(0);
    downloads.changes.add(null);
    await pumpEventQueue();
    expect(states, isNotEmpty, reason: 'the rebuild started');
    expect(states.every((state) => state.pages?.length == 2), isTrue, reason: 'never back to a loading list');
    expect(container.read(paged).items!.length, 200, reason: 'the old pages while the new ones load');
    expect(container.read(paged).isLoading, isTrue, reason: 'so nothing plays from the old pages');

    downloads.slow!.complete();
    await pumpEventQueue();
    expect(states.every((state) => state.pages?.length == 2), isTrue);
    final names = [for (final item in container.read(paged).items!) (item as FinampPlayableDto).item.name];
    expect(names.first, 'Album 001', reason: 'then the new list');
    expect(container.read(paged).isLoading, isFalse);
    expect(downloads.reads, 2);
  });

  test("switching library never shows the old library's pages as ready, nor mixes the two", () async {
    downloads.albums
      ..clear()
      ..addAll([
        for (final library in ['A', 'B'])
          for (var i = 0; i < 150; i++)
            DownloadStub.fromItem(
              type: DownloadItemType.collection,
              item: BaseItemDto(
                id: BaseItemId('$library$i'),
                name: '$library ${i.toString().padLeft(3, '0')}',
                type: 'MusicAlbum',
              ),
            ),
      ]);
    for (final album in downloads.albums) {
      downloads.libraries[album] = BaseItemId(album.baseItem!.name!.substring(0, 1));
    }
    container.read(_user.notifier).state = _userIn('A');
    final request = albums(SortBy.sortName, library: currentLibraryPlaceholder);
    final paged = pagedContentProvider(request);
    final states = <PagingState<int, FinampDisplayableOrPlayable>>[];
    container.listen(paged, (_, next) => states.add(next), fireImmediately: true);
    for (var page = 0; page < 2; page++) {
      container.read(paged.notifier).newPage();
      await pumpEventQueue();
    }
    String libraryOf(FinampDisplayableOrPlayable item) => (item as FinampPlayableDto).item.name!.substring(0, 1);
    expect({for (final item in container.read(paged).items!) libraryOf(item)}, {'A'});

    states.clear();
    downloads.slow = Completer();
    container.read(_user.notifier).state = _userIn('B');
    await pumpEventQueue();
    downloads.slow!.complete();
    await pumpEventQueue();
    for (final state in states) {
      final libraries = {for (final item in state.items ?? <FinampDisplayableOrPlayable>[]) libraryOf(item)};
      expect(libraries.length, lessThan(2), reason: 'never a mix of the two');
      if (libraries.contains('A')) expect(state.isLoading, isTrue, reason: "A's pages aren't offered as ready");
    }
    expect({for (final item in container.read(paged).items!) libraryOf(item)}, {'B'});
  });

  test('nothing plays from the old pages while the downloads list is rebuilt', () async {
    final request = albums(SortBy.sortName);
    final paged = pagedContentProvider(request);
    container.listen(paged, (_, _) {});
    for (var page = 0; page < 2; page++) {
      container.read(paged.notifier).newPage();
      await pumpEventQueue();
    }
    downloads.slow = Completer();
    downloads.albums.removeAt(0);
    downloads.changes.add(null);
    await pumpEventQueue();
    expect(container.read(paged).items!.length, 200, reason: 'the old pages on show');

    String name(FinampDisplayableOrPlayable item) => (item as FinampPlayableDto).item.name!;
    final (cached, whole) = container.read(paged.notifier).loadSlice(0, 10);
    final (partly, rest) = container.read(paged.notifier).loadSlice(150, 100);
    expect(cached, isEmpty, reason: 'all of it was on show, but it waits');
    expect(partly, isEmpty, reason: 'part of it was on show, but it waits');
    downloads.slow!.complete();
    final first = [for (final item in await whole!) name(item)];
    expect(first.length, 10);
    expect(first.first, 'Album 001', reason: 'the removed album never plays');
    final later = [for (final item in await rest!) name(item)];
    expect(later.length, 99, reason: 'the 249 left, from the 151st');
    expect(later.first, 'Album 151');
    expect(later, isNot(contains('Album 000')));
  });

  test(
    'asking for songs straight after a change, before the list has caught up, still waits for the new list',
    () async {
      final request = albums(SortBy.sortName);
      final paged = pagedContentProvider(request);
      container.listen(paged, (_, _) {});
      for (var page = 0; page < 2; page++) {
        container.read(paged.notifier).newPage();
        await pumpEventQueue();
      }
      downloads.slow = Completer();
      downloads.albums.removeAt(0);
      // The change and the request in one go, with no chance for the list to rebuild in between.
      container.invalidate(offlineHomeSectionItemsProvider(request));
      final (now, later) = container.read(paged.notifier).loadSlice(0, 10);
      expect(now, isEmpty, reason: 'nothing from the old pages');
      downloads.slow!.complete();
      final names = [for (final item in await later!) (item as FinampPlayableDto).item.name!];
      expect(names.first, 'Album 001');
      expect(names, isNot(contains('Album 000')));
    },
  );

  group('the track chosen is the one that plays, though the downloads change as it is chosen', () {
    late MusicScreenPlayable request;
    DownloadStub track(String name) => DownloadStub.fromItem(
      type: DownloadItemType.track,
      item: BaseItemDto(id: BaseItemId(name), name: name, type: 'Audio'),
    );
    setUp(() async {
      downloads.tracks.addAll([for (var i = 0; i < 250; i++) track('Track ${i.toString().padLeft(3, '0')}')]);
      request = albums(SortBy.sortName, tab: ContentType.tracks);
      final paged = pagedContentProvider(request);
      container.listen(paged, (_, _) {});
      container.read(paged.notifier).newPage();
      await pumpEventQueue();
    });
    Future<String> plays(int row, {BaseItemId? chosen}) async {
      final slice = await container.read(
        getPlayableSliceProvider(item: request, startingOffset: row, chosen: chosen).future,
      );
      return switch (slice) {
        BasePlayableSlice base => base.items[base.startingIndex].name!,
        PreCachedPlayableSlice cached => cached.cachedTracks[cached.startingOffset].name!,
        _ => throw StateError('unexpected $slice'),
      };
    }

    test('a change not yet taken in when it is chosen', () async {
      downloads.tracks.removeAt(0);
      downloads.changes.add(null);
      expect(await plays(5, chosen: const BaseItemId('Track 005')), 'Track 005');
    });
    test('the old pages on show, and many added above it, past the pages loaded', () async {
      downloads.slow = Completer();
      downloads.tracks.addAll([for (var i = 0; i < 350; i++) track('Track 000 ${i.toString().padLeft(3, '0')}')]);
      downloads.changes.add(null);
      await pumpEventQueue();
      final playing = plays(99, chosen: const BaseItemId('Track 099'));
      downloads.slow!.complete();
      expect(await playing, 'Track 099');
    });
    test('the old pages on show, and one removed above it near the top', () async {
      downloads.slow = Completer();
      downloads.tracks.removeAt(0);
      downloads.changes.add(null);
      await pumpEventQueue();
      final playing = plays(5, chosen: const BaseItemId('Track 005'));
      downloads.slow!.complete();
      expect(await playing, 'Track 005');
    });
    test('a row drawn before a change, tapped after the new list is on show (as CarPlay keeps its rows)', () async {
      downloads.tracks.removeAt(0);
      downloads.changes.add(null);
      await pumpEventQueue();
      final shown = container.read(pagedContentProvider(request)).items![5] as FinampPlayableDto;
      expect(shown.item.name, 'Track 006', reason: 'the new list is on show');
      expect(await plays(5, chosen: const BaseItemId('Track 005')), 'Track 005');
    });
    test('tapped again after a download near it is removed, the songs leave that one out', () async {
      final slice = getPlayableSliceProvider(item: request, startingOffset: 5, chosen: const BaseItemId('Track 005'));
      // Kept, as the row keeps the slice it was given.
      container.listen(slice, (_, _) {});
      Future<List<String>> names(PlayableSlice slice) async => [
        for (final item in switch (slice) {
          BasePlayableSlice() => slice.items,
          PreCachedPlayableSlice() => [...slice.cachedTracks, ...await slice.fetchTracks],
          _ => throw StateError('unexpected slice'),
        })
          item.name!,
      ];
      expect(await names(await container.read(slice.future)), contains('Track 010'));
      downloads.tracks.removeAt(10);
      downloads.changes.add(null);
      await pumpEventQueue();
      final again = await names(await container.read(slice.future));
      expect(again, isNot(contains('Track 010')));
      expect(again, contains('Track 005'));
    });
    test('playing it all starts at the top of the latest list, a download added there too', () async {
      downloads.slow = Completer();
      downloads.tracks.insert(0, track('A new download'));
      downloads.changes.add(null);
      await pumpEventQueue();
      final playing = plays(0);
      downloads.slow!.complete();
      expect(await playing, 'A new download');
      expect(await plays(0), 'A new download', reason: 'and once the new list is on show');
    });
    test('removed itself: the one now in its place', () async {
      downloads.slow = Completer();
      downloads.tracks.removeAt(50);
      downloads.changes.add(null);
      await pumpEventQueue();
      final playing = plays(50, chosen: const BaseItemId('Track 050'));
      downloads.slow!.complete();
      expect(await playing, 'Track 051');
    });
  });
}
