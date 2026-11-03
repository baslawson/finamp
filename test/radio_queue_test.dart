import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/artist_spacing.dart';
import 'package:finamp/services/radio_queue.dart';
import 'package:finamp/services/song_duplicates.dart';
import 'package:flutter_test/flutter_test.dart';

BaseItemDto track(String id, String artist) =>
    BaseItemDto(id: BaseItemId(id), name: 'Song $id', type: 'Audio', artists: [artist]);

QueueItemSource source({bool repeats = false, BaseItemDto? item}) => QueueItemSource.rawId(
  type: QueueItemSourceType.radio,
  id: 'radio',
  item: item,
  allowArtistRepeats: repeats,
  name: const QueueItemSourceName(type: QueueItemSourceNameType.preTranslated, pretranslatedName: 'Radio'),
);

void alternating(List<BaseItemDto> items, {BaseItemDto? previous}) {
  var last = previous == null ? null : ArtistSpacing.artistKey(previous);
  for (final item in items) {
    final artist = ArtistSpacing.artistKey(item);
    expect(artist, isNot(last));
    last = artist;
  }
}

void main() {
  for (final mode in RadioMode.values) {
    test('${mode.name} starts with the exact picked song and removes its other copies', () {
      final picked = track('picked', 'A');
      final copy = BaseItemDto(id: const BaseItemId('copy'), name: picked.name, type: 'Audio', artists: picked.artists);
      final result = RadioQueue.initial(
        picked,
        [
          track('b0', 'B'),
          copy,
          for (var i = 0; i < 4; i++) track('a$i', 'A'),
          for (var i = 1; i < 5; i++) track('b$i', 'B'),
        ],
        mode: mode,
        needed: 6,
      );
      expect(result.selected.first, same(picked));
      expect(result.selected.length, 6);
      expect([...result.selected, ...result.deferred].map((item) => item.id), isNot(contains(copy.id)));
      expect([...result.selected, ...result.deferred].where((item) => item.id == picked.id).length, 1);
      if (mode != RadioMode.albumMix) alternating(result.selected);
    });
  }

  test('a retained current seed plays once and generated followers avoid its artist', () {
    final picked = track('picked', 'A');
    final result = RadioQueue.initial(
      picked,
      [picked, track('a', 'A'), track('b', 'B'), track('c', 'C')],
      mode: RadioMode.similar,
      needed: 10,
      current: picked,
    );
    expect(result.selected.map((item) => item.id), isNot(contains(picked.id)));
    alternating(result.selected, previous: picked);
  });

  test('a picked cover starts even while the original is playing', () {
    final original = BaseItemDto(id: const BaseItemId('oasis'), name: 'Wonderwall', type: 'Audio', artists: ['Oasis']);
    final cover = BaseItemDto(id: const BaseItemId('ryan'), name: 'Wonderwall', type: 'Audio', artists: ['Ryan Adams']);
    final result = RadioQueue.initial(cover, [track('b', 'B')], mode: RadioMode.similar, needed: 5, current: original);
    expect(result.selected.first, same(cover));
  });

  test('a cover linked to a queued version only through a left-out original stays out', () {
    final quartet = BaseItemDto(
      id: const BaseItemId('vsq'),
      name: 'Letterbomb',
      type: 'Audio',
      artists: ['Vitamin String Quartet'],
      album: "Vitamin String Quartet Performs Green Day's American Idiot",
    );
    final original = BaseItemDto(id: const BaseItemId('gd'), name: 'Letterbomb', type: 'Audio', artists: ['Green Day']);
    final broadway = BaseItemDto(
      id: const BaseItemId('cast'),
      name: 'Letterbomb',
      type: 'Audio',
      artists: ['Original Broadway Cast Featuring Green Day'],
    );
    final result = RadioQueue.select([quartet, original], needed: 2, allowArtistRepeats: true, blocked: [broadway]);
    expect(result.selected, isEmpty);
  });

  test('the picked song still starts when related results are empty or all share its artist', () {
    final picked = track('picked', 'A');
    expect(RadioQueue.initial(picked, [], mode: RadioMode.similar, needed: 30).selected, [picked]);
    final result = RadioQueue.initial(picked, [track('a', 'A')], mode: RadioMode.similar, needed: 30);
    expect(result.selected, [picked]);
    expect(result.deferred.map((item) => item.id.raw), ['a']);
  });

  test('an explicitly tapped preview song takes the first position', () {
    final picked = track('picked', 'A'), tapped = track('tapped', 'B');
    final result = RadioQueue.initial(
      picked,
      [picked, track('c', 'C'), tapped],
      mode: RadioMode.similar,
      needed: 30,
      current: picked,
      startingTrack: tapped,
    );
    expect(result.selected.first, tapped);
    expect(result.selected.where((item) => item.id == tapped.id).length, 1);
    expect(result.selected.map((item) => item.id), isNot(contains(picked.id)));
  });

  test('Album Mix keeps the full generated album together after the picked song', () {
    final picked = track('picked', 'A');
    final album = [for (var i = 0; i < 8; i++) track('album$i', 'B')];
    final result = RadioQueue.initial(picked, album, mode: RadioMode.albumMix, needed: 30);
    expect(result.selected, [picked, ...album]);
  });

  test('a ten-song same-artist batch retains the nine deferred songs for later', () {
    final pool = [for (var i = 0; i < 10; i++) track('a$i', 'A')];
    final first = RadioQueue.select(pool, needed: 10, allowArtistRepeats: false);
    expect(first.selected.length, 1);
    expect(first.deferred.length, 9);
    final next = RadioQueue.select(
      [...first.deferred, for (var i = 0; i < 9; i++) track('b$i', 'B')],
      needed: 10,
      allowArtistRepeats: false,
      previous: first.selected.single,
    );
    expect(next.selected.length, 10);
    alternating(next.selected, previous: first.selected.single);
    expect(next.selected.length + next.deferred.length, 18);
  });

  for (final mode in RadioMode.values) {
    test('${mode.name} counts playable songs after spacing and duplicate removal', () {
      final a = track('a0', 'A');
      final pool = [for (var i = 0; i < 12; i++) track('a$i', 'A'), for (var i = 0; i < 12; i++) track('b$i', 'B'), a];
      final allowed = RadioQueue.allowsArtistRepeats(mode, source());
      final result = RadioQueue.select(
        pool,
        needed: 10,
        blocked: [a],
        allowArtistRepeats: allowed,
        previous: a,
        deferBlocked: mode == RadioMode.reshuffle,
      );
      expect(result.selected.length, 10);
      expect(result.selected.map((item) => item.id).toSet().length, 10);
      expect(result.selected.map((item) => item.id), isNot(contains(a.id)));
      if (!allowed) alternating(result.selected, previous: a);
    });
  }

  test('album and explicit artist choices preserve intentional artist repeats', () {
    for (final mode in RadioMode.values) {
      expect(RadioQueue.allowsArtistRepeats(mode, source(repeats: true)), isTrue);
    }
    final artist = BaseItemDto(id: const BaseItemId('artist'), type: 'MusicArtist');
    expect(RadioQueue.allowsArtistRepeats(RadioMode.random, source(item: artist)), isTrue);
    expect(RadioQueue.allowsArtistRepeats(RadioMode.reshuffle, source(item: artist)), isTrue);
    expect(RadioQueue.allowsArtistRepeats(RadioMode.similar, source(item: artist)), isFalse);
    final album = [for (var i = 0; i < 12; i++) track('album$i', 'A')];
    final result = RadioQueue.select(
      album,
      needed: album.length,
      allowArtistRepeats: RadioQueue.allowsArtistRepeats(RadioMode.albumMix, source()),
    );
    expect(result.selected, album);
  });

  test('reshuffle defers queued copies until they have played instead of losing cycle entries', () {
    final a = track('a', 'A'), b = track('b', 'B');
    final first = RadioQueue.select(
      [a, b],
      needed: 10,
      allowArtistRepeats: false,
      blocked: [a],
      previous: a,
      deferBlocked: true,
    );
    expect(first.selected, [b]);
    expect(first.deferred, [a]);
    final next = RadioQueue.select(
      first.deferred,
      needed: 10,
      allowArtistRepeats: false,
      blocked: [b],
      previous: b,
      deferBlocked: true,
    );
    expect(next.selected, [a]);
  });

  test('recent history comes from played tracks rather than the upcoming queue', () {
    FinampQueueItem queued(BaseItemDto item) => FinampQueueItem(
      source: source(),
      item: MediaItem(
        id: item.id.raw,
        title: item.name!,
        duration: const Duration(minutes: 20),
        extras: {'itemJson': item.toJson()},
      ),
    );
    final queue = FinampQueueInfo(
      id: 'q',
      previousTracks: [queued(track('old', 'O')), queued(track('recent', 'R'))],
      currentTrack: queued(track('current', 'C')),
      nextUp: [],
      queue: [queued(track('upcoming', 'U'))],
      source: source(),
      saveState: SavedQueueState.saving,
      sourceLibrary: null,
    );
    expect(RadioQueue.recent(queue, const Duration(minutes: 20)).map((item) => item.id.raw), ['recent']);
  });

  test('continuous radio keeps completed selections when a later request fails', () async {
    var calls = 0;
    final a = track('a', 'A'), b = track('b', 'B'), c = track('c', 'C');
    final result = await RadioQueue.continuous(
      seed: a,
      needed: 10,
      next: (seed, selected) async {
        calls++;
        if (calls == 1) return [b];
        if (calls == 2) return [c];
        throw StateError('server unavailable');
      },
    );
    expect(result, [b, c]);
    expect(calls, 3);
  });

  test('continuous radio rejects repeated artists and duplicate copies of earlier songs', () async {
    final a = track('a', 'A'), b = track('b', 'B');
    var calls = 0;
    final result = await RadioQueue.continuous(
      seed: a,
      needed: 10,
      next: (_, selected) async {
        calls++;
        return selected.isEmpty ? [track('a2', 'A'), b] : [b, track('b2', 'B')];
      },
    );
    expect(result, [b]);
    expect(calls, 2);
  });

  test('versions in different fetches are linked through one each fetch would leave out', () async {
    BaseItemDto letterbomb(String id, String artist, {String? album}) =>
        BaseItemDto(id: BaseItemId(id), name: 'Letterbomb', type: 'Audio', artists: [artist], album: album);
    final batches = [
      [
        letterbomb(
          'vsq',
          'Vitamin String Quartet',
          album: "Vitamin String Quartet Performs Green Day's American Idiot",
        ),
        letterbomb('gd', 'Green Day'),
      ],
      [letterbomb('cast', 'Original Broadway Cast Featuring Green Day')],
    ];
    final result = await RadioQueue.search(
      needed: 5,
      allowArtistRepeats: true,
      attempts: 2,
      fetch: (attempt, _) async => withoutSongsIn(batches[attempt], const []),
    );
    expect(result.map((item) => item.id.raw), ['vsq']);
  });

  test('songs to avoid keep their versions out across fetches, unless there are too few others', () async {
    BaseItemDto letterbomb(String id, String artist, {String? album}) =>
        BaseItemDto(id: BaseItemId(id), name: 'Letterbomb', type: 'Audio', artists: [artist], album: album);
    final heard = letterbomb('cast', 'Original Broadway Cast Featuring Green Day');
    final original = letterbomb('gd', 'Green Day');
    final quartet = letterbomb(
      'vsq',
      'Vitamin String Quartet',
      album: "Vitamin String Quartet Performs Green Day's American Idiot",
    );
    final fresh = track('fresh', 'B');
    Future<List<BaseItemDto>> search(int needed) => RadioQueue.search(
      needed: needed,
      allowArtistRepeats: true,
      attempts: 2,
      avoid: [heard],
      // The first fetch left the original out, as a version of the heard song.
      through: [original],
      fetch: (attempt, _) async => attempt == 0 ? [] : [quartet, fresh],
    );
    expect((await search(1)).map((item) => item.id.raw), ['fresh']);
    expect((await search(2)).map((item) => item.id.raw), ['fresh', 'vsq']);
  });

  test('search broadens a same-artist response until ten playable songs are available', () async {
    var calls = 0;
    final seed = track('seed', 'A');
    final result = await RadioQueue.search(
      needed: 10,
      allowArtistRepeats: false,
      previous: seed,
      fetch: (attempt, limit) async {
        calls++;
        return [
          for (var i = 0; i < 20; i++) track('a$i', 'A'),
          if (attempt >= 2)
            for (var i = 0; i < 20; i++) track('b$i', 'B'),
        ];
      },
    );
    final selected = RadioQueue.select(result, needed: 10, allowArtistRepeats: false, previous: seed);
    expect(calls, 3);
    expect(selected.selected.length, 10);
    alternating(selected.selected, previous: seed);
  });

  test('sparse or failed searches return partial results after a bounded number of requests', () async {
    var calls = 0;
    final b = track('b', 'B');
    final result = await RadioQueue.search(
      needed: 10,
      allowArtistRepeats: false,
      fetch: (_, limit) async {
        if (calls++ == 0) return [b];
        throw StateError('request failed');
      },
    );
    expect(result, [b]);
    expect(calls, 4);
  });

  test('a replaced queue cancels an in-flight search before returning stale tracks', () async {
    var active = true, calls = 0;
    final pending = Completer<List<BaseItemDto>>();
    final result = RadioQueue.search(
      needed: 10,
      allowArtistRepeats: false,
      isCurrent: () => active,
      fetch: (_, limit) {
        calls++;
        return pending.future;
      },
    );
    active = false;
    pending.complete([track('b', 'B')]);
    expect(await result, isEmpty);
    expect(calls, 1);
  });

  test('radio state updates preserve the album fallback selection', () {
    final state = RadioCacheState(
      tracks: [],
      radioMode: RadioMode.albumMix,
      seedItem: null,
      radioState: true,
      albumMixFallbackMode: AlbumMixFallbackModes.artistSingles,
    );
    expect(state.copyWith(generating: true).albumMixFallbackMode, AlbumMixFallbackModes.artistSingles);
  });

  test('rapid refill requests share one operation, even across invalidation', () async {
    final gate = RadioRefillGate();
    final pending = Completer<bool>();
    var calls = 0;
    Future<bool> refill() {
      calls++;
      return pending.future;
    }

    final first = gate.run(refill);
    gate.reset();
    final second = gate.run(refill);
    expect(identical(first, second), isTrue);
    expect(calls, 1);
    pending.complete(false);
    await first;
    await gate.run(() async {
      calls++;
      return true;
    });
    expect(calls, 2);
  });

  test('empty refills back off and successful refills release the delay', () async {
    var now = DateTime(2026);
    final gate = RadioRefillGate(now: () => now);
    var calls = 0;
    Future<bool> fail() async {
      calls++;
      return false;
    }

    await gate.run(fail);
    await gate.run(fail);
    expect(calls, 1);
    now = now.add(const Duration(seconds: 2));
    await gate.run(fail);
    now = now.add(const Duration(seconds: 3));
    await gate.run(fail);
    expect(calls, 2);
    gate.reset();
    await gate.run(() async => true);
    await gate.run(fail);
    expect(calls, 3);
  });

  test('a thrown refill releases the busy lock', () async {
    final gate = RadioRefillGate();
    await expectLater(gate.run(() async => throw StateError('append failed')), throwsStateError);
    var called = false;
    await gate.run(() async {
      called = true;
      return true;
    });
    expect(called, isTrue);
  });
}
