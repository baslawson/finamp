import 'dart:async';
import 'dart:convert';

import 'package:finamp/models/jellyfin_models.dart';
import 'package:fake_async/fake_async.dart';
import 'package:finamp/services/genre_editor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

/// Storage that can't be read.
base class _Unreadable extends InMemorySharedPreferencesAsync {
  _Unreadable() : super.empty();

  @override
  Future<String?> getString(String key, SharedPreferencesOptions options) => Future.error(StateError("unreadable"));
}

/// Storage that takes [writes] writes, then no more.
base class _Filling extends InMemorySharedPreferencesAsync {
  _Filling(this.writes) : super.empty();

  int writes;

  Future<bool> _write(Future<bool> Function() write) => writes-- > 0 ? write() : Future.error(StateError("full"));

  @override
  Future<bool> setString(String key, String value, SharedPreferencesOptions options) =>
      _write(() => super.setString(key, value, options));

  @override
  Future<bool> clear(ClearPreferencesParameters parameters, SharedPreferencesOptions options) =>
      _write(() => super.clear(parameters, options));
}

void main() {
  late Map<String, Map<String, dynamic>> items;
  late List<http.Request> requests;
  late int Function(String id) refuse;
  late Map<String, int> attempts;
  late bool Function(String id) answerLost;
  late Duration Function(String id) slow;
  late Duration Function(String id) slowRead;
  late List<String> albumSongs;
  late bool Function(String id, int read) failRead;
  late Map<String, int> reads;
  late Map<String, dynamic> policy;
  late List<Map<String, dynamic>> folders;

  Map<String, dynamic> song(String id, List<String> genres) => {
    "Id": id,
    "Name": "Song $id",
    "Type": "Audio",
    "Genres": genres,
    "GenreItems": [
      for (final genre in genres) {"Name": genre, "Id": "g-$genre"},
    ],
    "People": [
      {"Name": "Someone", "Type": "Composer"},
    ],
    "Tags": ["live"],
    "Artists": ["Bob"],
    "ArtistItems": [
      {"Name": "Bob", "Id": "a-bob"},
    ],
    "AlbumArtist": "Bob",
    "AlbumArtists": [
      {"Name": "Bob", "Id": "a-bob"},
    ],
    "ProviderIds": {"MusicBrainzTrack": "mb-$id"},
    "Overview": "Kept as it is",
    "LockedFields": ["Name"],
  };

  setUp(() {
    items = {
      "album": song("album", ["Rock"])..["Type"] = "MusicAlbum",
      "s1": song("s1", ["Rock", "Pop"]),
      "s2": song("s2", ["Reggae"]),
    };
    requests = [];
    refuse = (_) => 0;
    attempts = {};
    answerLost = (_) => false;
    slow = (_) => Duration.zero;
    slowRead = (_) => Duration.zero;
    albumSongs = ["s1", "s2"];
    failRead = (_, _) => false;
    reads = {};
    folders = [];
    policy = {
      "MaxParentalRating": null,
      "BlockedTags": <String>[],
      "AllowedTags": <String>[],
      "BlockUnratedItems": <String>[],
    };
    GenreEditor.edited.value = const {};
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    GenreEditor.account = () =>
        (baseUrl: "https://jf.example/jellyfin", serverId: "srv1", userId: "u1", auth: "MediaBrowser Token=t");
    GenreEditor.client = () => MockClient((request) async {
      requests.add(request);
      final path = request.url.path;
      if (request.method == "GET" && path == "/jellyfin/Items") {
        return http.Response(
          jsonEncode({
            "Items": [
              for (final id in albumSongs)
                {
                  "Id": id,
                  "Type": "Audio",
                  "OfficialRating": items[id]!["OfficialRating"],
                  "CustomRating": items[id]!["CustomRating"],
                },
              // Right under it, songs or not.
              if (request.url.queryParameters["IncludeItemTypes"] != "Audio") ...folders,
            ],
          }),
          200,
        );
      }
      final id = request.url.pathSegments.last;
      if (request.method == "GET" && path.startsWith("/jellyfin/MusicGenres/")) {
        return http.Response(jsonEncode({"Id": "mg-${request.url.pathSegments.last}"}), 200);
      }
      if (request.method == "GET" && path == "/jellyfin/Users/u1") {
        return http.Response(jsonEncode({"Id": "u1", "Policy": policy}), 200);
      }
      if (request.method == "GET" && path == "/jellyfin/Users/u1/Items/$id") {
        reads[id] = (reads[id] ?? 0) + 1;
        final fails = failRead(id, reads[id]!);
        final body = jsonEncode(items[id]);
        await Future<void>.delayed(slowRead(id));
        return fails ? http.Response("", 503) : http.Response(body, 200);
      }
      if (request.method == "POST" && path == "/jellyfin/Items/$id") {
        attempts[id] = (attempts[id] ?? 0) + 1;
        await Future<void>.delayed(slow(id));
        if (refuse(id) != 0) return http.Response("", refuse(id));
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        // As Jellyfin does: credits not sent stay as they are.
        if (!body.containsKey("People")) body["People"] = items[id]!["People"];
        items[id] = body;
        // As Jellyfin does: an album's rating goes to its songs when the album is saved.
        if (id == "album") {
          for (final song in albumSongs) {
            items[song]!["OfficialRating"] = items["album"]!["OfficialRating"];
          }
        }
        return http.Response("", answerLost(id) ? 504 : 204);
      }
      return http.Response("", 404);
    });
  });

  test("only the genres change, and they're locked against rescans", () async {
    final before = jsonDecode(jsonEncode(items["s1"])) as Map<String, dynamic>;
    expect(await GenreEditor.save(["s1"], ["Ska", "Reggae"]), ["s1"]);
    final after = items["s1"]!;
    expect(after["Genres"], ["Ska", "Reggae"]);
    expect(after["LockedFields"], ["Name", "Genres"]);
    for (final field in before.keys.where((field) => field != "Genres" && field != "LockedFields")) {
      expect(after[field], before[field], reason: field);
    }
    final post = requests.singleWhere((request) => request.method == "POST");
    expect(post.headers["Authorization"], "MediaBrowser Token=t");
    expect(post.headers["Content-Type"], startsWith("application/json"));
  });

  test("an album's songs are found, and all get the genres", () async {
    final songs = await GenreEditor.songsOf("album");
    expect(songs, ["s1", "s2"]);
    expect(requests.single.url.queryParameters, containsPair("ParentId", "album"));
    expect(await GenreEditor.save(["album", ...songs], ["Dub"]), ["album", "s1", "s2"]);
    expect(
      [
        for (final id in ["album", "s1", "s2"]) items[id]!["Genres"],
      ],
      [
        ["Dub"],
        ["Dub"],
        ["Dub"],
      ],
    );
  });

  test("what an album save passes on to its songs is put back", () async {
    items["album"]!["OfficialRating"] = null;
    items["s1"]!["OfficialRating"] = "Explicit";
    await GenreEditor.save(["album", "s1", "s2"], ["Dub"]);
    expect(items["s1"]!["OfficialRating"], "Explicit");
  });

  test("a song added to the album since the dialog opened is saved too, with its own rating", () async {
    items["album"]!["OfficialRating"] = null;
    items["s3"] = song("s3", ["Pop"])..["OfficialRating"] = "Explicit";
    albumSongs = ["s1", "s2", "s3"];
    expect(await GenreEditor.save(["album", "s1", "s2"], ["Dub"], album: true), ["album", "s1", "s2", "s3"]);
    expect(items["s3"]!["Genres"], ["Dub"]);
    expect(items["s3"]!["OfficialRating"], "Explicit");
  });

  test("a song added to the album while the others are fetched keeps its rating", () async {
    items["album"]!["OfficialRating"] = null;
    slowRead = (id) {
      // A library scan adds it.
      if (id == "s2" && !albumSongs.contains("s3")) {
        items["s3"] = song("s3", ["Pop"])..["OfficialRating"] = "Explicit";
        albumSongs = [...albumSongs, "s3"];
      }
      return Duration.zero;
    };
    expect(await GenreEditor.save(["album", "s1", "s2"], ["Dub"], album: true), ["album", "s1", "s2", "s3"]);
    expect(items["s3"]!["OfficialRating"], "Explicit");
  });

  test("a song gone from the album while the others are fetched isn't saved", () async {
    items["album"]!["OfficialRating"] = null;
    items["s2"]!["OfficialRating"] = "PG";
    items["s3"] = song("s3", ["Pop"])..["OfficialRating"] = "Explicit";
    albumSongs = ["s1", "s2", "s3"];
    slowRead = (id) {
      // Deleted once fetched.
      if (id == "s2") albumSongs = ["s1", "s3"];
      return Duration.zero;
    };
    expect(await GenreEditor.save(["album", "s1", "s2", "s3"], ["Dub"], album: true), ["album", "s1", "s3"]);
    expect(attempts.keys, isNot(contains("s2")));
    expect(items["s3"]!["Genres"], ["Dub"]);
    expect(items["s3"]!["OfficialRating"], "Explicit");
    expect((await GenreEditor.keptRatings()).keys, isEmpty);
  });

  test("an album that couldn't be read again to save it keeps nothing", () async {
    items["album"]!["OfficialRating"] = null;
    failRead = (id, read) => id == "album" && read == 2;
    await expectLater(GenreEditor.save(["album", "s1", "s2"], ["Dub"]), throwsA(isA<GenreEditException>()));
    expect(attempts, isEmpty);
    expect(await GenreEditor.keptRatings(), isEmpty);
  });

  test("an album whose rating changes in Jellyfin before it's saved: its songs keep their own", () async {
    items["album"]!["OfficialRating"] = "PG";
    items["s1"]!["OfficialRating"] = "Explicit";
    slowRead = (id) {
      // Fetched already, then rated again elsewhere.
      if (id == "s2") items["album"]!["OfficialRating"] = "G";
      return Duration.zero;
    };
    await GenreEditor.save(["album", "s1", "s2"], ["Dub"]);
    expect(items["album"]!["OfficialRating"], "G");
    expect(items["s1"]!["OfficialRating"], "Explicit");
    expect(items["s2"]!["OfficialRating"], null);
  });

  test("a song rated again in Jellyfin while an album's songs are fetched keeps that rating", () async {
    items["album"]!["OfficialRating"] = "PG";
    items["s1"]!["OfficialRating"] = "Explicit";
    slowRead = (id) {
      // Once, as the songs are first fetched.
      if (id == "s2" && reads["s2"] == 1) items["s1"]!["OfficialRating"] = "G";
      return Duration.zero;
    };
    await GenreEditor.save(["album", "s1", "s2"], ["Dub"], album: true);
    expect(items["s1"]!["OfficialRating"], "G");
    final lookups = requests.where(
      (request) => request.url.path == "/jellyfin/Items" && request.url.queryParameters["IncludeItemTypes"] == "Audio",
    );
    expect(lookups.last.url.queryParameters["Fields"], "CustomRating");
  });

  test("kept ratings that can't be read stop the save", () async {
    SharedPreferencesAsyncPlatform.instance = _Unreadable();
    await expectLater(
      GenreEditor.save(["album", "s1", "s2"], ["Dub"]),
      throwsA(isA<GenreEditException>().having((e) => e.saved, "saved", 0)),
    );
    expect(requests, isEmpty);
  });

  test("kept ratings that can't be updated afterwards: what was saved still shows as saved", () async {
    // The one before the album is sent, not those after.
    SharedPreferencesAsyncPlatform.instance = _Filling(1);
    await expectLater(
      GenreEditor.save(["album", "s1", "s2"], ["Dub"]),
      throwsA(isA<GenreEditException>().having((e) => e.savedIds, "savedIds", ["album", "s1", "s2"])),
    );
    // Each read to fetch it and again to send it, not a third time to tell if it was saved.
    expect(reads["s1"], 2);
  });

  test("a song saved is kept no more at once, not only once the album's songs are done", () async {
    Map<String, Map<String, dynamic>>? whileS2Saved;
    refuse = (id) {
      if (id == "s2") GenreEditor.keptRatings().then((kept) => whileS2Saved = kept);
      return 0;
    };
    slow = (id) => id == "s2" ? const Duration(milliseconds: 20) : Duration.zero;
    await GenreEditor.save(["album", "s1", "s2"], ["Dub"]);
    expect(whileS2Saved!.keys, ["s2"]);
  });

  test("a song saved with its answer lost is kept no more at once", () async {
    Map<String, Map<String, dynamic>>? whileS2Saved;
    answerLost = (id) => id == "s1";
    refuse = (id) {
      if (id == "s2") GenreEditor.keptRatings().then((kept) => whileS2Saved = kept);
      return 0;
    };
    slow = (id) => id == "s2" ? const Duration(milliseconds: 20) : Duration.zero;
    await GenreEditor.save(["album", "s1", "s2"], ["Dub"]);
    expect(whileS2Saved!.keys, ["s2"]);
  });

  test("kept ratings spoiled for good don't stop saves", () async {
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.withData({
      "genreEditorKeptRatings srv1": "not json",
    });
    expect(await GenreEditor.save(["s1"], ["Dub"]), ["s1"]);
  });

  test("an album isn't saved by an account parental controls hide songs from", () async {
    for (final (field, value) in [
      ("MaxParentalRating", 10),
      ("BlockedTags", ["explicit"]),
      ("AllowedTags", ["kids"]),
      ("BlockUnratedItems", ["Audio"]),
    ]) {
      policy = {
        "MaxParentalRating": null,
        "BlockedTags": <String>[],
        "AllowedTags": <String>[],
        "BlockUnratedItems": <String>[],
        field: value,
      };
      await expectLater(
        GenreEditor.save(["album", "s1", "s2"], ["Dub"], album: true),
        throwsA(isA<GenreEditException>().having((e) => e.reason, "reason", contains("Parental controls"))),
        reason: field,
      );
    }
    expect(attempts, isEmpty);
    // A song alone is.
    expect(await GenreEditor.save(["s1"], ["Dub"]), ["s1"]);
  });

  test("an album artist Jellyfin has under another case isn't added twice", () async {
    items["s1"]!
      ..["AlbumArtist"] = "BOB"
      ..["AlbumArtists"] = [
        {"Name": "Bob", "Id": "a-bob"},
      ];
    await GenreEditor.save(["s1"], ["Dub"]);
    expect(items["s1"]!["AlbumArtists"], [
      {"Name": "Bob", "Id": "a-bob"},
    ]);
  });

  test("a song's artists not found in the library yet aren't lost", () async {
    items["s1"]!
      ..["Artists"] = ["Bob", "New Band"]
      ..["ArtistItems"] = [
        {"Name": "Bob", "Id": "a-bob"},
      ]
      ..["AlbumArtist"] = "New Band"
      ..["AlbumArtists"] = <Map<String, dynamic>>[];
    await GenreEditor.save(["s1"], ["Dub"]);
    expect(items["s1"]!["ArtistItems"], [
      {"Name": "Bob", "Id": "a-bob"},
      {"Name": "New Band"},
    ]);
    expect(items["s1"]!["AlbumArtists"], [
      {"Name": "New Band"},
    ]);
  });

  test("an album with a disc folder rated otherwise isn't saved", () async {
    items["album"]!["OfficialRating"] = "PG";
    folders = [
      {"Id": "cd1", "Type": "Folder", "OfficialRating": "PG", "CustomRating": null},
      {"Id": "cd2", "Type": "Folder", "OfficialRating": null, "CustomRating": null},
    ];
    await expectLater(
      GenreEditor.save(["album", "s1", "s2"], ["Dub"], album: true),
      throwsA(isA<GenreEditException>().having((e) => e.reason, "reason", contains("folders"))),
    );
    expect(attempts, isEmpty);
    // Rated as the album, it's saved.
    folders = [folders.first];
    expect(await GenreEditor.save(["album", "s1", "s2"], ["Dub"], album: true), ["album", "s1", "s2"]);
  });

  test("an album whose rating changes before it's sent isn't saved over a folder rated as it was", () async {
    items["album"]!["OfficialRating"] = "PG";
    folders = [
      {"Id": "cd1", "Type": "Folder", "OfficialRating": "PG", "CustomRating": null},
    ];
    slowRead = (id) {
      // Rated again by a scan once fetched.
      if (id == "s2" && reads["s2"] == 1) items["album"]!["OfficialRating"] = "G";
      return Duration.zero;
    };
    await expectLater(
      GenreEditor.save(["album", "s1", "s2"], ["Dub"], album: true),
      throwsA(isA<GenreEditException>().having((e) => e.reason, "reason", contains("folders"))),
    );
    expect(attempts, isEmpty);
    expect(await GenreEditor.keptRatings(), isEmpty);
  });

  test("a song saved alone with its answer lost counts as saved, its kept rating put back", () async {
    items["album"]!["OfficialRating"] = null;
    items["s1"]!["OfficialRating"] = "Explicit";
    refuse = (id) => id == "s1" ? 500 : 0;
    await expectLater(GenreEditor.save(["album", "s1", "s2"], ["Dub"]), throwsA(isA<GenreEditException>()));
    expect((await GenreEditor.keptRatings()).keys, ["s1"]);
    refuse = (_) => 0;
    answerLost = (id) => id == "s1";
    expect(await GenreEditor.save(["s1"], ["Dub"]), ["s1"]);
    expect(items["s1"]!["OfficialRating"], "Explicit");
    expect(await GenreEditor.keptRatings(), isEmpty);
  });

  /// Saves the album and its songs on a server [slow] to save and [slowRead] to read, waiting as long as it takes.
  Object? saveAlbumOnSlowServer() {
    Object? result;
    fakeAsync((async) {
      GenreEditor.save(
        ["album", "s1", "s2"],
        ["Dub"],
        album: true,
      ).then<void>((saved) => result = saved, onError: (Object e) => result = e);
      async.elapse(const Duration(minutes: 10));
    });
    return result;
  }

  test("a busy server slow to save and to read (as one seen at 20s and more) is waited for", () {
    slow = (id) => id == "album" ? const Duration(seconds: 85) : const Duration(seconds: 30);
    slowRead = (_) => const Duration(seconds: 55);
    expect(saveAlbumOnSlowServer(), ["album", "s1", "s2"]);
    expect(items["s2"]!["Genres"], ["Dub"]);
  });

  test("an album save not answered in 90 seconds is taken for lost", () {
    slow = (id) => id == "album" ? const Duration(seconds: 95) : Duration.zero;
    expect(saveAlbumOnSlowServer(), isA<GenreEditException>().having((e) => e.saved, "saved", 0));
    expect(items["s1"]!["Genres"], ["Rock", "Pop"]);
  });

  test("a read not answered in a minute fails the save before anything is sent", () {
    slowRead = (_) => const Duration(seconds: 65);
    expect(saveAlbumOnSlowServer(), isA<GenreEditException>().having((e) => e.saved, "saved", 0));
    expect(attempts, isEmpty);
  });

  test("credits aren't sent, so they stay as they are, their order too", () async {
    await GenreEditor.save(["s1"], ["Dub"]);
    final post = requests.singleWhere((request) => request.method == "POST");
    expect((jsonDecode(post.body) as Map<String, dynamic>).containsKey("People"), isFalse);
  });

  test("an album with a disc folder whose own rating is locked is saved", () async {
    items["album"]!["OfficialRating"] = "PG";
    folders = [
      {
        "Id": "cd1",
        "Type": "Folder",
        "OfficialRating": "R",
        "CustomRating": null,
        "LockedFields": ["OfficialRating"],
      },
    ];
    expect(await GenreEditor.save(["album", "s1", "s2"], ["Dub"], album: true), ["album", "s1", "s2"]);
    expect(
      requests.firstWhere((request) => request.url.queryParameters["Fields"]?.contains("Settings") ?? false),
      isNotNull,
    );
  });

  test("an album sent as it already was, its answer lost, isn't taken for saved", () async {
    items["album"]!
      ..["Genres"] = ["Dub"]
      ..["LockedFields"] = ["Genres"];
    items["album"]!["OfficialRating"] = null;
    items["s1"]!["OfficialRating"] = "Explicit";
    answerLost = (id) => id == "album";
    await expectLater(
      GenreEditor.save(["album", "s1", "s2"], ["Dub"]),
      throwsA(isA<GenreEditException>().having((e) => e.saved, "saved", 0)),
    );
    expect((await GenreEditor.keptRatings()).keys, ["s1", "s2"]);
  });

  test("a song rated again twice while its album saves keeps the newest", () async {
    items["album"]!["OfficialRating"] = "PG";
    items["s1"]!["OfficialRating"] = "Explicit";
    slowRead = (id) {
      // Rated G once fetched, as the last look at the album's songs sees.
      if (id == "s2" && reads["s2"] == 1) items["s1"]!["OfficialRating"] = "G";
      return Duration.zero;
    };
    failRead = (id, read) {
      // And Explicit again, after the album passed its rating on.
      if (id == "s1" && read == 2) items["s1"]!["OfficialRating"] = "Explicit";
      return false;
    };
    await GenreEditor.save(["album", "s1", "s2"], ["Dub"], album: true);
    expect(items["s1"]!["OfficialRating"], "Explicit");
  });

  test("what changes in Jellyfin while an album saves stays", () async {
    items["album"]!["OfficialRating"] = null;
    items["s2"]!["OfficialRating"] = "Explicit";
    refuse = (id) {
      // Fetched already, then renamed elsewhere.
      if (id == "album") items["s2"]!["Name"] = "Renamed";
      return 0;
    };
    await GenreEditor.save(["album", "s1", "s2"], ["Dub"]);
    expect(items["s2"]!["Name"], "Renamed");
    expect(items["s2"]!["Genres"], ["Dub"]);
    expect(items["s2"]!["OfficialRating"], "Explicit");
  });

  test("a save waiting its turn stays with the account it was made on", () async {
    items["s3"] = song("s3", ["Pop"]);
    slow = (id) => id == "s3" ? const Duration(milliseconds: 50) : Duration.zero;
    final first = GenreEditor.save(["s3"], ["Ska"]);
    final second = GenreEditor.save(["s1"], ["Dub"]);
    GenreEditor.account = () =>
        (baseUrl: "https://other.example/jellyfin", serverId: "srv2", userId: "u1", auth: "MediaBrowser Token=o");
    await Future.wait([first, second]);
    final posts = requests.where((request) => request.method == "POST");
    expect({for (final post in posts) post.url.host}, {"jf.example"});
  });

  test("a genre already locked isn't locked twice", () async {
    items["s2"]!["LockedFields"] = ["Genres"];
    await GenreEditor.save(["s2"], ["Dub"]);
    expect(items["s2"]!["LockedFields"], ["Genres"]);
  });

  test("genres are tidied: trimmed, no blanks, each once", () {
    expect(GenreEditor.tidy([" Rock ", "", "rock", "Pop", "  "]), ["Rock", "Pop"]);
  });

  test("a refused song doesn't stop the rest, which keep their own rating", () async {
    items["album"]!["OfficialRating"] = null;
    items["s2"]!["OfficialRating"] = "Explicit";
    refuse = (id) => id == "s1" ? 403 : 0;
    await expectLater(
      GenreEditor.save(["album", "s1", "s2"], ["Dub"]),
      throwsA(
        isA<GenreEditException>()
            .having((e) => e.savedIds, "saved", ["album", "s2"])
            .having((e) => e.total, "total", 3)
            .having((e) => e.reason, "reason", contains("administrator")),
      ),
    );
    expect(items["s1"]!["Genres"], ["Rock", "Pop"]);
    expect(items["s2"]!["Genres"], ["Dub"]);
    expect(items["s2"]!["OfficialRating"], "Explicit");
    // Tried once more.
    expect(attempts["s1"], 2);
  });

  test("a song left unsaved after its album gets its own rating back when saved again", () async {
    items["album"]!["OfficialRating"] = null;
    items["s1"]!["OfficialRating"] = "Explicit";
    refuse = (id) => id == "s1" ? 500 : 0;
    await expectLater(GenreEditor.save(["album", "s1", "s2"], ["Dub"]), throwsA(isA<GenreEditException>()));
    // Jellyfin gave it the album's.
    expect(items["s1"]!["OfficialRating"], null);
    refuse = (_) => 0;
    expect(await GenreEditor.save(["s1"], ["Dub"]), ["s1"]);
    expect(items["s1"]!["OfficialRating"], "Explicit");
    expect(await GenreEditor.keptRatings(), isEmpty);
  });

  test("an album turned down keeps nothing, so a rating changed later in Jellyfin stays", () async {
    items["album"]!["OfficialRating"] = "PG";
    refuse = (id) => id == "album" ? 403 : 0;
    await expectLater(GenreEditor.save(["album", "s1", "s2"], ["Dub"]), throwsA(isA<GenreEditException>()));
    expect(await GenreEditor.keptRatings(), isEmpty);
    items["s1"]!["OfficialRating"] = "PG";
    refuse = (_) => 0;
    await GenreEditor.save(["s1"], ["Dub"]);
    expect(items["s1"]!["OfficialRating"], "PG");
  });

  test("a rating changed in Jellyfin since its album was saved isn't put back over", () async {
    items["album"]!["OfficialRating"] = "PG";
    items["s1"]!["OfficialRating"] = "Explicit";
    refuse = (id) => id == "s1" ? 500 : 0;
    await expectLater(GenreEditor.save(["album", "s1", "s2"], ["Dub"]), throwsA(isA<GenreEditException>()));
    items["s1"]!["OfficialRating"] = "G";
    refuse = (_) => 0;
    await GenreEditor.save(["s1"], ["Dub"]);
    expect(items["s1"]!["OfficialRating"], "G");
  });

  test("kept ratings outlast the app: kept before the album is saved", () async {
    items["album"]!["OfficialRating"] = null;
    items["s1"]!["OfficialRating"] = "Explicit";
    Map<String, Map<String, dynamic>>? whileAlbumSaved;
    refuse = (id) {
      if (id == "album") GenreEditor.keptRatings().then((kept) => whileAlbumSaved = kept);
      return id == "s1" ? 500 : 0;
    };
    await expectLater(GenreEditor.save(["album", "s1", "s2"], ["Dub"]), throwsA(isA<GenreEditException>()));
    expect(whileAlbumSaved!["s1"]!["OfficialRating"], {"before": "Explicit", "album": null});
    expect((await GenreEditor.keptRatings()).keys, ["s1"]);
  });

  test("saves at the same time don't lose each other's kept ratings", () async {
    items["album"]!["OfficialRating"] = null;
    items["s1"]!["OfficialRating"] = "Explicit";
    // Another song, slow to save: done last.
    items["s3"] = song("s3", ["Pop"]);
    slow = (id) => id == "s3" ? const Duration(milliseconds: 50) : Duration.zero;
    refuse = (id) => id == "s1" ? 500 : 0;
    await Future.wait([
      GenreEditor.save(["s3"], ["Ska"]),
      GenreEditor.save(["album", "s1", "s2"], ["Dub"]).then((_) {}, onError: (_) {}),
    ]);
    expect((await GenreEditor.keptRatings()).keys, ["s1"]);
  });

  test("an edit stays with its account when another signs in meanwhile", () async {
    refuse = (id) {
      if (id == "album") {
        GenreEditor.account = () =>
            (baseUrl: "https://other.example/jellyfin", serverId: "srv2", userId: "u1", auth: "MediaBrowser Token=o");
      }
      return 0;
    };
    await GenreEditor.save(["album", "s1", "s2"], ["Dub"]);
    final posts = requests.where((request) => request.method == "POST");
    expect({for (final post in posts) post.url.host}, {"jf.example"});
    expect({for (final post in posts) post.headers["Authorization"]}, {"MediaBrowser Token=t"});
  });

  test("kept ratings are for the server they came from", () async {
    refuse = (id) => id == "s1" ? 500 : 0;
    await expectLater(GenreEditor.save(["album", "s1", "s2"], ["Dub"]), throwsA(isA<GenreEditException>()));
    expect((await GenreEditor.keptRatings()).keys, ["s1"]);
    // The same server at another address.
    GenreEditor.account = () =>
        (baseUrl: "http://10.0.0.5:8096", serverId: "srv1", userId: "u1", auth: "MediaBrowser Token=t");
    expect((await GenreEditor.keptRatings()).keys, ["s1"]);
    // Another administrator there.
    GenreEditor.account = () =>
        (baseUrl: "https://jf.example/jellyfin", serverId: "srv1", userId: "u2", auth: "MediaBrowser Token=u");
    expect((await GenreEditor.keptRatings()).keys, ["s1"]);
    GenreEditor.account = () =>
        (baseUrl: "https://jf.example/jellyfin", serverId: "srv2", userId: "u1", auth: "MediaBrowser Token=o");
    expect(await GenreEditor.keptRatings(), isEmpty);
  });

  test("a song that had no rating has none again, not the album's", () async {
    items["album"]!["OfficialRating"] = "PG";
    refuse = (id) => id == "s1" ? 500 : 0;
    await expectLater(GenreEditor.save(["album", "s1", "s2"], ["Dub"]), throwsA(isA<GenreEditException>()));
    expect(items["s1"]!["OfficialRating"], "PG");
    refuse = (_) => 0;
    await GenreEditor.save(["s1"], ["Dub"]);
    expect(items["s1"]!["OfficialRating"], null);
  });

  test("an album saved with its answer lost: its songs get their own rating back when saved again", () async {
    items["album"]!["OfficialRating"] = null;
    items["s1"]!["OfficialRating"] = "Explicit";
    answerLost = (id) => id == "album";
    await expectLater(
      GenreEditor.save(["album", "s1", "s2"], ["Dub"]),
      throwsA(isA<GenreEditException>().having((e) => e.saved, "saved", 0)),
    );
    // Not even when it looks saved: Jellyfin may still be passing its rating on.
    expect(items["album"]!["Genres"], ["Dub"]);
    expect(attempts.keys, ["album"]);
    expect(items["s1"]!["OfficialRating"], null);
    answerLost = (_) => false;
    await GenreEditor.save(["album", "s1", "s2"], ["Dub"]);
    expect(items["s1"]!["OfficialRating"], "Explicit");
  });

  test("an album that had the genres already, unlocked, isn't taken for saved when it wasn't", () async {
    items["album"]!["Genres"] = ["Dub"];
    refuse = (id) => id == "album" ? 504 : 0;
    await expectLater(
      GenreEditor.save(["album", "s1", "s2"], ["Dub"]),
      throwsA(isA<GenreEditException>().having((e) => e.saved, "saved", 0)),
    );
  });

  test("a song saved with its answer lost counts as saved", () async {
    answerLost = (id) => id == "s1";
    expect(await GenreEditor.save(["album", "s1", "s2"], ["Dub"]), ["album", "s1", "s2"]);
    expect(attempts["s1"], 1);
    expect(await GenreEditor.keptRatings(), isEmpty);
  });

  test("a song with the genres already isn't taken for saved when its rating wasn't put back", () async {
    items["album"]!["OfficialRating"] = null;
    items["s1"]!
      ..["OfficialRating"] = "Explicit"
      ..["Genres"] = ["Dub"]
      ..["LockedFields"] = ["Genres"];
    refuse = (id) => id == "s1" ? 504 : 0;
    await expectLater(
      GenreEditor.save(["album", "s1", "s2"], ["Dub"]),
      throwsA(isA<GenreEditException>().having((e) => e.savedIds, "savedIds", ["album", "s2"])),
    );
    expect((await GenreEditor.keptRatings()).keys, ["s1"]);
  });

  test("an album not saved, though not turned down, saves none of its songs and keeps their ratings", () async {
    refuse = (id) => id == "album" ? 504 : 0;
    await expectLater(
      GenreEditor.save(["album", "s1", "s2"], ["Dub"]),
      throwsA(isA<GenreEditException>().having((e) => e.saved, "saved", 0)),
    );
    expect(attempts.keys, ["album"]);
    expect((await GenreEditor.keptRatings()).keys, ["s1", "s2"]);
  });

  test("a song refused once gets saved on the second try", () async {
    refuse = (id) => id == "s1" && attempts["s1"] == 1 ? 500 : 0;
    expect(await GenreEditor.save(["album", "s1", "s2"], ["Dub"]), ["album", "s2", "s1"]);
    expect(items["s1"]!["Genres"], ["Dub"]);
  });

  test("when the album isn't saved, its songs aren't touched", () async {
    refuse = (id) => id == "album" ? 403 : 0;
    await expectLater(
      GenreEditor.save(["album", "s1", "s2"], ["Dub"]),
      throwsA(isA<GenreEditException>().having((e) => e.saved, "saved", 0)),
    );
    expect(attempts.keys, ["album"]);
  });

  test("an old copy shows the saved genres for good, and later ones from Jellyfin", () {
    NameLongIdPair genre(String name) => NameLongIdPair(name: name, id: BaseItemId("g-$name"));
    final old = BaseItemDto(id: const BaseItemId("s1"), genreItems: [genre("Rock")]);
    final before = GenreEditor.asking;
    GenreEditor.remember(["s1"], [genre("Dub")]);
    expect(GenreEditor.genresShown(old)!.single.name, "Dub");
    // Asked for before the edit, and come after it: old news.
    GenreEditor.loaded([old], asked: before);
    expect(GenreEditor.genresShown(old)!.single.name, "Dub");
    // Loaded without its genres: no news.
    GenreEditor.loaded([BaseItemDto(id: const BaseItemId("s1"))], asked: GenreEditor.asking);
    expect(GenreEditor.genresShown(old)!.single.name, "Dub");
    // Changed in Jellyfin since, and loaded again.
    GenreEditor.loaded(asked: GenreEditor.asking, [
      BaseItemDto(id: const BaseItemId("s1"), genreItems: [genre("Ska")]),
      BaseItemDto(id: const BaseItemId("other"), genreItems: [genre("Pop")]),
    ]);
    expect(GenreEditor.genresShown(old)!.single.name, "Ska");
    // Items never edited are left to themselves.
    expect(GenreEditor.edited.value.keys, [const BaseItemId("s1")]);
  });

  test("genres read after a save don't replace those of a later save, read first", () async {
    var reads = 0;
    final firstRead = Completer<void>();
    slowRead = (_) {
      if (++reads > 1) return Duration.zero;
      firstRead.complete();
      return const Duration(milliseconds: 50);
    };
    final first = GenreEditor.showSaved(["s1"], GenreEditor.account(), genres: const []);
    // Read as it was; changed and saved again before that read is back.
    await firstRead.future;
    items["s1"] = song("s1", ["Ska"]);
    expect((await GenreEditor.showSaved(["s1"], GenreEditor.account(), genres: const []))!.single.name, "Ska");
    await first;
    expect(GenreEditor.genresShown(BaseItemDto(id: const BaseItemId("s1")))!.single.name, "Ska");
  });

  test("an answer slower than one asked for after it isn't shown over it", () {
    NameLongIdPair genre(String name) => NameLongIdPair(name: name, id: BaseItemId("g-$name"));
    GenreEditor.remember(["s1"], [genre("Dub")]);
    final first = GenreEditor.asking;
    final second = GenreEditor.asking;
    GenreEditor.loaded([
      BaseItemDto(id: const BaseItemId("s1"), genreItems: [genre("Ska")]),
    ], asked: second);
    GenreEditor.loaded([
      BaseItemDto(id: const BaseItemId("s1"), genreItems: [genre("Dub")]),
    ], asked: first);
    expect(GenreEditor.genresShown(BaseItemDto(id: const BaseItemId("s1")))!.single.name, "Ska");
  });

  test("saved genres that can't be read back show as saved, until they next load", () async {
    NameLongIdPair genre(String name) => NameLongIdPair(name: name, id: BaseItemId("g-$name"));
    failRead = (_, _) => true;
    final shown = await GenreEditor.showSaved(["s1", "s2"], GenreEditor.account(), genres: [genre("Dub")]);
    expect(shown!.single.name, "Dub");
    expect(GenreEditor.genresShown(BaseItemDto(id: const BaseItemId("s2")))!.single.name, "Dub");
    GenreEditor.loaded([
      BaseItemDto(id: const BaseItemId("s2"), genreItems: [genre("Ska")]),
    ], asked: GenreEditor.asking);
    expect(GenreEditor.genresShown(BaseItemDto(id: const BaseItemId("s2")))!.single.name, "Ska");
  });

  test("saved genres not read back don't replace those of a later edit", () async {
    NameLongIdPair genre(String name) => NameLongIdPair(name: name, id: BaseItemId("g-$name"));
    final readStarted = Completer<void>();
    failRead = (_, _) {
      readStarted.complete();
      return true;
    };
    slowRead = (_) => const Duration(milliseconds: 50);
    final first = GenreEditor.showSaved(["s1"], GenreEditor.account(), genres: [genre("Dub")]);
    await readStarted.future;
    GenreEditor.remember(["s1"], [genre("Ska")]);
    await first;
    expect(GenreEditor.genresShown(BaseItemDto(id: const BaseItemId("s1")))!.single.name, "Ska");
  });

  test("after a save, the others show the genres saved, with the ids Jellyfin has, not the first's", () async {
    NameLongIdPair genre(String name, [String? id]) => NameLongIdPair(name: name, id: BaseItemId(id ?? "g-$name"));
    // The album changed elsewhere since: it's Ska and Dub there now.
    items["album"] = song("album", ["Ska", "Dub"]);
    await GenreEditor.showSaved(["album", "s1"], GenreEditor.account(), genres: [genre("Dub", "")]);
    List<(String?, String)> shown(String id) => [
      for (final genre in GenreEditor.genresShown(BaseItemDto(id: BaseItemId(id)))!) (genre.name, genre.id.raw),
    ];
    expect(shown("album"), [("Ska", "g-Ska"), ("Dub", "g-Dub")]);
    expect(shown("s1"), [("Dub", "g-Dub")]);
    // Only the first read back.
    expect(requests.where((request) => request.url.path.contains("/Items/")), hasLength(1));
  });

  test("a slow read-back shows nothing of another server's edit made meanwhile", () async {
    NameLongIdPair genre(String name) => NameLongIdPair(name: name, id: BaseItemId("g-$name"));
    final here = GenreEditor.account();
    slowRead = (_) => const Duration(milliseconds: 50);
    final shown = GenreEditor.showSaved(["s1"], here, genres: [genre("Dub")]);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    GenreEditor.account = () =>
        (baseUrl: "https://other.example/jellyfin", serverId: "srv2", userId: "u1", auth: "MediaBrowser Token=o");
    GenreEditor.remember(["s1"], [genre("Polka")]);
    expect(await shown, isNull);
  });

  test("while the saved genres are read back, the saved ones show, not those of an old copy", () async {
    NameLongIdPair genre(String name) => NameLongIdPair(name: name, id: BaseItemId("g-$name"));
    final old = BaseItemDto(id: const BaseItemId("s1"), genreItems: [genre("Rock")]);
    GenreEditor.remember(["s1"], [genre("Dub")]);
    slowRead = (_) => const Duration(milliseconds: 50);
    final shown = GenreEditor.showSaved(["s1"], GenreEditor.account(), genres: [genre("Ska")]);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(GenreEditor.genresShown(old)!.single.name, "Ska");
    await shown;
  });

  test("a genre new to the library is made one, so its chip opens it", () async {
    NameLongIdPair genre(String name, String id) => NameLongIdPair(name: name, id: BaseItemId(id));
    failRead = (_, _) => true;
    final shown = await GenreEditor.showSaved(
      ["s1"],
      GenreEditor.account(),
      genres: [genre("Rock", "g-Rock"), genre("Hip Hop", "")],
    );
    expect([for (final genre in shown!) genre.id.raw], ["g-Rock", "mg-Hip Hop"]);
    expect([for (final request in requests) request.url.path], contains("/jellyfin/MusicGenres/Hip%20Hop"));
    expect(requests.where((request) => request.url.path.contains("MusicGenres/Rock")), isEmpty);
  });

  test("a save shows nothing once another account is signed in", () async {
    final here = GenreEditor.account();
    GenreEditor.account = () =>
        (baseUrl: "https://other.example/jellyfin", serverId: "srv2", userId: "u1", auth: "MediaBrowser Token=o");
    expect(await GenreEditor.showSaved(["s1"], here, genres: const []), isNull);
    expect(GenreEditor.edited.value, isEmpty);
    expect(requests, isEmpty);
  });

  test("a save's genres are read with the account that saved them", () async {
    final here = GenreEditor.account();
    // Signed in again with another token: the same server and account.
    GenreEditor.account = () =>
        (baseUrl: "https://jf.example/jellyfin", serverId: "srv1", userId: "u1", auth: "MediaBrowser Token=new");
    await GenreEditor.showSaved(["s1"], here, genres: const []);
    expect(requests.single.headers["Authorization"], "MediaBrowser Token=t");
  });

  test("edits are for the server they were made on", () {
    NameLongIdPair genre(String name) => NameLongIdPair(name: name, id: BaseItemId("g-$name"));
    final item = BaseItemDto(id: const BaseItemId("s1"), genreItems: [genre("Rock")]);
    GenreEditor.remember(["s1"], [genre("Dub")]);
    expect(GenreEditor.genresShown(item)!.single.name, "Dub");
    GenreEditor.account = () =>
        (baseUrl: "https://other.example", serverId: "srv2", userId: "u1", auth: "MediaBrowser Token=o");
    expect(GenreEditor.genresShown(item)!.single.name, "Rock");
    // And what loads there doesn't bring them back.
    GenreEditor.loaded([item], asked: GenreEditor.asking);
    expect(GenreEditor.edited.value, isEmpty);
  });

  test("what another server sends, after signing back in, isn't shown", () {
    NameLongIdPair genre(String name) => NameLongIdPair(name: name, id: BaseItemId("g-$name"));
    final here = GenreEditor.account;
    GenreEditor.remember(["s1"], [genre("Dub")]);
    // Asked there after the edit here, and back only once signed in here again.
    GenreEditor.account = () =>
        (baseUrl: "https://other.example", serverId: "srv2", userId: "u1", auth: "MediaBrowser Token=o");
    final there = GenreEditor.asking;
    GenreEditor.account = here;
    GenreEditor.loaded([
      BaseItemDto(id: const BaseItemId("s1"), genreItems: [genre("Polka")]),
    ], asked: there);
    expect(GenreEditor.genresShown(BaseItemDto(id: const BaseItemId("s1")))!.single.name, "Dub");
  });

  test("the genres of an item are read from Jellyfin", () async {
    expect(await GenreEditor.genresOf("s1"), ["Rock", "Pop"]);
  });
}
