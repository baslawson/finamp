import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/list_duplicates.dart';
import 'package:finamp/services/song_duplicates.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

QueueItemSource _source(QueueItemSourceType type) => QueueItemSource.rawId(
  type: type,
  id: "list",
  name: const QueueItemSourceName(type: QueueItemSourceNameType.preTranslated, pretranslatedName: "List"),
);

BaseItemDto _track(String id, String name, String artist, {String? album}) =>
    BaseItemDto(id: BaseItemId(id), name: name, artists: [artist], albumArtist: artist, album: album, type: "Audio");

List<String> _ids(Iterable<BaseItemDto> tracks) => [for (final track in tracks) track.id.raw];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferencesAsyncPlatform? originalPrefs;

  setUp(() {
    originalPrefs = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    ListDuplicates.reset();
  });
  tearDown(() {
    ListDuplicates.reset();
    SharedPreferencesAsyncPlatform.instance = originalPrefs;
  });

  final playlist = _source(QueueItemSourceType.playlist), album = _source(QueueItemSourceType.album);

  test("off by default: no list is cleaned", () async {
    await ListDuplicates.ensureLoaded();
    expect(ListDuplicates.mode, ListDuplicatesMode.off);
    expect(ListDuplicates.appliesTo(playlist), isFalse);
    expect(ListDuplicates.appliesTo(album), isFalse);
  });

  test("playlists only leaves albums and other lists as they are", () async {
    await ListDuplicates.setMode(ListDuplicatesMode.playlists);
    expect(ListDuplicates.appliesTo(playlist), isTrue);
    expect(ListDuplicates.appliesTo(album), isFalse);
    expect(ListDuplicates.appliesTo(_source(QueueItemSourceType.artist)), isFalse);
  });

  test("every list covers albums, artists and genres, but not songs added by hand or SyncPlay", () async {
    await ListDuplicates.setMode(ListDuplicatesMode.everyList);
    for (final type in [
      QueueItemSourceType.playlist,
      QueueItemSourceType.album,
      QueueItemSourceType.artist,
      QueueItemSourceType.genre,
      QueueItemSourceType.filteredList,
      QueueItemSourceType.downloads,
    ]) {
      expect(ListDuplicates.appliesTo(_source(type)), isTrue, reason: type.name);
    }
    for (final type in [
      QueueItemSourceType.nextUp,
      QueueItemSourceType.nextUpPlaylist,
      QueueItemSourceType.queue,
      QueueItemSourceType.remoteClient,
    ]) {
      expect(ListDuplicates.appliesTo(_source(type)), isFalse, reason: type.name);
    }
  });

  test("lists pinned to the home screen count as what they are", () async {
    QueueItemSource section(String? type) => QueueItemSource.rawId(
      type: QueueItemSourceType.homeScreenSection,
      id: "section",
      name: const QueueItemSourceName(type: QueueItemSourceNameType.preTranslated, pretranslatedName: "Pinned"),
      item: type == null ? null : BaseItemDto(id: BaseItemId("p"), type: type),
    );
    await ListDuplicates.setMode(ListDuplicatesMode.playlists);
    expect(ListDuplicates.appliesTo(section("Playlist")), isTrue);
    expect(ListDuplicates.appliesTo(section("MusicAlbum")), isFalse);
    await ListDuplicates.setMode(ListDuplicatesMode.everyList);
    expect(ListDuplicates.appliesTo(section("MusicAlbum")), isTrue);
    expect(ListDuplicates.appliesTo(section(null)), isTrue, reason: "a library tab's songs");
    expect(ListDuplicates.appliesTo(section("Audio")), isTrue, reason: "a song tapped in a section");
  });

  test("a collection played directly counts as a list", () async {
    final collection = QueueItemSource.rawId(
      type: QueueItemSourceType.unknown,
      id: "c",
      name: const QueueItemSourceName(type: QueueItemSourceNameType.preTranslated, pretranslatedName: "Box set"),
      item: BaseItemDto(id: BaseItemId("c"), type: "BoxSet"),
    );
    await ListDuplicates.setMode(ListDuplicatesMode.playlists);
    expect(ListDuplicates.appliesTo(collection), isFalse);
    await ListDuplicates.setMode(ListDuplicatesMode.everyList);
    expect(ListDuplicates.appliesTo(collection), isTrue);
  });

  test("search results played as a list count with every list", () async {
    final search = QueueItemSource.rawId(
      type: QueueItemSourceType.unknown,
      id: "library-search",
      name: const QueueItemSourceName(type: QueueItemSourceNameType.preTranslated, pretranslatedName: "Search"),
    );
    await ListDuplicates.setMode(ListDuplicatesMode.playlists);
    expect(ListDuplicates.appliesTo(search), isFalse);
    await ListDuplicates.setMode(ListDuplicatesMode.everyList);
    expect(ListDuplicates.appliesTo(search), isTrue);
  });

  test("the choice is kept across restarts", () async {
    await ListDuplicates.setMode(ListDuplicatesMode.everyList);
    ListDuplicates.reset();
    await ListDuplicates.ensureLoaded();
    expect(ListDuplicates.mode, ListDuplicatesMode.everyList);
  });

  group("as a list starts and its rest arrives", () {
    final wonderwall = _track("1", "Wonderwall", "Oasis");
    final live = _track("2", "Wonderwall (Live)", "Oasis");
    final cover = _track("3", "Wonderwall", "Ryan Adams");
    final other = _track("4", "Champagne Supernova", "Oasis");
    final again = _track("5", "Wonderwall - Remastered", "Oasis", album: "Time Flies");

    test("the first copy is kept, and a cover that doesn't credit the original stays", () {
      expect(_ids(withoutDuplicateSongs([wonderwall, other, live, cover])), ["1", "4", "3"]);
    });

    test("the song picked to start with stays, even after an earlier copy", () {
      expect(_ids(withoutDuplicateSongs([wonderwall, other, live], keep: [live])), ["4", "2"]);
    });

    test("started part-way, a skipped copy doesn't drop an upcoming version", () {
      final (:tracks, :start) = withoutDuplicateSongsFrom([wonderwall, other, live], 1);
      expect(_ids(tracks), ["4", "2"]);
      expect(start, 0);
    });

    test("tapping a later copy of the same recording starts there, not at the first copy", () {
      final c = _track("6", "Morning Glory", "Oasis");
      final (:tracks, :start) = withoutDuplicateSongsFrom([wonderwall, other, wonderwall, c], 2);
      expect(_ids(tracks), ["4", "1", "6"]);
      expect(tracks[start].id.raw, "1");
      expect(start, 1, reason: "Champagne Supernova stays behind, not played again");
    });

    test("a playable version is kept over one that can't play, which stays only without one", () {
      final broken = _track("7", "Wonderwall", "Oasis");
      final lonely = _track("8", "Morning Glory", "Oasis");
      final (:tracks, :start) = withoutDuplicateSongsFrom(
        [broken, other, again, lonely],
        0,
        playable: {other.id, again.id},
      );
      expect(_ids(tracks), ["4", "5", "8"]);
      expect(start, 0);
    });

    test("the very same entry twice, the second tapped, starts there with playable versions too", () {
      final c = _track("6", "Morning Glory", "Oasis");
      final (:tracks, :start) = withoutDuplicateSongsFrom(
        [wonderwall, other, wonderwall, c],
        2,
        playable: {wonderwall.id, other.id, c.id},
      );
      expect(_ids(tracks), ["4", "1", "6"]);
      expect(start, 1);
    });

    test("a picked version that can't play starts at its playable one", () {
      final (:tracks, :start) = withoutDuplicateSongsFrom(
        [other, wonderwall, live],
        2,
        playable: {other.id, wonderwall.id},
      );
      expect(_ids(tracks), ["4", "1"]);
      expect(start, 1);
    });

    test("a picked version that can't play, with no playable one, is the copy kept, so it starts where it was", () {
      final c = _track("6", "Morning Glory", "Oasis");
      final (:tracks, :start) = withoutDuplicateSongsFrom([wonderwall, other, live, c], 2, playable: {other.id, c.id});
      expect(_ids(tracks), ["4", "2", "6"]);
      expect(start, 1, reason: "Champagne Supernova, before the pick, isn't played again");
    });

    test("a picked version that can't play, last in the list, starts there, not back at the top", () {
      final (:tracks, :start) = withoutDuplicateSongsFrom([other, wonderwall, live], 2, playable: {other.id});
      expect(_ids(tracks), ["4", "2"]);
      expect(start, 1);
    });

    test("a picked version that can't play, after a playable song, isn't swapped for an earlier copy", () {
      final c = _track("6", "Morning Glory", "Oasis");
      final (:tracks, :start) = withoutDuplicateSongsFrom([other, wonderwall, c, live], 3, playable: {other.id, c.id});
      expect(_ids(tracks), ["4", "6", "2"]);
      expect(start, 2, reason: "Morning Glory, before the pick, isn't played again");
    });

    test("the very same entry that can't play twice, the second tapped, starts there", () {
      final (:tracks, :start) = withoutDuplicateSongsFrom([wonderwall, other, wonderwall], 2, playable: {other.id});
      expect(_ids(tracks), ["4", "1"]);
      expect(start, 1, reason: "Champagne Supernova, before the pick, isn't played again");
    });

    test("a song with no playable version keeps just one of them", () {
      final remaster = _track("5", "Wonderwall - Remastered", "Oasis");
      final c = _track("6", "Morning Glory", "Oasis");
      final (:tracks, start: _) = withoutDuplicateSongsFrom(
        [other, wonderwall, live, remaster, c],
        0,
        playable: {other.id, c.id},
      );
      expect(_ids(tracks), ["4", "1", "6"]);
    });

    test("the rest of a long list doesn't repeat songs from its start", () {
      final start = withoutDuplicateSongs([wonderwall, other]);
      expect(_ids(withoutDuplicateSongs([again, cover, live], already: start)), ["3"]);
    });
  });
}
