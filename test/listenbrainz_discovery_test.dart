import 'dart:convert';

import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/finamp_user_helper.dart';
import 'package:finamp/services/jellyfin_api_helper.dart';
import 'package:finamp/services/listenbrainz_client.dart';
import 'package:finamp/services/listenbrainz_discovery_service.dart';
import 'package:finamp/services/radio_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

const a = '11111111-1111-4111-8111-111111111111';
const b = '22222222-2222-4222-8222-222222222222';
const c = '33333333-3333-4333-8333-333333333333';
BaseItemDto track(String id, String artist, String mbid, {String key = 'MusicBrainzTrack', String genre = 'Rock'}) =>
    BaseItemDto(id: BaseItemId(id), name: id, artists: [artist], genres: [genre], providerIds: {key: mbid});

class _User extends Fake implements FinampUserHelper {
  @override
  FinampUser? get currentUser => null;
}

class _Api extends Fake implements JellyfinApiHelper {
  final offsets = <int>[];
  @override
  String get defaultFields => 'ProviderIds';
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #getItems) {
      final offset = invocation.namedArguments[#startIndex] as int;
      offsets.add(offset);
      expect(invocation.namedArguments[#recursive], isTrue);
      expect(invocation.namedArguments[#limit], 500);
      return Future<List<BaseItemDto>?>.value(
        offset == 0
            ? [track('a', 'A', a), for (var i = 1; i < 500; i++) track('other$i', 'Other', '')]
            : [track('b', 'B', b)],
      );
    }
    return super.noSuchMethod(invocation);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferencesAsyncPlatform? oldPrefs;
  setUp(() {
    oldPrefs = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
  });
  tearDown(() async {
    SharedPreferencesAsyncPlatform.instance = oldPrefs;
    await GetIt.instance.reset();
  });

  test('recommendations page the current library and stop after all exact matches are found', () async {
    await SharedPreferencesAsync().setString('scrobbleListenBrainzUser', 'listener');
    await SharedPreferencesAsync().setString('scrobbleListenBrainzToken', 'test-token');
    final api = _Api();
    GetIt.instance.registerSingleton<FinampUserHelper>(_User());
    GetIt.instance.registerSingleton<JellyfinApiHelper>(api);
    var requests = 0;
    final progress = <int>[];
    final result = await http.runWithClient(
      () => ListenBrainzDiscoveryService.generate(onLibraryProgress: progress.add),
      () => MockClient((request) async {
        requests++;
        expect(request.url.path, '/1/cf/recommendation/user/listener/recording');
        return http.Response(
          jsonEncode({
            'payload': {
              'mbids': [
                {'recording_mbid': a},
                {'recording_mbid': b},
                {'recording_mbid': a},
                {'recording_mbid': 'invalid'},
              ],
            },
          }),
          200,
        );
      }),
    );
    expect(result.map((s) => s.id.raw), ['a', 'b']);
    expect(api.offsets, [0, 500]);
    expect(progress, [500, 501]);
    expect(requests, 1);
  });

  test('missing connection and not-yet-generated recommendations have clear failures', () async {
    await expectLater(
      ListenBrainzDiscoveryService.generate(),
      throwsA(
        isA<ListenBrainzDiscoveryException>().having((e) => e.reason, 'reason', ListenBrainzDiscoveryFailure.connect),
      ),
    );
    await SharedPreferencesAsync().setString('scrobbleListenBrainzUser', 'listener');
    await SharedPreferencesAsync().setString('scrobbleListenBrainzToken', 'test-token');
    await http.runWithClient(() async {
      await expectLater(
        ListenBrainzDiscoveryService.generate(),
        throwsA(
          isA<ListenBrainzDiscoveryException>().having(
            (e) => e.reason,
            'reason',
            ListenBrainzDiscoveryFailure.noRecommendations,
          ),
        ),
      );
    }, () => MockClient((_) async => http.Response('', 204)));
  });

  test('matches recording IDs, skips release-track IDs and duplicates, preserves seed and artist spacing', () {
    final seed = track('seed', 'A', '');
    final result = ListenBrainzDiscoveryService.match(
      [a, a, b, c],
      [
        track('a', 'A', a.toUpperCase()),
        track('release', 'B', b, key: 'MusicBrainzReleaseTrack'),
        track('b', 'B', b, key: 'MusicBrainzRecording'),
        track('c', 'C', c),
      ],
      const RadioPreferences(),
      seed: seed,
    );
    expect(result.first, same(seed));
    expect(result.map((s) => s.id.raw), ['seed', 'b', 'a', 'c']);
  });

  test('discovery honours excluded artists and genres', () {
    final result = ListenBrainzDiscoveryService.match(
      [a, b, c],
      [track('a', 'A', a), track('b', 'B', b), track('c', 'C', c, genre: 'Jazz')],
      const RadioPreferences(genres: ['rock'], excludedArtists: ['a']),
    );
    expect(result.map((s) => s.id.raw), ['b']);
  });

  test('all ListenBrainz calls carry contact/auth headers and queue without overlap', () async {
    final client = ListenBrainzClient(minimumInterval: const Duration(milliseconds: 30));
    final starts = <DateTime>[];
    var active = 0, peak = 0;
    await http.runWithClient(
      () async {
        final uri = Uri.https('api.listenbrainz.org', '/1/test');
        await Future.wait([client.get(uri, token: 'test'), client.post(uri, token: 'test', body: '{}')]);
      },
      () => MockClient((request) async {
        starts.add(DateTime.now());
        active++;
        if (active > peak) peak = active;
        expect(request.headers['User-Agent'], ListenBrainzClient.userAgent);
        expect(request.headers['Authorization'], 'Token test');
        await Future<void>.delayed(const Duration(milliseconds: 5));
        active--;
        return http.Response('{}', 200);
      }),
    );
    expect(peak, 1);
    expect(starts.last.difference(starts.first).inMilliseconds, greaterThanOrEqualTo(25));
    expect(() => client.get(Uri.parse('http://example.org'), token: 'secret'), throwsArgumentError);
  });

  test('rate-limit backoff prevents immediate retries and failed requests do not poison the queue', () async {
    final client = ListenBrainzClient(minimumInterval: Duration.zero);
    var calls = 0;
    await http.runWithClient(
      () async {
        final uri = Uri.https('api.listenbrainz.org', '/1/test');
        await client.get(uri);
        await expectLater(client.get(uri), throwsA(isA<http.ClientException>()));
        expect(calls, 1);
      },
      () => MockClient((_) async {
        calls++;
        return http.Response('', 429, headers: {'x-ratelimit-reset-in': '60'});
      }),
    );
    final failing = ListenBrainzClient(minimumInterval: Duration.zero);
    await http.runWithClient(
      () async {
        final uri = Uri.https('api.listenbrainz.org', '/1/test');
        await expectLater(failing.get(uri), throwsA(isA<http.ClientException>()));
        expect((await failing.get(uri)).statusCode, 200);
      },
      () => MockClient((_) async {
        if (calls++ == 1) throw http.ClientException('Offline');
        return http.Response('{}', 200);
      }),
    );
  });
}
