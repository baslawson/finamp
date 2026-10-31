import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/mood_notes.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

BaseItemDto _track(String id, String name, [String artist = "Oasis"]) =>
    BaseItemDto(id: BaseItemId(id), name: name, artists: [artist], albumArtist: artist, type: "Audio");

QueueItemSource _source(String id, String name, String? request) => QueueItemSource.rawId(
  type: QueueItemSourceType.unknown,
  id: id,
  name: QueueItemSourceName(type: QueueItemSourceNameType.preTranslated, pretranslatedName: name),
  mixRequest: request,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferencesAsyncPlatform? originalPrefs;
  var time = DateTime(2026, 10, 25, 12);

  setUp(() {
    originalPrefs = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    time = DateTime(2026, 10, 25, 12);
    MoodNotes.now = () => time;
    MoodNotes.scope = () => "server/me";
  });
  tearDown(() {
    MoodNotes.now = DateTime.now;
    SharedPreferencesAsyncPlatform.instance = originalPrefs;
  });

  test("a song said not to fit is noted with its request, the latest replacing an earlier note", () async {
    await MoodNotes.add(_track("1", "Wonderwall"), "chill evening");
    time = time.add(const Duration(hours: 1));
    await MoodNotes.add(_track("1", "Wonderwall"), "rainy day");
    final notes = await MoodNotes.load();
    expect(notes, hasLength(1));
    expect(notes.single.request, "rainy day");
    expect(notes.single.artist, "Oasis");
  });

  test("at most 50 notes, the oldest going first", () async {
    for (var i = 0; i < MoodNotes.maxNotes + 5; i++) {
      time = time.add(const Duration(minutes: 1));
      await MoodNotes.add(_track("$i", "Song $i"), "party");
    }
    final notes = await MoodNotes.load();
    expect(notes, hasLength(MoodNotes.maxNotes));
    expect(notes.first.trackId, "5");
  });

  test("a note goes after 90 days", () async {
    await MoodNotes.add(_track("1", "Wonderwall"), "party");
    time = time.add(const Duration(days: 89));
    expect(await MoodNotes.load(), hasLength(1));
    time = time.add(const Duration(days: 2));
    expect(await MoodNotes.load(), isEmpty);
  });

  test("one can be removed, or all cleared", () async {
    await MoodNotes.add(_track("1", "Wonderwall"), "party");
    await MoodNotes.add(_track("2", "Champagne Supernova"), "party");
    await MoodNotes.remove("1");
    expect([for (final note in await MoodNotes.load()) note.trackId], ["2"]);
    await MoodNotes.clear();
    expect(await MoodNotes.load(), isEmpty);
  });

  test("an AI DJ mix's request comes with its own songs, even for two mixes of one name", () {
    expect(
      MoodNotes.requestFor(_source(MoodNotes.aiDjSourceId, "Ai DJ: Golden Hour", "chill evening")),
      "chill evening",
    );
    expect(MoodNotes.requestFor(_source(MoodNotes.aiDjSourceId, "Ai DJ: Golden Hour", "beach party")), "beach party");
    expect(MoodNotes.requestFor(_source("playlist", "Ai DJ: Golden Hour", "chill evening")), isNull);
  });

  test("notes changed at once all count", () async {
    await MoodNotes.add(_track("1", "Wonderwall"), "party");
    await MoodNotes.add(_track("2", "Champagne Supernova"), "party");
    await MoodNotes.add(_track("3", "Morning Glory"), "party");
    await Future.wait([MoodNotes.remove("1"), MoodNotes.remove("2")]);
    expect([for (final note in await MoodNotes.load()) note.trackId], ["3"]);
  });

  test("each account keeps its own notes", () async {
    await MoodNotes.add(_track("1", "Wonderwall"), "party");
    MoodNotes.scope = () => "server/someone else";
    expect(await MoodNotes.load(), isEmpty);
    await MoodNotes.add(_track("2", "Champagne Supernova"), "party");
    MoodNotes.scope = () => "server/me";
    expect([for (final note in await MoodNotes.load()) note.trackId], ["1"]);
  });

  test("the same request, give or take case and punctuation", () {
    expect(MoodNotes.sameRequest("Chill evening!", "chill  evening"), isTrue);
    expect(MoodNotes.sameRequest("chill evening", "chill morning"), isFalse);
  });

  test("the prompt lists only noted songs the AI can see, by their number", () async {
    await MoodNotes.add(_track("1", "Wonderwall"), 'a "chill" evening');
    await MoodNotes.add(_track("9", "Not in the catalog"), "party");
    final catalog = [_track("0", "Champagne Supernova"), _track("1", "Wonderwall")];
    final section = MoodNotes.promptSection(await MoodNotes.load(), catalog);
    expect(section, contains("1 (Wonderwall by Oasis): not for \"a 'chill' evening\""));
    expect(section, isNot(contains("Not in the catalog")));
    expect(MoodNotes.promptSection(const [], catalog), isEmpty);
  });
}
