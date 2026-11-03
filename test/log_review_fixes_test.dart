import 'dart:async';

import 'package:chopper/chopper.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/downloads_service_backend.dart';
import 'package:finamp/services/jellyfin_api.dart';
import 'package:finamp/services/lrclib_service.dart';
import 'package:finamp/services/new_releases_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final _song = BaseItemDto(
  id: const BaseItemId('song'),
  name: 'Little Wing',
  albumArtist: 'Jimi Hendrix',
  album: 'Axis',
  runTimeTicks: 1000000000,
);

void main() {
  group("request logging", () {
    Level level({bool debug = false, bool verbose = false, bool foreground = true}) =>
        JellyfinApi.httpLogLevel(debug: debug, verbose: verbose, inForeground: foreground);

    test("a normal release logs only the address and the result", () {
      expect(level(), Level.basic);
      expect(level(foreground: false), Level.basic);
    });

    test("asking for verbose logs keeps the detail", () {
      expect(level(verbose: true), Level.body);
      expect(level(verbose: true, foreground: false), Level.headers);
    });

    test("debug builds keep the detail", () {
      expect(level(debug: true), Level.body);
      expect(level(debug: true, foreground: false), Level.headers);
      expect(level(debug: true, verbose: true, foreground: false), Level.body);
    });
  });

  group("LRCLIB being busy", () {
    final found = http.Response('{"syncedLyrics":"[00:01.00]Hello","plainLyrics":"Hello"}', 200);

    setUp(() => LrclibService.busyRetries = const [Duration.zero, Duration.zero]);

    Future<({LyricDto? lyrics, bool failed})> lookUp(FutureOr<http.Response> Function(http.Request) answer) =>
        http.runWithClient(() => LrclibService.lookUp(_song), () => MockClient((request) async => answer(request)));

    for (final status in [502, 503, 504]) {
      test("$status gets another try", () async {
        var asked = 0;
        final result = await lookUp((_) => ++asked == 1 ? http.Response("", status) : found);
        expect(result.lyrics?.lyrics?.single.text, "Hello");
        expect(result.failed, isFalse);
        expect(asked, 2);
      });
    }

    test("it tries both lookups as many times as there are waits, then says it failed", () async {
      final asked = <String, int>{};
      final result = await lookUp((request) {
        asked.update(request.url.path, (count) => count + 1, ifAbsent: () => 1);
        return http.Response("", 503);
      });
      expect(result.lyrics, isNull);
      expect(result.failed, isTrue);
      expect(asked, {"/api/get": 3, "/api/search": 3});
    });

    test("a busy exact match falls back to the search", () async {
      final result = await lookUp(
        (request) => request.url.path == "/api/get"
            ? http.Response("", 503)
            : http.Response('[{"syncedLyrics":"[00:01.00]Found","plainLyrics":"Found"}]', 200),
      );
      expect(result.lyrics?.lyrics?.single.text, "Found");
      expect(result.failed, isFalse);
    });

    test("a busy exact match and an empty search means no lyrics, not a failure", () async {
      final result = await lookUp(
        (request) => request.url.path == "/api/get" ? http.Response("", 503) : http.Response("[]", 200),
      );
      expect(result.lyrics, isNull);
      expect(result.failed, isFalse);
    });

    test("a failing search after a busy exact match says it failed", () async {
      final result = await lookUp((request) => http.Response("", request.url.path == "/api/get" ? 503 : 500));
      expect(result.lyrics, isNull);
      expect(result.failed, isTrue);
    });

    test("the last try can still get through", () async {
      var asked = 0;
      final result = await lookUp((_) => ++asked < 3 ? http.Response("", 502) : found);
      expect(result.lyrics, isNotNull);
    });

    test("other errors aren't tried again", () async {
      var asked = 0;
      final result = await lookUp((_) {
        asked++;
        return http.Response("", 500);
      });
      expect(result.failed, isTrue);
      expect(asked, 1);
    });

    test("no lyrics isn't a failure", () async {
      final result = await lookUp((_) => http.Response("", 404));
      expect(result.lyrics, isNull);
      expect(result.failed, isFalse);
    });

    test("a failed lookup asks again next time, a finished one doesn't", () async {
      var asked = 0;
      var status = 500;
      await http.runWithClient(
        () async {
          final container = ProviderContainer();
          addTearDown(container.dispose);
          Future<void> play() async {
            final listening = container.listen(lrclibLyricsProvider(_song), (_, _) {});
            await container.read(lrclibLyricsProvider(_song).future);
            listening.close();
            await pumpEventQueue();
          }

          await play();
          expect(asked, 1);
          status = 404;
          await play();
          // The exact match and then the search.
          expect(asked, 3, reason: "the failure wasn't kept");
          await play();
          expect(asked, 3, reason: "a real answer is kept");
        },
        () => MockClient((request) async {
          asked++;
          return http.Response("", status);
        }),
      );
    });
  });

  group("MusicBrainz being busy", () {
    final uri = Uri.https("musicbrainz.org", "/ws/2/release-group");

    setUp(() => NewReleasesService.busyRetry = Duration.zero);

    Future<int> ask(List<int> statuses) async {
      var asked = 0;
      final response = await http.runWithClient(
        () => NewReleasesService.askMusicBrainz(uri),
        () => MockClient((request) async => http.Response("{}", statuses[asked++])),
      );
      expect(asked, statuses.length);
      return response.statusCode;
    }

    test("503 gets one more try", () async {
      expect(await ask([503, 200]), 200);
    });

    test("it stops after that one try", () async {
      expect(await ask([503, 503]), 503);
    });

    test("other answers aren't tried again", () async {
      expect(await ask([200]), 200);
      expect(await ask([404]), 404);
    });
  });

  group("asking for a batch of downloads together", () {
    DownloadStub stub(String id) => DownloadStub.fromItem(
      type: DownloadItemType.collection,
      item: BaseItemDto(id: BaseItemId(id), name: id, type: "Playlist"),
    );

    test("one request gets them all, as fresh stubs", () async {
      final asked = <List<BaseItemId>>[];
      final found = await DownloadsSyncService.fetchStubsTogether([stub("a"), stub("b"), stub("c")], (ids) async {
        asked.add(ids);
        return [for (final id in ids) BaseItemDto(id: id, name: "new ${id.raw}", type: "Playlist")];
      });
      expect(asked.single.map((id) => id.raw), ["a", "b", "c"]);
      expect(found[const BaseItemId("b")]?.baseItem?.name, "new b");
      expect(found[const BaseItemId("b")]?.type, DownloadItemType.collection);
    });

    test("a song stays a song", () async {
      BaseItemDto song(BaseItemId id) => BaseItemDto(id: id, name: id.raw, type: "Audio");
      final found = await DownloadsSyncService.fetchStubsTogether([
        DownloadStub.fromItem(type: DownloadItemType.track, item: song(const BaseItemId("t"))),
        DownloadStub.fromItem(type: DownloadItemType.track, item: song(const BaseItemId("u"))),
      ], (ids) async => [for (final id in ids) song(id)]);
      expect(found[const BaseItemId("t")]?.type, DownloadItemType.track);
      expect(found[const BaseItemId("u")]?.baseItem?.type, "Audio");
    });

    test("one on its own is left to the normal request", () async {
      var asked = 0;
      final found = await DownloadsSyncService.fetchStubsTogether([stub("a")], (ids) async {
        asked++;
        return [];
      });
      expect(found, isEmpty);
      expect(asked, 0);
    });

    test("an item the server no longer has stays out, so it's reported as before", () async {
      final found = await DownloadsSyncService.fetchStubsTogether([
        stub("a"),
        stub("gone"),
      ], (ids) async => [BaseItemDto(id: const BaseItemId("a"), name: "a", type: "Playlist")]);
      expect(found.keys.map((id) => id.raw), ["a"]);
    });

    test("anything the server adds that wasn't asked for stays out", () async {
      final found = await DownloadsSyncService.fetchStubsTogether([
        stub("a"),
        stub("b"),
      ], (ids) async => [BaseItemDto(id: const BaseItemId("x"), name: "x", type: "Playlist")]);
      expect(found, isEmpty);
    });
  });
}
