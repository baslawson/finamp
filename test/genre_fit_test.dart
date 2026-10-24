import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/hive_registrar.g.dart';
import 'package:finamp/menus/components/menuEntries/genre_answers_menu_entry.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/models/locale_adapter.dart';
import 'package:finamp/models/theme_mode_adapter.dart';
import 'package:finamp/services/analyzer_service.dart';
import 'package:finamp/services/genre_fit.dart';
import 'package:finamp/services/genre_mix.dart';
import 'package:finamp/services/jellyfin_api_helper.dart';
import 'package:finamp/services/radio_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

BaseItemDto _track(String id, List<String>? genres) =>
    BaseItemDto(id: BaseItemId(id), name: id, genres: genres, type: "Audio");

/// A song in the queue that came from [source].
FinampQueueItem _queued(
  String id,
  QueueItemSourceType type, {
  required String sourceId,
  String name = "Mix",
  String? genreMix,
}) => FinampQueueItem(
  item: MediaItem(
    id: id,
    title: id,
    extras: {
      "itemJson": {"Id": id, "Name": id},
    },
  ),
  source: QueueItemSource.rawId(
    type: type,
    id: sourceId,
    name: QueueItemSourceName(type: QueueItemSourceNameType.preTranslated, pretranslatedName: name),
    genreMix: genreMix,
  ),
);

/// A server that can't be reached.
class _NoApi extends Fake implements JellyfinApiHelper {}

/// A server whose only favourites are [favorites].
class _FavoritesApi extends Fake implements JellyfinApiHelper {
  _FavoritesApi(this.favorites, {this.sorted = false});

  final Set<String> favorites;

