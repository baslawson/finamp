import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:finamp/hive_registrar.g.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/models/locale_adapter.dart';
import 'package:finamp/models/theme_mode_adapter.dart';
import 'package:finamp/services/analyzer_service.dart';
import 'package:finamp/services/finamp_user_helper.dart';
import 'package:finamp/services/music_player_background_task.dart';
import 'package:finamp/services/playback_history_service.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:finamp/services/radio_preferences.dart';
import 'package:finamp/services/server_hub_service.dart';
import 'package:finamp/services/server_sync_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:http/testing.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

class _LocalHttp extends HttpOverrides {}

class _User extends Fake implements FinampUserHelper {
  @override
  final currentUser = FinampUser(
    id: 'user',
    publicAddress: 'https://server.invalid',
    localAddress: '',
    preferLocalNetwork: false,
    isLocal: false,
    accessToken: 'test',
    serverId: 'server',
  );
}

class _Player extends Fake implements MusicPlayerBackgroundTask {
  @override
  final playbackState = BehaviorSubject.seeded(PlaybackState());
  @override
  bool get paused => true;
  @override
  Duration get playbackPosition => Duration.zero;
}

class _Queue extends Fake implements QueueService {
  @override
  FinampQueueInfo getQueue() => FinampQueueInfo(
    id: 'queue',
    previousTracks: [],
    currentTrack: null,
    nextUp: [],
    queue: [],
    source: QueueService.savedQueueSource,
    saveState: SavedQueueState.saving,
    sourceLibrary: null,
  );
}

class _History extends Fake implements PlaybackHistoryService {
  @override
  List<FinampHistoryItem> get history => [];
}

/// The hub's sync endpoints, as the analyzer has them: a tag naming the configuration, and with `unless` that tag,
/// a short answer. [tagged] false acts as an older server, which has no tag and ignores `unless`.
class _Hub {
  _Hub({this.tagged = true});
  final bool tagged;
  var stations = <Map<String, dynamic>>[];
  Map<String, dynamic>? preferences;
  final requests = <String>[];
  Completer<void>? holding;
  Completer<void>? heldStarted;
  bool failing = false;

  /// A station as the analyzer keeps it (validate_station): its own order of fields, and of preferences.
  static Map<String, dynamic> served(Map<String, dynamic> station) {
    final seed = station['seed'] as Map;
    final preferences = station['preferences'] as Map;
    return {
      'id': station['id'],
      'name': station['name'],
      'seed': {'id': seed['id'], 'name': seed['name'] ?? '', 'type': seed['type'] ?? 'Audio'},
      'mode': station['mode'],
      'preferences': {
        'discovery': preferences['discovery'] ?? 50,
        'energy': preferences['energy'] ?? 0,
        'genres': preferences['genres'] ?? <String>[],
        'excludedArtists': preferences['excludedArtists'] ?? <String>[],
      },
    };
  }

  String get tag => jsonEncode([stations, preferences]).hashCode.toRadixString(16);

  Map<String, dynamic> full() => {
    'revision': 1,
    if (tagged) 'configTag': tag,
    'stations': stations,
    'preferences': preferences,
    'history': List.filled(100, {'id': 'play', 'song': 'song', 'startedMs': 1, 'playedMs': 1}),
    'queue': null,
  };

