import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/played_recently.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

BaseItemDto _track(String id, String name, String artist) =>
    BaseItemDto(id: BaseItemId(id), name: name, artists: [artist], albumArtist: artist, type: "Audio");

List<String> _ids(Iterable<BaseItemDto> tracks) => [for (final track in tracks) track.id.raw];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferencesAsyncPlatform? originalPrefs;
  var time = DateTime(2026, 10, 25, 9);
  const minutes4 = Duration(minutes: 4);

  setUp(() {
    originalPrefs = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    PlayedRecently.reset();
    time = DateTime(2026, 10, 25, 9);
    PlayedRecently.now = () => time;
  });
  tearDown(() {
    PlayedRecently.reset();
    SharedPreferencesAsyncPlatform.instance = originalPrefs;
  });

  final creep = _track("1", "Creep", "Radiohead");
  final list = [creep, _track("2", "Karma Police", "Radiohead"), _track("3", "Airbag", "Radiohead")];

  test("half a song counts as heard, less doesn't", () {
    expect(PlayedRecently.heard(const Duration(minutes: 2), minutes4), isTrue);
    expect(PlayedRecently.heard(const Duration(minutes: 1, seconds: 59), minutes4), isFalse);
    expect(PlayedRecently.heard(const Duration(seconds: 90), null), isTrue);
  });

  test("heard songs are left out only while the setting is on, for 24 hours", () async {
    await PlayedRecently.record(creep, played: const Duration(minutes: 3), total: minutes4);
    await PlayedRecently.record(list[1], played: const Duration(seconds: 20), total: minutes4);
    expect(_ids(PlayedRecently.filter(list).tracks), ["1", "2", "3"], reason: "off by default");
    await PlayedRecently.setOn(true);
    expect(_ids(PlayedRecently.filter(list).tracks), ["2", "3"]);
    time = time.add(const Duration(hours: 23, minutes: 59));
    expect(_ids(PlayedRecently.filter(list).tracks), ["2", "3"]);
    time = time.add(const Duration(minutes: 1));
    expect(_ids(PlayedRecently.filter(list).tracks), ["1", "2", "3"], reason: "the last 24 hours, not today");
  });

  test("other versions of a heard song are left out too", () async {
    await PlayedRecently.setOn(true);
    await PlayedRecently.record(creep, played: minutes4, total: minutes4);
    final versions = [_track("4", "Creep (Acoustic)", "Radiohead"), _track("5", "Creep", "Stone Temple Pilots")];
    expect(_ids(PlayedRecently.filter([...versions, list[2]]).tracks), ["5", "3"]);
  });

  test("the list is kept across restarts and can be cleared", () async {
    await PlayedRecently.setOn(true);
    await PlayedRecently.record(creep, played: minutes4, total: minutes4);
    PlayedRecently.reset();
    PlayedRecently.now = () => time;
    await PlayedRecently.ensureLoaded();
    expect(PlayedRecently.isOn, isTrue);
    expect(PlayedRecently.heardCount, 1);
    expect(_ids(PlayedRecently.filter(list).tracks), ["2", "3"]);
    await PlayedRecently.clear();
    expect(PlayedRecently.heardCount, 0);
    expect(_ids(PlayedRecently.filter(list).tracks), ["1", "2", "3"]);
  });

  test("a picked song still plays, and a list heard in full plays in full", () async {
    await PlayedRecently.setOn(true);
    for (final track in list.take(2)) {
      await PlayedRecently.record(track, played: minutes4, total: minutes4);
    }
    expect(_ids(PlayedRecently.filter(list, keep: creep).tracks), ["1", "3"]);
    await PlayedRecently.record(list[2], played: minutes4, total: minutes4);
    final all = PlayedRecently.filter(list);
    expect(all.allHeard, isTrue);
    expect(_ids(all.tracks), ["1", "2", "3"]);
    expect(PlayedRecently.filter(list, keep: creep).allHeard, isTrue, reason: "only the picked song would be left");
    expect(
      PlayedRecently.filter(list, fallBack: false).tracks,
      isEmpty,
      reason: "the rest of a list that had new songs",
    );
  });

  test("each server keeps its own list, as item ids belong to one server", () async {
    var server = "home";
    PlayedRecently.scope = () => server;
    await PlayedRecently.setOn(true);
    await PlayedRecently.record(creep, played: minutes4, total: minutes4);
    server = "work";
    await PlayedRecently.ensureLoaded();
    expect(PlayedRecently.heardCount, 0);
    expect(_ids(PlayedRecently.filter(list).tracks), ["1", "2", "3"]);
    server = "home";
    await PlayedRecently.ensureLoaded();
    expect(_ids(PlayedRecently.filter(list).tracks), ["2", "3"]);
  });

  test("a heard cover keeps out others linked to it through the original, and heard songs can go last", () async {
    await PlayedRecently.setOn(true);
    final cast = _track("c", "Letterbomb", "Original Broadway Cast Featuring Green Day");
    await PlayedRecently.record(cast, played: minutes4, total: minutes4);
    final quartet = BaseItemDto(
      id: const BaseItemId("q"),
      name: "Letterbomb",
      artists: ["Vitamin String Quartet"],
      album: "Vitamin String Quartet Performs Green Day's American Idiot",
      type: "Audio",
    );
    final original = _track("g", "Letterbomb", "Green Day");
    expect(_ids(PlayedRecently.filter([quartet, original, list[2]]).tracks), ["3"]);
    expect(_ids(PlayedRecently.heardLast([cast, list[2], original])), ["3", "c", "g"]);
  });

  test("a play recorded while switching account isn't added to the new account's list", () async {
    var server = "home";
    PlayedRecently.scope = () => server;
    await PlayedRecently.setOn(true);
    final recording = PlayedRecently.record(creep, played: minutes4, total: minutes4);
    server = "work";
    await PlayedRecently.ensureLoaded();
    await recording;
    expect(PlayedRecently.heardCount, 0);
  });

  test("a version left out for another reason still links a heard song to its other versions", () async {
    await PlayedRecently.setOn(true);
    final cast = _track("c", "Letterbomb", "Original Broadway Cast Featuring Green Day");
    await PlayedRecently.record(cast, played: minutes4, total: minutes4);
    final quartet = BaseItemDto(
      id: const BaseItemId("q"),
      name: "Letterbomb",
      artists: ["Vitamin String Quartet"],
      album: "Vitamin String Quartet Performs Green Day's American Idiot",
      type: "Audio",
    );
    // Green Day's original can't play, but still tells that the quartet's cover is the heard song.
    final unplayable = _track("g", "Letterbomb", "Green Day");
    expect(_ids(PlayedRecently.filter([quartet, list[2]], through: [quartet, unplayable, list[2]]).tracks), ["3"]);
  });

  test("the time a heard song is left out for can be shorter, custom, and is kept after a restart", () async {
    await PlayedRecently.setOn(true);
    expect(PlayedRecently.hours, 24, reason: "a day unless another time is chosen");
    await PlayedRecently.record(creep, played: minutes4, total: minutes4);
    time = time.add(const Duration(hours: 2));
    await PlayedRecently.setHours(3);
    expect(_ids(PlayedRecently.filter(list).tracks), ["2", "3"]);
    await PlayedRecently.setHours(1);
    expect(_ids(PlayedRecently.filter(list).tracks), ["1", "2", "3"], reason: "heard two hours ago");
    expect(PlayedRecently.heardCount, 0);
    await PlayedRecently.setHours(48);
    expect(_ids(PlayedRecently.filter(list).tracks), ["2", "3"], reason: "a longer time still knows the play");
    PlayedRecently.reset();
    PlayedRecently.now = () => time;
    await PlayedRecently.ensureLoaded();
    expect(PlayedRecently.hours, 48);
    await PlayedRecently.setHours(500);
    expect(PlayedRecently.hours, PlayedRecently.maxHours);
    await PlayedRecently.setHours(0);
    expect(PlayedRecently.hours, 1);
    expect(PlayedRecently.presets, [1, 3, 6, 12, 24]);
  });

  test("plays are kept for the longest time that can be chosen, not longer", () async {
    await PlayedRecently.setOn(true);
    await PlayedRecently.setHours(PlayedRecently.maxHours);
    await PlayedRecently.record(creep, played: minutes4, total: minutes4);
    time = time.add(const Duration(hours: PlayedRecently.maxHours - 1));
    expect(PlayedRecently.heardCount, 1);
    time = time.add(const Duration(hours: 1));
    expect(PlayedRecently.heardCount, 0);
  });
}
