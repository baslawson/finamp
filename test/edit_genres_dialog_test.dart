import 'dart:convert';

import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/components/PlayerScreen/genre_chip.dart';
import 'package:finamp/components/MusicScreen/music_screen_tab_view.dart';
import 'package:finamp/l10n/app_localizations.dart';
import 'package:finamp/menus/components/menuEntries/edit_genres_menu_entry.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/genre_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  late Map<String, List<String>> genres;
  late List<String> posted;
  late Set<String> refused;
  late List<String> albumSongs;
  late void Function(String id) onPost;
  late bool readsFail;

  setUp(() {
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    genres = {
      "album": ["Rock"],
      "s1": ["Rock", "Pop"],
      "s2": ["Reggae"],
    };
    posted = [];
    refused = {};
    albumSongs = ["s1", "s2"];
    onPost = (_) {};
    readsFail = false;
    GenreEditor.edited.value = const {};
    EditGenresDialog.libraryGenres = () async => [
      for (final genre in ["Reggae", "Rock", "Ska"]) NameLongIdPair(name: genre, id: BaseItemId("lib-$genre")),
    ];
    GenreEditor.account = () =>
        (baseUrl: "https://jf.example", serverId: "srv1", userId: "u1", auth: "MediaBrowser Token=t");
    GenreEditor.client = () => MockClient((request) async {
      final id = request.url.pathSegments.last;
      if (request.method == "GET" && request.url.path == "/Users/u1") {
        return http.Response(jsonEncode({"Id": "u1", "Policy": <String, dynamic>{}}), 200);
      }
      if (request.method == "GET" && request.url.path == "/Items") {
        return http.Response(
          jsonEncode({
            "Items": [
              for (final id in albumSongs) {"Id": id},
            ],
          }),
          200,
        );
      }
      if (request.method == "GET") {
        if (readsFail) return http.Response("", 503);
        if (request.url.pathSegments.contains("MusicGenres")) return http.Response(jsonEncode({"Id": "mg-$id"}), 200);
        return http.Response(
          jsonEncode({
            "Id": id,
            "Genres": genres[id],
            "GenreItems": [
              for (final genre in genres[id]!) {"Name": genre, "Id": "g-$genre"},
            ],
          }),
          200,
        );
      }
      if (refused.contains(id)) return http.Response("", 403);
      posted.add(id);
      onPost(id);
      genres[id] = [...(jsonDecode(request.body)["Genres"] as List).cast<String>()];
      return http.Response("", 204);
    });
  });

  Future<void> open(WidgetTester tester, BaseItemDto item) async {
    await tester.pumpWidget(
      MaterialApp(
        // ignore: deprecated_member_use_from_same_package
        scaffoldMessengerKey: GlobalSnackbar.rawMaterialAppScaffoldKey,
        navigatorKey: GlobalSnackbar.rawMaterialAppNavigatorKey,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        // Opened over a screen, as from a menu.
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => EditGenresDialog(item: item),
              ),
              child: const Text("Open"),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text("Open"));
    await tester.pumpAndSettle();
  }

  testWidgets("an album's genres are changed on the album and all its songs", (tester) async {
    await open(tester, BaseItemDto(id: const BaseItemId("album"), name: "Kaya", type: "MusicAlbum"));
    expect(find.widgetWithText(InputChip, "Rock"), findsOneWidget);
    expect(find.textContaining("its 2 songs"), findsOneWidget);
    await tester.enterText(find.byType(TextField), "Reggae");
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.widgetWithText(InputChip, "Rock"), matching: find.byIcon(Icons.clear)));
    await tester.pumpAndSettle();
    await tester.tap(find.text("Save"));
    await tester.pumpAndSettle();
    expect(posted, ["album", "s1", "s2"]);
    expect(genres.values, everyElement(["Reggae"]));
    expect(find.text("Saved the genres of 3 items"), findsOneWidget);
  });

  testWidgets("a song added to the album while the dialog is open gets the genres too", (tester) async {
    await open(tester, BaseItemDto(id: const BaseItemId("album"), name: "Kaya", type: "MusicAlbum"));
    expect(find.textContaining("its 2 songs"), findsOneWidget);
    genres["s3"] = ["Pop"];
    albumSongs = ["s1", "s2", "s3"];
    await tester.enterText(find.byType(TextField), "Reggae");
    await tester.tap(find.text("Save"));
    await tester.pumpAndSettle();
    expect(posted, ["album", "s1", "s2", "s3"]);
    expect(genres["s3"], ["Rock", "Reggae"]);
  });

  testWidgets("signed in elsewhere while saving, the other server's items aren't shown as edited", (tester) async {
    await open(tester, BaseItemDto(id: const BaseItemId("s1"), name: "Is This Love", type: "Audio"));
    onPost = (_) =>
        GenreEditor.account = () =>
            (baseUrl: "https://other.example", serverId: "srv2", userId: "u1", auth: "MediaBrowser Token=o");
    await tester.enterText(find.byType(TextField), "Dub");
    await tester.tap(find.text("Save"));
    await tester.pumpAndSettle();
    expect(posted, ["s1"]);
    expect(GenreEditor.edited.value, isEmpty);
  });

  testWidgets("saved genres that can't be read back still show, with the ids known for them", (tester) async {
    final song = BaseItemDto(
      id: const BaseItemId("s2"),
      name: "Jamming",
      type: "Audio",
      genreItems: [NameLongIdPair(name: "Reggae", id: const BaseItemId("g-Reggae"))],
    );
    await open(tester, song);
    onPost = (_) => readsFail = true;
    await tester.enterText(find.byType(TextField), "Ska");
    await tester.pumpAndSettle();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), "Dub");
    await tester.pumpAndSettle();
    await tester.tap(find.text("Save"));
    await tester.pumpAndSettle();
    expect(posted, ["s2"]);
    expect(
      [for (final genre in song.genreItems!) (genre.name, genre.id.raw)],
      [("Reggae", "g-Reggae"), ("Ska", "lib-Ska"), ("Dub", "")],
    );
  });

  testWidgets("a genre typed without pressing Done is saved too", (tester) async {
    await open(tester, BaseItemDto(id: const BaseItemId("s1"), name: "Is This Love", type: "Audio"));
    await tester.enterText(find.byType(TextField), "Dub");
    await tester.tap(find.text("Save"));
    await tester.pumpAndSettle();
    expect(genres["s1"], ["Rock", "Pop", "Dub"]);
  });

  testWidgets("Done takes the suggestion showing", (tester) async {
    await open(tester, BaseItemDto(id: const BaseItemId("s2"), name: "Jamming", type: "Audio"));
    await tester.enterText(find.byType(TextField), "Sk");
    await tester.pumpAndSettle();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(InputChip, "Ska"), findsOneWidget);
    expect(find.widgetWithText(InputChip, "Sk"), findsNothing);
  });

  testWidgets("many genres on a small screen still fit, by scrolling", (tester) async {
    tester.view.physicalSize = const Size(390, 420);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    genres["s1"] = [for (var i = 0; i < 14; i++) "Genre number $i"];
    await open(tester, BaseItemDto(id: const BaseItemId("s1"), name: "Is This Love", type: "Audio"));
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(find.byType(TextField), 100, scrollable: find.byType(Scrollable).last);
    expect(find.byType(TextField).hitTestable(), findsOneWidget);
  });

  testWidgets("the saved genres show on the item at once", (tester) async {
    final song = BaseItemDto(id: const BaseItemId("s2"), name: "Jamming", type: "Audio", genres: ["Reggae"]);
    await open(tester, song);
    await tester.enterText(find.byType(TextField), "Dub");
    await tester.tap(find.text("Save"));
    await tester.pumpAndSettle();
    expect(song.genres, ["Reggae", "Dub"]);
    expect([for (final genre in song.genreItems!) genre.name], ["Reggae", "Dub"]);
    expect(song.genreItems!.last.id, const BaseItemId("g-Dub"));
    expect(
      [for (final genre in GenreEditor.genresShown(BaseItemDto(id: const BaseItemId("s2")))!) genre.name],
      ["Reggae", "Dub"],
    );
  });

  testWidgets("genre chips already on screen show the saved genres, even for another copy of the item", (tester) async {
    final shown = BaseItemDto(
      id: const BaseItemId("s2"),
      name: "Jamming",
      type: "Audio",
      genreItems: [NameLongIdPair(name: "Reggae", id: const BaseItemId("g-Reggae"))],
    );
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: GenreIconAndText(parent: shown)),
        ),
      ),
    );
    expect(find.text("Reggae"), findsOneWidget);
    GenreEditor.remember(["s2"], [NameLongIdPair(name: "Dub", id: const BaseItemId("g-Dub"))]);
    await tester.pump();
    expect(find.text("Dub"), findsOneWidget);
    expect(find.text("Reggae"), findsNothing);
  });

  testWidgets("genres without ids yet each show", (tester) async {
    final shown = BaseItemDto(
      id: const BaseItemId("s2"),
      type: "Audio",
      genreItems: [
        for (final genre in ["Dub", "Ska"]) NameLongIdPair(name: genre, id: const BaseItemId("")),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: GenreIconAndText(parent: shown)),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text("Dub"), findsOneWidget);
    expect(find.text("Ska"), findsOneWidget);
  });

  testWidgets("when some songs can't be saved, the ones that were show their new genres", (tester) async {
    refused = {"s2"};
    await open(tester, BaseItemDto(id: const BaseItemId("album"), name: "Kaya", type: "MusicAlbum"));
    await tester.enterText(find.byType(TextField), "Dub");
    await tester.tap(find.text("Save"));
    await tester.pumpAndSettle();
    String? shown(String id) => GenreEditor.genresShown(BaseItemDto(id: BaseItemId(id)))?.lastOrNull?.name;
    expect(shown("album"), "Dub");
    expect(shown("s1"), "Dub");
    expect(shown("s2"), isNull);
    expect(find.textContaining("Saved 2 of 3"), findsOneWidget);
  });

  testWidgets("the music screen's lists load again, so one filtered by genre has the song or not", (tester) async {
    var refreshed = 0;
    List<String?>? shownThen;
    final listening = musicScreenRefreshStream.stream.listen((_) {
      refreshed++;
      // The edit known by then, so what loads shows on copies loaded before.
      shownThen = [
        for (final genre
            in GenreEditor.genresShown(BaseItemDto(id: const BaseItemId("s2"))) ?? const <NameLongIdPair>[])
          genre.name,
      ];
    });
    addTearDown(listening.cancel);
    await open(tester, BaseItemDto(id: const BaseItemId("s2"), name: "Jamming", type: "Audio"));
    await tester.tap(find.text("Save"));
    await tester.pumpAndSettle();
    expect(refreshed, 1);
    expect(shownThen, ["Reggae"]);
  });

  testWidgets("a song's genres are changed on that song only", (tester) async {
    await open(tester, BaseItemDto(id: const BaseItemId("s1"), name: "Is This Love", type: "Audio"));
    expect(find.widgetWithText(InputChip, "Pop"), findsOneWidget);
    expect(find.textContaining("songs"), findsNothing);
    await tester.tap(find.text("Save"));
    await tester.pumpAndSettle();
    expect(posted, ["s1"]);
    expect(find.text("Saved the genres of 1 item"), findsOneWidget);
  });
}