  late final client = MockClient((request) async {
    final path = request.url.path.replaceFirst('/hub', '');
    final unless = request.url.queryParameters['unless'];
    final fail = failing;
    requests.add('${request.method} $path${unless == null ? '' : '?unless'}');
    if (holding != null) {
      heldStarted?.complete();
      await holding!.future;
      holding = null;
    }
    if (fail) return http.Response('', 500);
    Object? answer;
    if (request.method == 'GET' && path == '/api/sync') {
      answer = tagged && unless == tag ? {'unchanged': true, 'configTag': tag} : full();
    } else if (request.method == 'PATCH' && path == '/api/sync') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final byId = {for (final station in stations) station['id']: station};
      for (final id in body['deleteStations'] as List? ?? []) {
        byId.remove(id);
      }
      for (final station in body['upsertStations'] as List? ?? []) {
        byId[(station as Map)['id']] = served(Map<String, dynamic>.from(station));
      }
      stations = byId.values.cast<Map<String, dynamic>>().toList();
      if (body.containsKey('preferences')) preferences = Map<String, dynamic>.from(body['preferences'] as Map);
      answer = full();
    }
    return answer == null ? http.Response('', 404) : http.Response(jsonEncode(answer), 200);
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory folder;
  late SharedPreferencesAsyncPlatform? oldPreferences;
  late http.Client oldClient;
  late ServerSyncService sync;

  // One store for every test, cleared between them: the service keeps the one it first finds.
  final store = InMemorySharedPreferencesAsync.empty();

  setUpAll(() {
    oldPreferences = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance = store;
    Hive.registerAdapters();
    Hive.registerAdapter(ThemeModeAdapter());
    Hive.registerAdapter(ColorAdapter());
    Hive.registerAdapter(LocaleAdapter());
  });

  tearDownAll(() => SharedPreferencesAsyncPlatform.instance = oldPreferences);

  setUp(() async {
    folder = await Directory.systemTemp.createTemp('finamp-hub-sync-');
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
        isOffline: false,
      ),
    );
    await SharedPreferencesAsync().clear();
    await AnalyzerService.saveSettings(url: 'http://hub.test', token: 'token');
    GetIt.instance.registerSingleton<FinampUserHelper>(_User());
    GetIt.instance.registerSingleton<MusicPlayerBackgroundTask>(_Player());
    GetIt.instance.registerSingleton<QueueService>(_Queue());
    GetIt.instance.registerSingleton<PlaybackHistoryService>(_History());
    oldClient = ServerHubService.client;
    sync = ServerSyncService(startImmediately: false);
  });

  tearDown(() async {
    await sync.dispose();
    ServerHubService.client = oldClient;
    await GetIt.instance.reset();
    await Hive.close();
    await folder.delete(recursive: true);
  });

  Map<String, dynamic> station(String id, String name) => RadioStation(
    id: id,
    name: name,
    seed: BaseItemDto(id: BaseItemId('song'), name: 'Song', type: 'Audio'),
    mode: RadioMode.similar,
    preferences: const RadioPreferences(),
  ).toJson();

  test('once in step, polls ask only whether anything changed, and take in full what did', () async {
    final hub = _Hub();
    ServerHubService.client = hub.client;
    await sync.sync();
    expect(hub.requests, ['GET /api/sync']);
    await sync.sync();
    await sync.sync();
    expect(hub.requests.skip(1), ['GET /api/sync?unless', 'GET /api/sync?unless']);

    // Changed on another device: the answer is in full, and taken in.
    hub.stations = [_Hub.served(station('other', 'From the other phone'))];
    hub.requests.clear();
    await sync.sync();
    expect(hub.requests, ['GET /api/sync?unless']);
    expect((await RadioPreferencesStore.stations()).map((s) => s.name), ['From the other phone']);
    await sync.sync();
    expect(hub.requests.last, 'GET /api/sync?unless', reason: 'in step again');
  });

  test('changed here, it sends the change rather than asking with an old tag', () async {
    final hub = _Hub();
    ServerHubService.client = hub.client;
    await sync.sync();
    await RadioPreferencesStore.writeStations([RadioStation.fromJson(station('mine', 'Made here'))]);
    hub.requests.clear();
    await sync.sync();
    expect(hub.requests, ['GET /api/sync', 'PATCH /api/sync']);
    expect(hub.stations.map((s) => s['name']), ['Made here']);
    hub.requests.clear();
    await sync.sync();
    expect(hub.requests, ['GET /api/sync?unless']);
  });

  test('an older server always gets the full question', () async {
    final hub = _Hub(tagged: false);
    ServerHubService.client = hub.client;
    for (var i = 0; i < 3; i++) {
      await sync.sync();
    }
    expect(hub.requests, ['GET /api/sync', 'GET /api/sync', 'GET /api/sync']);
  });

  test('a sync asked for while one is under way runs once that one is done', () async {
    final hub = _Hub(tagged: false)
      ..holding = Completer()
      ..heldStarted = Completer();
    ServerHubService.client = hub.client;
    final first = sync.sync();
    await hub.heldStarted!.future;
    // Paused meanwhile: its sync must not be lost, as polling slows once paused in the background.
    final again = sync.sync();
    await again;
    expect(hub.requests, ['GET /api/sync']);
    hub.holding!.complete();
    await first;
    for (var i = 0; i < 50 && hub.requests.length < 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(hub.requests, ['GET /api/sync', 'GET /api/sync']);
  });

  test('paused, it keeps trying to send that until a sync begun since goes through', () async {
    final hub = _Hub(tagged: false);
    ServerHubService.client = hub.client;
    final player = GetIt.instance<MusicPlayerBackgroundTask>() as _Player;
    Future<void> pause() async {
      player.playbackState.add(PlaybackState(playing: true));
      await pumpEventQueue();
      player.playbackState.add(PlaybackState(playing: false));
      await pumpEventQueue();
    }

    expect(sync.pauseUnsent, isFalse);
    hub.failing = true;
    await pause();
    expect(sync.pauseUnsent, isTrue);
    expect(hub.requests, ['GET /api/sync'], reason: 'tried at once, and failed');
    await sync.sync(force: true);
    expect(sync.pauseUnsent, isTrue, reason: 'still failing');

    // One begun before a pause doesn't count for it, though it goes through.
    hub
      ..failing = false
      ..holding = Completer()
      ..heldStarted = Completer();
    final before = sync.sync(force: true);
    await hub.heldStarted!.future;
    hub.failing = true;
    await pause();
    final held = hub.requests.length;
    hub.holding!.complete();
    await before;
    for (var i = 0; i < 50 && hub.requests.length == held; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await pumpEventQueue();
    expect(hub.requests.length, held + 1, reason: "the pause's own sync, run after, failed");
    expect(sync.pauseUnsent, isTrue, reason: 'begun before the pause');

    hub.failing = false;
    await sync.sync(force: true);
    expect(sync.pauseUnsent, isFalse, reason: 'the pause went through');
  });

  test('the next song playing is sent at once, as polling while playing in the background is slower', () async {
    final hub = _Hub(tagged: false);
    ServerHubService.client = hub.client;
    final player = GetIt.instance<MusicPlayerBackgroundTask>() as _Player;
    player.playbackState.add(PlaybackState(playing: true, queueIndex: 0));
    await pumpEventQueue();
    player.playbackState.add(PlaybackState(playing: true, queueIndex: 0));
    await pumpEventQueue();
    expect(hub.requests, isEmpty, reason: 'starting to play, or more of the same song, waits for the poll');
    player.playbackState.add(PlaybackState(playing: true, queueIndex: 1));
    await pumpEventQueue();
    expect(hub.requests, ['GET /api/sync']);
  });

  group('a request the server hub does not answer in time', () {
    // A bare socket server: it sees each connection close, which an HTTP server waiting to answer does not.
    late ServerSocket server;
    final open = <Socket>{};
    var accepted = 0;

    setUp(() async {
      server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      open.clear();
      accepted = 0;
      // Real connections, not the test binding's stand-in.
      ServerHubService.client = IOClient(_LocalHttp().createHttpClient(null));
      await AnalyzerService.saveSettings(url: 'http://127.0.0.1:${server.port}', token: 'token');
    });

    tearDown(() async {
      ServerHubService.client.close();
      for (final socket in open.toList()) {
        socket.destroy();
      }
      await server.close();
    });

    Future<void> closesItsConnection({required bool partly}) async {
      server.listen((socket) {
        accepted++;
        open.add(socket);
        var request = '';
        socket.listen(
          (data) {
            request += utf8.decode(data, allowMalformed: true);
            if (partly && request.contains('\r\n\r\n')) {
              socket.write(
                'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 1000\r\n\r\n{"stations"',
              );
            }
          },
          onDone: () => open.remove(socket..destroy()),
          onError: (Object _) => open.remove(socket..destroy()),
        );
      });
      final hub = (await ServerHubService.connect())!;
      for (var i = 0; i < 3; i++) {
        await expectLater(
          hub.request('GET', '/api/sync', timeout: const Duration(milliseconds: 200)),
          throwsA(isA<TimeoutException>()),
        );
      }
      expect(accepted, 3);
      for (var i = 0; i < 100 && open.isNotEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(open, isEmpty, reason: 'each is stopped, not left waiting');
    }

    test('is stopped while waiting for its answer', () => closesItsConnection(partly: false));

    test('is stopped part-way through its answer', () => closesItsConnection(partly: true));

    test('is given up on in time while still connecting, and only so many are left connecting', () async {
      // Taken, but its secure connection never set up.
      server.listen((socket) {
        accepted++;
        open.add(socket);
        socket.listen(
          (_) {},
          onDone: () => open.remove(socket..destroy()),
          onError: (Object _) => open.remove(socket..destroy()),
        );
      });
      await AnalyzerService.saveSettings(url: 'https://127.0.0.1:${server.port}', token: 'token');
      final hub = (await ServerHubService.connect())!;
      Future<void> timesOut() => expectLater(
        hub.request('GET', '/api/sync', timeout: const Duration(milliseconds: 300)),
        throwsA(isA<TimeoutException>()),
      );

      // At once, and then one after another: each on time, and never more connections than so many.
      final waited = Stopwatch()..start();
      await Future.wait([for (var i = 0; i < ServerHubService.mostAtOnce + 2; i++) timesOut()]);
      await timesOut();
      expect(waited.elapsed, lessThan(const Duration(seconds: 2)));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(accepted, ServerHubService.mostAtOnce);

      // Another server (the address changed) goes ahead meanwhile.
      final other = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(other.close);
      other.listen((socket) {
        var request = '';
        socket.listen((data) {
          request += utf8.decode(data, allowMalformed: true);
          if (request.contains('\r\n\r\n')) {
            socket.write(
              'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 11\r\n'
              'Connection: close\r\n\r\n{"ok":true}',
            );
            unawaited(socket.flush().then((_) => socket.close()));
          }
        }, onError: (Object _) {});
      });
      await AnalyzerService.saveSettings(url: 'http://127.0.0.1:${other.port}', token: 'token');
      final elsewhere = (await ServerHubService.connect())!;
      expect(await elsewhere.request('GET', '/api/sync', timeout: const Duration(seconds: 2)), {'ok': true});

      // Once they've ended, connecting again.
      Future<void> endStuck() async {
        for (final socket in open.toList()) {
          socket.destroy();
        }
        open.clear();
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }

      await endStuck();
      await timesOut();
      expect(accepted, ServerHubService.mostAtOnce + 1);
      await endStuck();
    });

    test('sent elsewhere, is not followed to a connection it could not stop', () async {
      server.listen((socket) {
        accepted++;
        open.add(socket);
        var request = '';
        socket.listen(
          (data) {
            request += utf8.decode(data, allowMalformed: true);
            // The first is sent on to one never answered.
            if (request.contains('\r\n\r\n') && request.startsWith('GET /hub/api/sync ')) {
              socket.write('HTTP/1.1 302 Found\r\nLocation: /never\r\nContent-Length: 0\r\n\r\n');
            }
          },
          onDone: () => open.remove(socket..destroy()),
          onError: (Object _) => open.remove(socket..destroy()),
        );
      });
      final hub = (await ServerHubService.connect())!;
      for (var i = 0; i < ServerHubService.mostAtOnce + 2; i++) {
        await expectLater(
          hub.request('GET', '/api/sync', timeout: const Duration(milliseconds: 300)),
          throwsA(isA<ServerHubException>().having((error) => error.status, 'status', 302)),
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(accepted, lessThanOrEqualTo(ServerHubService.mostAtOnce), reason: 'no connections followed elsewhere');
    });

    test('many at once all go through, a few at a time', () async {
      // Asked and not yet answered, at most.
      var asked = 0, most = 0;
      server.listen((socket) {
        accepted++;
        open.add(socket);
        var request = '';
        socket.listen(
          (data) {
            request += utf8.decode(data, allowMalformed: true);
            if (request.contains('\r\n\r\n')) {
              request = '';
              asked++;
              most = asked > most ? asked : most;
              Future<void>.delayed(const Duration(milliseconds: 50), () {
                asked--;
                socket.write(
                  'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 11\r\n'
                  'Connection: close\r\n\r\n{"ok":true}',
                );
                unawaited(socket.flush().then((_) => socket.close()));
              });
            }
          },
          onDone: () => open.remove(socket..destroy()),
          onError: (Object _) => open.remove(socket..destroy()),
        );
      });
      final hub = (await ServerHubService.connect())!;
      final answers = await Future.wait([
        for (var i = 0; i < 12; i++) hub.request('GET', '/api/sync', timeout: const Duration(seconds: 5)),
      ]);
      expect(answers, everyElement({'ok': true}));
      expect(accepted, 12);
      expect(most, lessThanOrEqualTo(ServerHubService.mostAtOnce));
    });
  });
}
