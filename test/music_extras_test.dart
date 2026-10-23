import 'dart:async';
import 'dart:convert';

import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/analyzer_service.dart';
import 'package:finamp/services/finamp_user_helper.dart';
import 'package:finamp/services/jellyfin_api_helper.dart';
import 'package:finamp/services/karaoke_practice.dart';
import 'package:finamp/services/karaoke_service.dart';
import 'package:finamp/services/party_voting.dart';
import 'package:finamp/services/radio_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

BaseItemDto song(String id, {bool played = false, String artist = 'A', String genre = 'Rock'}) => BaseItemDto(
  id: BaseItemId(id),
  name: id,
  type: 'Audio',
  artists: [artist],
  genres: [genre],
  userData: UserItemDataDto(playbackPositionTicks: 0, playCount: played ? 3 : 0, isFavorite: false, played: played),
);

class _User extends Fake implements FinampUserHelper {
  FinampUser? user;
  @override
  FinampUser? get currentUser => user;
}

class _Library extends Fake implements JellyfinApiHelper {
  final calls = <Map<Symbol, dynamic>>[];
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName != #getItems) return super.noSuchMethod(invocation);
    calls.add(invocation.namedArguments);
    return Future<List<BaseItemDto>?>.value(
      invocation.namedArguments[#includeItemTypes] == 'MusicGenre'
          ? [BaseItemDto(id: const BaseItemId('rock'), name: 'Rock', type: 'MusicGenre')]
          : [song('match')],
    );
  }
}