  /// Whether songs come back in the server's own order rather than the order asked.
  final bool sorted;
  var requests = 0;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    requests++;
    final itemIds = invocation.namedArguments[#itemIds] as List<BaseItemId>;
    expect(itemIds.length, lessThanOrEqualTo(200));
    return Future.value([
      for (final id in sorted ? (itemIds.toList()..sort((a, b) => a.raw.compareTo(b.raw))) : itemIds)
        if (invocation.namedArguments[#isFavorite] != true || favorites.contains(id.raw)) _track(id.raw, ['Pop']),
    ]);
  }
}

/// A server that finds nothing but [genres], and remembers what it was asked.
class _RecordingApi extends Fake implements JellyfinApiHelper {
  _RecordingApi({this.genres = const []});

  final List<BaseItemDto> genres;
  final calls = <Invocation>[];

  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls.add(invocation);
    return Future.value(invocation.namedArguments[#includeItemTypes] == "MusicGenre" ? genres : <BaseItemDto>[]);
  }
}

void main() {
  group("choosing", () {
    List<String> choose(
      List<String> items, {
      Set<String> main = const {},
      Map<String, double> scores = const {},
      int keepAtLeast = 0,
      int? keepAtMost,
    }) => GenreFit.choose(
      items,
      id: (item) => item,
      main: main.contains,
      scores: scores,
      keepAtLeast: keepAtLeast,
      keepAtMost: keepAtMost,
    );

    test("without a sound check, songs only tagged with the genre on the side are left out", () {
      expect(choose(["a", "side1", "b", "side2"], main: {"a", "b"}), ["a", "b"]);
    });

    test("the lowest quarter of sound-checked songs is left out when below average", () {
      final items = [for (var i = 0; i < 8; i++) "s$i"];
      final scores = {for (var i = 0; i < 8; i++) "s$i": (i - 3.5) / 2};
      // s0 and s1 score lowest: a quarter of 8.
      expect(choose(items, main: items.toSet(), scores: scores), items.skip(2).toList());
      // All above average (after the main-tag bonus counts): nothing is left out.
      expect(choose(items, main: items.toSet(), scores: {for (final item in items) item: 0.1}), items);
    });

    test("the main tag counts towards fitting", () {
      final items = ["main", "side", "x1", "x2"];
      final scores = {"main": -0.6, "side": -0.4, "x1": 0.5, "x2": 0.5};
      // Only one of four can go: the side-tag song, as the main-tag song's bonus lifts it to -0.1.
      expect(choose(items, main: {"main", "x1", "x2"}, scores: scores), ["main", "x1", "x2"]);
    });

    test("songs left out come back to reach the minimum, side tags first, then the best poor fits", () {
      final items = [for (var i = 0; i < 8; i++) "s$i", "side"];
      final scores = {for (var i = 0; i < 8; i++) "s$i": (i - 3.5) / 2};
      final main = {for (var i = 0; i < 8; i++) "s$i"};
      expect(choose(items, main: main, scores: scores, keepAtLeast: 7), [for (var i = 2; i < 8; i++) "s$i", "side"]);
      expect(choose(items, main: main, scores: scores, keepAtLeast: 8), [
        for (var i = 2; i < 8; i++) "s$i",
        "side",
        "s1",
      ]);
      expect(choose(items, main: main, scores: scores, keepAtLeast: 100), hasLength(items.length));
    });

    test("is cut to the maximum in the original order", () {
      expect(choose(["a", "b", "c", "d"], main: {"a", "b", "c", "d"}, keepAtMost: 2), ["a", "b"]);
    });
  });

  test("a song's main tag is its first", () {
    expect(GenreFit.hasMainTag(_track("a", ["Rock", "Pop"]), {"rock"}), isTrue);
    expect(GenreFit.hasMainTag(_track("a", ["Pop", "Rock"]), {"rock"}), isFalse);
    expect(GenreFit.hasMainTag(_track("a", ["ROCK"]), {"rock"}), isTrue);
    // No tags: nothing says it doesn't belong.
    expect(GenreFit.hasMainTag(_track("a", null), {"rock"}), isTrue);
  });

  group("filtering with the analyzer", () {
    TestWidgetsFlutterBinding.ensureInitialized();
    late SharedPreferencesAsyncPlatform? previous;

    setUp(() async {
      previous = SharedPreferencesAsyncPlatform.instance;
      SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
      await AnalyzerService.saveSettings(url: 'http://analyzer.test', token: 't');
      GenreFit.forget();
      await GenreFit.isEnabled(); // the switch as these preferences have it
    });

    tearDown(() {
      SharedPreferencesAsyncPlatform.instance = previous;
    });

    final tracks = [
      for (var i = 0; i < 8; i++) _track("rock$i", ["Rock"]),
      _track("ballad", ["Pop", "Rock"]),
    ];

    test("asks for the genre's sound with its main-tag songs and leaves out the poorest fit", () async {
      Map<String, dynamic>? sent;
      final kept = await http.runWithClient(
        () => GenreFit.filter(tracks, name: "Rock", tags: {"Rock"}, keepAtLeast: 2),
        () => MockClient((request) async {
          expect(request.url.path, "/genre-fit");
          sent = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({
              "scores": {for (var i = 0; i < 8; i++) "rock$i": 0.2, "ballad": -1.6},
            }),
            200,
          );
        }),
      );
      expect(sent!["genre"], "Rock");
      expect(sent!["ids"], hasLength(9));
      expect(sent!["main"], [for (var i = 0; i < 8; i++) "rock$i"]);
      expect(kept.map((track) => track.id.raw), [for (var i = 0; i < 8; i++) "rock$i"]);
    });

    test("goes by tags when the analyzer fails or the switch is off", () async {
      var requests = 0;
      Future<List<String>> run() async => (await http.runWithClient(
        () => GenreFit.filter(tracks, name: "Rock", tags: {"rock"}, keepAtLeast: 2),
        () => MockClient((request) async {
          requests++;
          return http.Response("broken", 500);
        }),
      )).map((track) => track.id.raw).toList();

      expect(await run(), [for (var i = 0; i < 8; i++) "rock$i"]);
      expect(requests, 1);
      await GenreFit.setEnabled(false);
      expect(await run(), [for (var i = 0; i < 8; i++) "rock$i"]);
      expect(requests, 1);
    });

    test("checking a pool again, as Radio does on each refill, doesn't keep cutting it down", () async {
      final pool = [
        for (var i = 0; i < 80; i++) _track("song$i", ["Rock"]),
      ];
      var requests = 0;
      // Like the analyzer: scores relative to the songs sent, spread evenly from -1.6 to 1.6 by a fixed order.
      Future<List<BaseItemDto>> check(List<BaseItemDto> tracks) => http.runWithClient(
        () => GenreFit.filter(tracks, name: "Rock", tags: {"Rock"}, keepAtLeast: 10),
        () => MockClient((request) async {
          requests++;
          final ids = ((jsonDecode(request.body) as Map<String, dynamic>)["ids"] as List).cast<String>()
            ..sort((a, b) => int.parse(a.substring(4)).compareTo(int.parse(b.substring(4))));
          return http.Response(
            jsonEncode({
              "scores": {for (final (i, id) in ids.indexed) id: ids.length < 2 ? 0 : -1.6 + 3.2 * i / (ids.length - 1)},
            }),
            200,
          );
        }),
      );

      final first = await check(pool);
      expect(first, hasLength(lessThan(80)));
      final second = await check(first);
      final third = await check(second);
      expect(second.map((track) => track.id.raw), first.map((track) => track.id.raw));
      expect(third.map((track) => track.id.raw), first.map((track) => track.id.raw));
      // Every song was already checked, so the analyzer wasn't asked again.
      expect(requests, 1);
    });

    test("new songs are checked with the pool, and earlier verdicts stand", () async {
      final pool = [
        for (var i = 0; i < 8; i++) _track("old$i", ["Rock"]),
      ];
      Future<List<String>> check(List<BaseItemDto> tracks, Map<String, double> scores) async =>
          (await http.runWithClient(
            () => GenreFit.filter(tracks, name: "Rock", tags: {"Rock"}, keepAtLeast: 1),
            () => MockClient((request) async => http.Response(jsonEncode({"scores": scores}), 200)),
          )).map((track) => track.id.raw).toList();

      // old0 and old1 don't fit.
      final first = await check(pool, {for (var i = 0; i < 8; i++) "old$i": i < 2 ? -2.0 : 0.3});
      expect(first, [for (var i = 2; i < 8; i++) "old$i"]);
      // Asked again with new songs, old0 now scores well and old7 badly, but the earlier verdicts stand.
      final grown = [
        ...pool,
        for (var i = 0; i < 4; i++) _track("new$i", ["Rock"]),
      ];
      final second = await check(grown, {
        for (var i = 0; i < 8; i++) "old$i": i == 7 ? -2.0 : 0.3,
        for (var i = 0; i < 4; i++) "new$i": i == 0 ? -2.0 : 0.3,
      });
      expect(second, [for (var i = 2; i < 8; i++) "old$i", "new1", "new2", "new3"]);
    });

    Future<List<String>> checkWith(List<BaseItemDto> tracks, Map<String, double> scores) async =>
        (await http.runWithClient(
          () => GenreFit.filter(tracks, name: "Rock", tags: {"Rock"}, keepAtLeast: 1),
          () => MockClient((request) async => http.Response(jsonEncode({"scores": scores}), 200)),
        )).map((track) => track.id.raw).toList();

    test("a newcomer to a checked pool gets the verdict it would in a fresh one", () async {
      final pool = [
        for (var i = 0; i < 8; i++) _track("old$i", ["Rock"]),
      ];
      expect(await checkWith(pool, {for (var i = 0; i < 8; i++) "old$i": 0.3}), hasLength(8));
      final grown = [
        ...pool,
        _track("ballad", ["Rock"]),
      ];
      final kept = await checkWith(grown, {for (var i = 0; i < 8; i++) "old$i": 0.3, "ballad": -2.0});
      expect(kept, isNot(contains("ballad")));
      expect(kept, hasLength(8));
    });

    test("without the analyzer, earlier sound checks don't apply", () async {
      final pool = [
        for (var i = 0; i < 8; i++) _track("song$i", ["Rock"]),
      ];
      expect(await checkWith(pool, {for (var i = 0; i < 8; i++) "song$i": i < 2 ? -2.0 : 0.3}), hasLength(6));
      await AnalyzerService.saveSettings(url: '', token: '');
      expect(await GenreFit.filter(pool, name: "Rock", tags: {"Rock"}, keepAtLeast: 1), hasLength(8));
    });

    test("the listener's answers stand: a refused song never comes back, a vouched-for one stays", () async {
      final pool = [
        for (var i = 0; i < 8; i++) _track("song$i", ["Rock"]),
      ];
      final kept = await http.runWithClient(
        // Even needing every song, the refused one stays out.
        () => GenreFit.filter(pool, name: "Rock", tags: {"Rock"}, keepAtLeast: 100),
        () => MockClient(
          (request) async => http.Response(
            jsonEncode({
              "scores": {for (var i = 0; i < 8; i++) "song$i": i == 0 ? -2.5 : 0.3},
              "labels": {"song0": true, "song1": false},
            }),
            200,
          ),
        ),
      );
      expect(kept.map((track) => track.id.raw), [
        for (var i = 0; i < 8; i++)
          if (i != 1) "song$i",
      ]);
    });

    test("an answer applies straight away, and the other songs are checked again with what it taught", () async {
      final pool = [
        for (var i = 0; i < 8; i++) _track("song$i", ["Rock"]),
      ];
      final requests = <String>[];
      // Once taught that song4 isn't Rock, the analyzer finds song1 sounds like it.
      var taught = false;
      Future<List<String>> check() async => (await http.runWithClient(
        () => GenreFit.filter(pool, name: "Rock", tags: {"Rock"}, keepAtLeast: 1),
        () => MockClient((request) async {
          requests.add(request.url.path);
          return http.Response(
            jsonEncode(
              request.url.path == "/genre-fit"
                  ? {
                      "scores": {for (var i = 0; i < 8; i++) "song$i": taught && i == 1 ? -2.0 : 0.3},
                    }
                  : {"ok": true},
            ),
            200,
          );
        }),
      )).map((track) => track.id.raw).toList();

      expect(await check(), hasLength(8));
      await http.runWithClient(
        () => GenreFit.teach("song4", "ROCK", false),
        () => MockClient((request) async {
          requests.add(request.url.path);
          expect(jsonDecode(request.body), {"id": "song4", "genre": "ROCK", "fits": false});
          return http.Response(jsonEncode({"ok": true}), 200);
        }),
      );
      taught = true;
      final again = await check();
      expect(again, isNot(contains("song4")));
      expect(again, isNot(contains("song1")));
      expect(requests, ["/genre-fit", "/genre-labels", "/genre-fit"]);
    });

    test("a reply sent before an answer doesn't undo it", () async {
      final pool = [
        for (var i = 0; i < 8; i++) _track("song$i", ["Rock"]),
      ];
      final reply = Completer<void>();
      final requested = Completer<void>();
      final first = http.runWithClient(
        () => GenreFit.filter(pool, name: "Rock", tags: {"Rock"}, keepAtLeast: 1),
        () => MockClient((request) async {
          requested.complete();
          await reply.future;
          return http.Response(
            jsonEncode({
              "scores": {for (var i = 0; i < 8; i++) "song$i": 0.3},
              "labels": {"song0": true},
            }),
            200,
          );
        }),
      );
      await requested.future;
      await http.runWithClient(
        () => GenreFit.teach("song0", "Rock", false),
        () => MockClient((request) async => http.Response(jsonEncode({"ok": true}), 200)),
      );
      reply.complete();
      await first;
      final again = await http.runWithClient(
        () => GenreFit.filter(pool, name: "Rock", tags: {"Rock"}, keepAtLeast: 1),
        () => MockClient((request) async => fail("Everything is decided")),
      );
      expect(again.map((track) => track.id.raw), isNot(contains("song0")));
    });

    test("Radio looks up the songs said to be its genres first, so they count after a restart", () async {
      final pop = _track("pop", ["Pop"]);
      final ranked = await http.runWithClient(
        () => const RadioPreferences(genres: ["Rock"]).rank([
          pop,
          for (var i = 0; i < 4; i++) _track("rock$i", ["Rock"]),
        ], 1),
        () => MockClient(
          (request) async => request.url.path == "/genre-labels"
              ? http.Response(jsonEncode({"pop": true}), 200)
              : http.Response("busy", 503),
        ),
      );
      expect(ranked, contains(pop));
    });

    test("a song said to be the genre on another device comes back, though a sound check left it out", () async {
      final pool = [
        for (var i = 0; i < 8; i++) _track("song$i", ["Rock"]),
      ];
      final checked = await http.runWithClient(
        () => GenreFit.filter(pool, name: "Rock", tags: {"Rock"}, keepAtLeast: 1),
        () => MockClient(
          (request) async => http.Response(
            jsonEncode({
              "scores": {for (var i = 0; i < 8; i++) "song$i": i == 0 ? -2.0 : 0.3},
            }),
            200,
          ),
        ),
      );
      expect(checked.map((track) => track.id.raw), isNot(contains("song0")));
      await http.runWithClient(
        () => GenreFit.answeredFits("Rock"),
        () => MockClient((request) async => http.Response(jsonEncode({"song0": true}), 200)),
      );
      final again = await http.runWithClient(
        () => GenreFit.filter(pool, name: "Rock", tags: {"Rock"}, keepAtLeast: 1),
        () => MockClient((request) async => fail("Everything is decided")),
      );
      expect(again.map((track) => track.id.raw), contains("song0"));
    });

    test(
      "genres are kept under the analyzer's keys, so an answer changed through a long key read back applies",
      () async {
        final genres = [for (var i = 0; i < 20; i++) "Röck Genre Number $i"];
        final name = GenreMix.radioGenreName(genres);
        // As the analyzer's genre_key makes it for the genres in this order.
        const key =
            "röck genre number 0 | röck genre number 1 | röck genre number 2 | röck genre number 3 | "
            "röck genre number 4 | röck genre number 5 | röck genre number "
            "#49c6e81707f18af653ba2c6dc7d43a604a1e98e499c266294eed515e7f80fd75";
        expect(GenreFit.keyOf(genres.join(" | ")), key);
        expect(GenreFit.keyOf(key), key);
        final readBack = GenreFit.keyOf(name);
        expect(readBack.length, 215);
        expect(GenreFit.keyOf(" Pop   ROCK "), "pop rock");
        // Only A to Z are lowered, as other letters lower differently on the analyzer.
        expect(GenreFit.keyOf("İNDIE  Rock"), "İndie rock");

        final pool = [
          for (var i = 0; i < 8; i++) _track("song$i", [genres.first]),
        ];
        Future<List<String>> check() async => (await http.runWithClient(
          () => GenreFit.filter(pool, name: name, tags: genres.toSet(), keepAtLeast: 1),
          () => MockClient(
            (request) async => http.Response(
              jsonEncode({
                "scores": {for (var i = 0; i < 8; i++) "song$i": 0.3},
              }),
              200,
            ),
          ),
        )).map((track) => track.id.raw).toList();
        Future<void> teach(String genre, bool? fits) => http.runWithClient(
          () => GenreFit.teach("song0", genre, fits),
          () => MockClient((request) async => http.Response(jsonEncode({"ok": true}), 200)),
        );

        await teach(name, false);
        expect(await check(), isNot(contains("song0")));
        // The genre editor lists the answer under the key the analyzer keeps it by.
        await teach(readBack, null);
        expect(await check(), contains("song0"));
      },
    );

    test("a song said not to be the genre on another device leaves, though a sound check kept it", () async {
      final pool = [
        for (var i = 0; i < 8; i++) _track("song$i", ["Rock"]),
      ];
      Future<List<String>> check(MockClient client) async => (await http.runWithClient(
        () => GenreFit.filter(pool, name: "Rock", tags: {"Rock"}, keepAtLeast: 1),
        () => client,
      )).map((track) => track.id.raw).toList();
      final scores = MockClient(
        (request) async => http.Response(
          jsonEncode({
            "scores": {for (var i = 0; i < 8; i++) "song$i": 0.3},
          }),
          200,
        ),
      );
      expect(await check(scores), contains("song0"));
      await http.runWithClient(
        () => GenreFit.answeredFits("Rock"),
        () => MockClient((request) async => http.Response(jsonEncode({"song0": false}), 200)),
      );
      expect(await check(MockClient((request) async => fail("Everything is decided"))), isNot(contains("song0")));
    });

    test("a sound check still out when the switch goes off doesn't cut the mix", () async {
      final pool = [
        for (var i = 0; i < 8; i++) _track("song$i", ["Rock"]),
      ];
      final reply = Completer<void>();
      final requested = Completer<void>();
      final filtered = http.runWithClient(
        () => GenreFit.filter(pool, name: "Rock", tags: {"Rock"}, keepAtLeast: 1),
        () => MockClient((request) async {
          requested.complete();
          await reply.future;
          return http.Response(
            jsonEncode({
              "scores": {for (var i = 0; i < 8; i++) "song$i": i < 2 ? -2.0 : 0.3},
            }),
            200,
          );
        }),
      );
      await requested.future;
      await GenreFit.setEnabled(false);
      reply.complete();
      expect(await filtered, hasLength(8));
    });

    test("a Radio song's genres are the ones its queue was picked for, after Radio's genres change", () async {
      await RadioPreferencesStore.save(const RadioPreferences(genres: ["Jazz"]));
      final rock = _queued("a", QueueItemSourceType.radio, sourceId: "seed", genreMix: "Pop | Rock");
      // The same song in another Radio queue goes by that queue's genres.
      final none = _queued("a", QueueItemSourceType.radio, sourceId: "seed", genreMix: "");
      expect(await GenreMix.current(item: rock), "Pop | Rock");
      expect(await GenreMix.current(item: none), isNull);
      // A song queued before the genres were kept with it goes by Radio's genres now.
      expect(await GenreMix.current(item: _queued("a", QueueItemSourceType.radio, sourceId: "seed")), "Jazz");
      expect(GenreMix.radioGenreMix(const RadioPreferences(genres: ["Rock", "Pop"])), "Pop | Rock");
      expect(GenreMix.radioGenreMix(const RadioPreferences()), "");
    });

    test("Radio's genres are one genre in any order", () {
      expect(GenreMix.radioGenreName(["Rock", "pop"]), "pop | Rock");
      expect(GenreMix.radioGenreName(["pop", "Rock"]), "pop | Rock");
      expect(GenreMix.displayName("pop | Rock"), "pop and Rock");
      expect(GenreMix.displayName("Rock"), "Rock");
      // Different picks never share a name.
      expect(
        GenreMix.radioGenreName(["Country and Western", "Rock"]),
        isNot(GenreMix.radioGenreName(["Country", "Rock", "Western"])),
      );
    });

    test("a song's genre mix is the one it came from", () async {
      await RadioPreferencesStore.save(const RadioPreferences(genres: ["Jazz", "Blues"]));
      await GenreMix.started(sourceName: "Smart Shuffle: Rock", genre: "Rock");
      final shuffled = _queued(
        "a",
        QueueItemSourceType.unknown,
        sourceId: GenreMix.smartShuffleId,
        name: "Smart Shuffle: Rock",
      );
      final radio = _queued("b", QueueItemSourceType.radio, sourceId: "seed");
      final album = _queued("c", QueueItemSourceType.album, sourceId: "album");
      expect(await GenreMix.current(item: shuffled), "Rock");
      // Radio songs added after the Smart Shuffle go by Radio's genres.
      expect(await GenreMix.current(item: radio), "Blues | Jazz");
      expect(await GenreMix.current(item: album), isNull);
      // A later mix doesn't make an earlier one (say, a saved queue played again) forget its genre.
      await GenreMix.started(sourceName: "Smart Shuffle: Jazz", genre: "Jazz");
      expect(await GenreMix.current(item: shuffled), "Rock");
      await RadioPreferencesStore.save(const RadioPreferences());
      expect(await GenreMix.current(item: radio), isNull);
    });

    test("Radio keeps songs said to be its genres, whatever their tags", () async {
      final pop = _track("pop", ["Pop"]);
      const preferences = RadioPreferences(genres: ["Rock"]);
      expect(preferences.order([pop], 1), isEmpty);
      final looked = await http.runWithClient(
        () => preferences.answeredSongs(_NoApi(), library: BaseItemDto(id: BaseItemId("library"))),
        () => MockClient((request) async {
          expect(request.url.queryParameters["genre"], "Rock");
          return http.Response(jsonEncode({"pop": true, "other": false}), 200);
        }),
      );
      expect(looked, isEmpty); // _NoApi finds nothing, but the answers are now known.
      expect(preferences.order([pop], 1), [pop]);
      GenreFit.forget();
      await http.runWithClient(
        () => GenreFit.teach("pop", "Rock", true),
        () => MockClient((request) async => http.Response(jsonEncode({"ok": true}), 200)),
      );
      expect(preferences.order([pop], 1), [pop]);

      // Even when the sound check fails, the song stays in the genre.
      final ranked = await http.runWithClient(
        () => preferences.rank([
          pop,
          for (var i = 0; i < 4; i++) _track("rock$i", ["Rock"]),
        ], 1),
        () => MockClient((request) async => http.Response("busy", 503)),
      );
      expect(ranked, contains(pop));

      // With "Match the sound" off, it goes by tags again.
      await GenreFit.setEnabled(false);
      expect(preferences.order([pop], 1), isEmpty);
    });

    test("a lookup still out when the switch goes off doesn't bring the answers back", () async {
      final pop = _track("pop", ["Pop"]);
      const preferences = RadioPreferences(genres: ["Rock"]);
      final reply = Completer<void>();
      final requested = Completer<void>();
      final lookup = http.runWithClient(
        () => GenreFit.answeredFits("Rock"),
        () => MockClient((request) async {
          requested.complete();
          await reply.future;
          return http.Response(jsonEncode({"pop": true}), 200);
        }),
      );
      await requested.future;
      await GenreFit.setEnabled(false);
      reply.complete();
      expect(await lookup, isEmpty);
      expect(preferences.order([pop], 1), isEmpty);
      await GenreFit.setEnabled(true);
      expect(preferences.order([pop], 1), isEmpty);
    });

    test("an answer saved after the switch goes off and on again still counts", () async {
      final pool = [
        for (var i = 0; i < 8; i++) _track("song$i", ["Rock"]),
      ];
      Future<List<String>> check() async => (await http.runWithClient(
        () => GenreFit.filter(pool, name: "Rock", tags: {"Rock"}, keepAtLeast: 1),
        () => MockClient(
          (request) async => http.Response(
            jsonEncode({
              "scores": {for (var i = 0; i < 8; i++) "song$i": 0.3},
            }),
            200,
          ),
        ),
      )).map((track) => track.id.raw).toList();

      final saved = Completer<void>();
      final requested = Completer<void>();
      final teaching = http.runWithClient(
        () => GenreFit.teach("song3", "Rock", false),
        () => MockClient((request) async {
          requested.complete();
          await saved.future;
          return http.Response(jsonEncode({"ok": true}), 200);
        }),
      );
      await requested.future;
      await GenreFit.setEnabled(false);
      await GenreFit.setEnabled(true);
      expect(await check(), contains("song3"));
      saved.complete();
      await teaching;
      expect(await check(), isNot(contains("song3")));
    });

    test("answers about the same song are saved in the order given, so a slow one can't undo a newer one", () async {
      final sent = <bool?>[];
      final firstSaved = Completer<void>();
      final client = MockClient((request) async {
        final fits = (jsonDecode(request.body) as Map<String, dynamic>)["fits"] as bool?;
        sent.add(fits);
        if (fits ?? false) await firstSaved.future;
        return http.Response(jsonEncode({"ok": true}), 200);
      });
      final first = http.runWithClient(() => GenreFit.teach("song3", "Rock", true), () => client);
      final second = http.runWithClient(() => GenreFit.teach("song3", "rock", false), () => client);
      await Future<void>.delayed(Duration.zero);
      expect(sent, [true]);
      firstSaved.complete();
      await Future.wait([first, second]);
      expect(sent, [true, false]);
      expect(GenreFit.saidToBe("Rock", "song3"), isFalse);
      final kept = await http.runWithClient(
        () => GenreFit.filter(
          [
            for (var i = 0; i < 8; i++) _track("song$i", ["Rock"]),
          ],
          name: "Rock",
          tags: {"Rock"},
          keepAtLeast: 100,
        ),
        () => MockClient((request) async => http.Response(jsonEncode({"scores": <String, double>{}}), 200)),
      );
      expect(kept.map((track) => track.id.raw), isNot(contains("song3")));
    });

    test("offline, the analyzer isn't asked and genres go by tags", () async {
      final directory = await Directory.systemTemp.createTemp("finamp-genre-fit-");
      addTearDown(() async {
        await Hive.close();
        await directory.delete(recursive: true);
      });
      Hive.init(directory.path);
      if (!Hive.isAdapterRegistered(FinampSettingsAdapter().typeId)) {
        Hive.registerAdapters();
        Hive.registerAdapter(ThemeModeAdapter());
        Hive.registerAdapter(ColorAdapter());
        Hive.registerAdapter(LocaleAdapter());
      }
      final box = await Hive.openBox<FinampSettings>("FinampSettings");
      await box.put(
        "FinampSettings",
        FinampSettings(
          downloadLocations: [],
          downloadLocationsMap: {},
          tabSortBy: {},
          tabSortOrder: {},
          homeScreenConfiguration: const FinampHomeScreenConfiguration(actions: [], sections: []),
          gridImageSize: 130,
          homeScreenImageSize: 90,
          deviceId: "test",
          isOffline: true,
        ),
      );
      final pool = [
        for (var i = 0; i < 8; i++) _track("song$i", ["Rock"]),
        _track("side", ["Pop", "Rock"]),
      ];
      final client = MockClient((request) async => fail("Offline, nothing is asked: ${request.url}"));
      final kept = await http.runWithClient(
        () => GenreFit.filter(pool, name: "Rock", tags: {"Rock"}, keepAtLeast: 1),
        () => client,
      );
      expect(kept.map((track) => track.id.raw), [for (var i = 0; i < 8; i++) "song$i"]);
      expect(await http.runWithClient(() => GenreFit.answeredFits("Rock"), () => client), isEmpty);
    });

    test("answered songs are only fetched from the library playing", () async {
      final api = _RecordingApi();
      final library = BaseItemDto(id: BaseItemId("library"));
      await http.runWithClient(
        () => const RadioPreferences(genres: ["Rock"]).answeredSongs(api, library: library),
        () => MockClient((request) async => http.Response(jsonEncode({"pop": true}), 200)),
      );
      final call = api.calls.single;
      expect(call.memberName, #getItems);
      expect(call.namedArguments[#parentItem], library);
      expect(call.namedArguments[#recursive], isTrue);
      expect(call.namedArguments[#itemIds], [BaseItemId("pop")]);
    });

    test("favourites-only Radio also takes favourites said to be its genres", () async {
      final api = _RecordingApi(
        genres: [BaseItemDto(id: BaseItemId("rock"), name: "Rock")],
      );
      await http.runWithClient(
        () => const RadioPreferences(
          genres: ["Rock"],
        ).libraryTracks(api, BaseItemDto(id: BaseItemId("library")), 10, favoritesOnly: true),
        () => MockClient((request) async => http.Response(jsonEncode({"pop": true}), 200)),
      );
      final answered = api.calls.where((call) => call.namedArguments[#itemIds] != null).single;
      expect(answered.namedArguments[#itemIds], [BaseItemId("pop")]);
      expect(answered.namedArguments[#isFavorite], isTrue);
    });

    test("a single answered favourite among many answered songs is found", () async {
      final api = _FavoritesApi({"song999"});
      final found = await GenreMix.answeredSongs(
        api,
        [for (var i = 0; i < 1000; i++) "song$i"],
        library: BaseItemDto(id: BaseItemId("library")),
        count: 25,
        favoritesOnly: true,
      );
      expect(found.map((song) => song.id.raw), ["song999"]);
      expect(api.requests, 5);
      // Without the favourites filter, the first 200 are plenty.
      api.requests = 0;
      final any = await GenreMix.answeredSongs(
        api,
        [for (var i = 0; i < 1000; i++) "song$i"],
        library: BaseItemDto(id: BaseItemId("library")),
        count: 25,
      );
      expect(any, hasLength(25));
      expect(api.requests, 1);
    });

    test("an answer waiting its turn when the analyzer changes isn't saved to the new one", () async {
      final saved = Completer<void>();
      final requested = Completer<void>();
      final sent = <String>[];
      final client = MockClient((request) async {
        sent.add(request.url.host);
        if (!requested.isCompleted) {
          requested.complete();
          await saved.future;
        }
        return http.Response(jsonEncode({"ok": true}), 200);
      });
      final first = http.runWithClient(() => GenreFit.teach("song1", "Rock", false), () => client);
      await requested.future;
      final second = http.runWithClient(() => GenreFit.teach("song1", "Rock", true), () => client);
      await AnalyzerService.saveSettings(url: "http://other-analyzer.test", token: "t");
      await Future<void>.delayed(Duration.zero);
      saved.complete();
      await first;
      await expectLater(second, throwsStateError);
      expect(sent, ["analyzer.test"]);
    });

    test("answered songs are picked at random, whatever order the server sends them in", () async {
      final api = _FavoritesApi({}, sorted: true);
      final picked = <String>{};
      for (var i = 0; i < 5; i++) {
        picked.addAll(
          (await GenreMix.answeredSongs(
            api,
            [for (var i = 0; i < 100; i++) "song$i"],
            library: BaseItemDto(id: BaseItemId("library")),
            count: 25,
          )).map((song) => song.id.raw),
        );
      }
      expect(picked.length, greaterThan(25));
    });

    test("an analyzer that can't be reached isn't asked again for a while", () async {
      final pool = [
        for (var i = 0; i < 8; i++) _track("song$i", ["Rock"]),
      ];
      var requests = 0;
      final down = MockClient((request) async {
        requests++;
        throw http.ClientException("down");
      });
      await http.runWithClient(() => GenreFit.filter(pool, name: "Rock", tags: {"Rock"}, keepAtLeast: 1), () => down);
      expect(requests, 1);
      final again = await http.runWithClient(() async {
        await GenreFit.answeredFits("Rock");
        return GenreFit.filter(pool, name: "Rock", tags: {"Rock"}, keepAtLeast: 1);
      }, () => down);
      expect(requests, 1);
      expect(again, hasLength(8));
    });

    test("a song said not to fit stays out while the analyzer can't be reached", () async {
      final pool = [
        for (var i = 0; i < 8; i++) _track("song$i", ["Rock"]),
      ];
      await http.runWithClient(
        () => GenreFit.teach("song0", "Rock", false),
        () => MockClient((request) async => http.Response(jsonEncode({"ok": true}), 200)),
      );
      final down = MockClient((request) async => throw http.ClientException("down"));
      for (var i = 0; i < 2; i++) {
        // The first check fails, and the second isn't sent at all.
        final kept = await http.runWithClient(
          () => GenreFit.filter(pool, name: "Rock", tags: {"Rock"}, keepAtLeast: 1),
          () => down,
        );
        expect(kept.map((track) => track.id.raw), isNot(contains("song0")));
      }
    });

    test("a sound check still out when an answer is given isn't kept, so the next one learns from it", () async {
      final pool = [
        for (var i = 0; i < 8; i++) _track("song$i", ["Rock"]),
      ];
      final reply = Completer<void>();
      final requested = Completer<void>();
      var checks = 0;
      final client = MockClient((request) async {
        if (request.url.path != "/genre-fit") return http.Response(jsonEncode({"ok": true}), 200);
        checks++;
        if (!requested.isCompleted) {
          requested.complete();
          await reply.future;
        }
        return http.Response(
          jsonEncode({
            "scores": {for (var i = 0; i < 8; i++) "song$i": 0.3},
          }),
          200,
        );
      });
      final first = http.runWithClient(
        () => GenreFit.filter(pool, name: "Rock", tags: {"Rock"}, keepAtLeast: 1),
        () => client,
      );
      await requested.future;
      await http.runWithClient(() => GenreFit.teach("song0", "Rock", false), () => client);
      reply.complete();
      await first;
      final again = await http.runWithClient(
        () => GenreFit.filter(pool, name: "Rock", tags: {"Rock"}, keepAtLeast: 1),
        () => client,
      );
      expect(checks, 2);
      expect(again.map((track) => track.id.raw), isNot(contains("song0")));
    });

    test("a new analyzer's answers count straight away, and a save to the old one doesn't", () async {
      final pool = [
        for (var i = 0; i < 8; i++) _track("song$i", ["Rock"]),
      ];
      var requests = 0;
      Future<List<String>> check(Map<String, bool> labels) async => (await http.runWithClient(
        () => GenreFit.filter(pool, name: "Rock", tags: {"Rock"}, keepAtLeast: 1),
        () => MockClient((request) async {
          requests++;
          return http.Response(
            jsonEncode({
              "scores": {for (var i = 0; i < 8; i++) "song$i": 0.3},
              "labels": labels,
            }),
            200,
          );
        }),
      )).map((track) => track.id.raw).toList();

      expect(await check({"song0": false}), isNot(contains("song0")));
      // A save still going to the old analyzer when it's replaced.
      final saved = Completer<void>();
      final requested = Completer<void>();
      final teaching = http.runWithClient(
        () => GenreFit.teach("song1", "Rock", false),
        () => MockClient((request) async {
          requested.complete();
          await saved.future;
          return http.Response(jsonEncode({"ok": true}), 200);
        }),
      );
      await requested.future;
      await AnalyzerService.saveSettings(url: "http://other-analyzer.test", token: "t");
      await Future<void>.delayed(Duration.zero);
      saved.complete();
      await teaching;
      final kept = await check({});
      expect(requests, 2);
      expect(kept, containsAll(["song0", "song1"]));
    });

    test("the genre editor also lists answers for genres that aren't choices, like Radio's picks", () {
      expect(GenreAnswersDialog.genresToShow(choices: ["Pop", "Rock"], answered: ["pop | rock", "rock"]), [
        "pop | rock",
        "Pop",
        "Rock",
      ]);
      expect(GenreAnswersDialog.genresToShow(choices: ["Pop", "Rock"], answered: ["pop | rock"], search: "pop and"), [
        "pop | rock",
      ]);
    });
  });
}