void main() {
  test('every discovery percentage targets the requested unheard share without discarding candidates', () {
    final tracks = [
      for (var i = 0; i < 20; i++) song('fresh$i'),
      for (var i = 0; i < 20; i++) song('known$i', played: true),
    ];
    for (var percent = 0; percent <= 100; percent += 5) {
      final ordered = RadioPreferences(discovery: percent).order(tracks, 20);
      expect(ordered.take(20).where((item) => item.userData!.playCount == 0).length, (20 * percent / 100).round());
      expect(ordered.map((item) => item.id).toSet().length, tracks.length);
    }
  });
  test('discovery fills sparse pools sensibly at both extremes and for zero requested songs', () {
    for (final percent in [0, 50, 100]) {
      final tracks = [song('a'), song('b', played: true), song('c', played: true)];
      expect(RadioPreferences(discovery: percent).order(tracks, 10), hasLength(3));
      expect(RadioPreferences(discovery: percent).order(tracks, 0), hasLength(3));
      expect(RadioPreferences(discovery: percent).order([], 10), isEmpty);
    }
  });
  test('genre and artist filters are respected before ranking', () {
    final tracks = [song('a', artist: 'AC/DC'), song('b', genre: 'Jazz'), song('c', artist: 'Other')];
    final preferences = RadioPreferences(genres: ['rock'], excludedArtists: ['acdc']);
    expect(preferences.order(tracks, 10).map((item) => item.id.raw), ['c']);
  });
  test('genre library requests retain a favorites-only source and do not fall back to unrelated genres', () async {
    final api = _Library();
    final library = BaseItemDto(id: const BaseItemId('library'), type: 'CollectionFolder');
    final result = await const RadioPreferences(genres: ['Rock']).libraryTracks(api, library, 100, favoritesOnly: true);
    expect(result.single.id.raw, 'match');
    expect(api.calls.last[#isFavorite], true);
    expect(api.calls.last[#genreFilters], [const BaseItemId('rock')]);
    final before = api.calls.length;
    expect(await const RadioPreferences(genres: ['missing']).libraryTracks(api, library, 100), isEmpty);
    expect(api.calls.length, before + 1);
  });
  test('energy ranking uses measured songs and preserves album order', () {
    final tracks = [song('low'), song('high'), song('unknown')];
    const analysis = {'low': TrackAnalysis(energy: .1), 'high': TrackAnalysis(energy: .9)};
    expect(const RadioPreferences(energy: 1).order(tracks, 3, analysis: analysis).first.id.raw, 'high');
    expect(const RadioPreferences(energy: -1).order(tracks, 3, analysis: analysis).first.id.raw, 'low');
    expect(const RadioPreferences(energy: 1).order(tracks, 3, analysis: analysis, album: true), tracks);
  });
  test('saved stations survive reopening, isolate accounts, and retain no access credentials', () async {
    final old = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    final helper = _User();
    GetIt.instance.registerSingleton<FinampUserHelper>(helper);
    addTearDown(() async {
      SharedPreferencesAsyncPlatform.instance = old;
      await GetIt.instance.reset();
    });
    FinampUser user(String id) => FinampUser(
      id: id,
      publicAddress: 'http://server',
      localAddress: 'http://local',
      preferLocalNetwork: false,
      isLocal: false,
      accessToken: 'must-not-save',
      serverId: 'server',
    );
    helper.user = user('one');
    const preferences = RadioPreferences(discovery: 75, genres: ['Rock'], energy: 1);
    await RadioPreferencesStore.save(preferences);
    final station = RadioPreferencesStore.station(' Test station ', song('seed'), RadioMode.continuous, preferences);
    await RadioPreferencesStore.writeStations([station]);
    final restored = (await RadioPreferencesStore.stations()).single;
    expect(restored.name, 'Test station');
    expect(restored.seed.id.raw, 'seed');
    expect(restored.mode, RadioMode.continuous);
    expect(restored.preferences.discovery, 75);
    expect(jsonEncode(restored.toJson()), isNot(contains('must-not-save')));
    helper.user = user('two');
    expect(await RadioPreferencesStore.stations(), isEmpty);
    expect((await RadioPreferencesStore.load()).discovery, 50);
    helper.user = user('one');
    expect((await RadioPreferencesStore.load()).discovery, 75);
    await RadioPreferencesStore.writeStations([]);
    expect(await RadioPreferencesStore.stations(), isEmpty);
  });

  test('karaoke loops only while playing, seeks once per crossing, and rearms after the seek', () async {
    final seeks = <Duration>[];
    final pending = Completer<void>();
    final practice = KaraokePractice(
      seek: (value) async {
        seeks.add(value);
        await pending.future;
      },
      setSpeed: (_) async {},
      setPitch: (_) async {},
      originalSpeed: 1,
      originalPitch: 1,
    );
    practice.markA(const Duration(seconds: 5));
    practice.markB(const Duration(seconds: 10));
    expect(await practice.tick(const Duration(seconds: 11), playing: false), false);
    final loop = practice.tick(const Duration(seconds: 10), playing: true);
    expect(await practice.tick(const Duration(seconds: 11), playing: true), false);
    pending.complete();
    expect(await loop, true);
    expect(await practice.tick(const Duration(seconds: 11), playing: true), false);
    expect(await practice.tick(const Duration(seconds: 5), playing: true), false);
    expect(await practice.tick(const Duration(seconds: 10), playing: true), true);
    expect(seeks, [const Duration(seconds: 5), const Duration(seconds: 5)]);
    await practice.close();
    expect(await practice.tick(const Duration(seconds: 10), playing: true), false);
  });
  test('invalid loop ranges are rejected and failed seeks release their lock', () async {
    var calls = 0;
    final practice = KaraokePractice(
      seek: (_) async {
        if (++calls == 1) throw StateError('seek');
      },
      setSpeed: (_) async {},
      setPitch: (_) async {},
      originalSpeed: 1,
      originalPitch: 1,
    );
    expect(() => practice.markB(const Duration(seconds: 2)), throwsArgumentError);
    practice.markA(const Duration(seconds: 2));
    expect(() => practice.markB(const Duration(milliseconds: 2500)), throwsArgumentError);
    practice.markB(const Duration(seconds: 4));
    await expectLater(practice.tick(const Duration(seconds: 4), playing: true), throwsStateError);
    expect(await practice.tick(const Duration(seconds: 4), playing: true), true);
  });
  test('leaving during a speed change restores speed and pitch last', () async {
    final events = <String>[];
    final pending = Completer<void>();
    final practice = KaraokePractice(
      seek: (_) async {},
      setPitch: (v) async {
        events.add('pitch:$v');
      },
      setSpeed: (v) async {
        events.add('speed:$v');
        if (v == .75) await pending.future;
      },
      originalSpeed: 1.1,
      originalPitch: .9,
    );
    final change = practice.changeSpeed(.75);
    await Future<void>.delayed(Duration.zero);
    final closing = practice.close();
    pending.complete();
    await change;
    await closing;
    expect(events, ['pitch:1.0', 'speed:0.75', 'speed:1.1', 'pitch:0.9']);
    await practice.changeSpeed(.5);
    expect(events.last, 'pitch:0.9');
  });

  PartyRequest request(String id, String guest) => PartyRequest(track: song(id), guest: guest, address: guest);
  test('failed speed restoration can be retried when leaving practice', () async {
    var calls = 0;
    final practice = KaraokePractice(
      seek: (_) async {},
      setPitch: (_) async {},
      originalSpeed: 1,
      originalPitch: 1,
      setSpeed: (_) async {
        if (++calls == 1) throw StateError('temporary failure');
      },
    );
    await expectLater(practice.close(), throwsStateError);
    await practice.close();
    expect(calls, 2);
  });
  test('party voting allows one vote per guest and rejects duplicates and excess requests', () {
    final ballot = PartyVoting();
    final first = request('one', 'A');
    expect(ballot.add(first), true);
    expect(ballot.vote(first.id, 'A'), false);
    expect(ballot.vote(first.id, 'B'), true);
    expect(ballot.vote(first.id, 'B'), false);
    expect(first.voters.length, 2);
    expect(ballot.add(request('one', 'C')), false);
    expect(ballot.add(request('two', 'A')), true);
    expect(ballot.add(request('three', 'A')), true);
    expect(ballot.add(request('four', 'A')), false);
    expect(ballot.vote('missing', 'C'), false);
  });
  test('party winners alternate guests when possible, while respecting votes among eligible requests', () {
    final ballot = PartyVoting();
    final a = request('a', 'A'), a2 = request('a2', 'A'), b = request('b', 'B'), c = request('c', 'C');
    for (final r in [a, a2, b, c]) {
      ballot.add(r);
    }
    for (var i = 0; i < 5; i++) {
      ballot.vote(a.id, '$i');
      ballot.vote(a2.id, '$i');
    }
    ballot.vote(b.id, 'extra');
    expect(ballot.next, anyOf(a, a2));
    final winner = ballot.next!;
    ballot.complete(winner);
    expect(ballot.next, b);
    ballot.complete(b);
    expect(ballot.next?.address, 'A');
    ballot.clear();
    expect(ballot.next, isNull);
    expect(ballot.lastGuest, isNull);
  });

  test('karaoke catalogue uses authenticated paginated requests without exposing tokens', () async {
    const id = '0123456789abcdef0123456789abcdef';
    final service = KaraokeService(
      settings: () async => (url: 'https://server', token: 'secret'),
      client: MockClient((request) async {
        expect(request.url.path, '/karaoke');
        expect(request.url.queryParameters['offset'], '50');
        expect(request.url.queryParameters['state'], 'processing');
        expect(request.url.queryParameters['limit'], '50');
        expect(request.headers['X-Api-Key'], 'secret');
        expect(request.url.toString(), isNot(contains('secret')));
        return http.Response(
          jsonEncode({
            'items': [
              {'id': id, 'state': 'processing'},
            ],
            'total': 51,
          }),
          200,
        );
      }),
    );
    final result = await service.catalogue(offset: 50, state: KaraokeState.processing);
    expect(result.total, 51);
    expect(result.items.single.id, id);
    expect(result.items.single.job.waiting, true);
    await expectLater(service.catalogue(offset: -1), throwsRangeError);
  });
  test('karaoke catalogue rejects unsupported servers, redirects and bad responses', () async {
    for (final code in [404, 302, 500]) {
      final service = KaraokeService(
        settings: () async => (url: 'https://server', token: 'secret'),
        client: MockClient((_) async => http.Response('', code)),
      );
      await expectLater(service.catalogue(), throwsA(isA<AnalyzerException>()));
    }
  });
}
