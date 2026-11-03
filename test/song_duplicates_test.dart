import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/song_duplicates.dart';
import 'package:flutter_test/flutter_test.dart';

BaseItemDto _track(String id, String name, String artist, {String album = "Album"}) =>
    BaseItemDto(id: BaseItemId(id), name: name, albumArtist: artist, album: album, type: "Audio");

QueueItemSource _source(QueueItemSourceType type, String id) => QueueItemSource.rawId(
  type: type,
  name: const QueueItemSourceName(type: QueueItemSourceNameType.preTranslated, pretranslatedName: "x"),
  id: id,
);

const _vsq = "Vitamin String Quartet Performs Green Day's American Idiot";

void main() {
  test("covers count as the same song when their details name the original artist, unrelated songs don't", () {
    final tracks = [
      _track("1", "Letterbomb", "Green Day", album: "American Idiot"),
      _track(
        "2",
        "Letterbomb",
        "Original Broadway Cast Featuring Green Day",
        album: "American Idiot: The Original Broadway Cast Recording",
      ),
      _track("3", "One", "U2"),
      _track("4", "One", "Metallica"),
      BaseItemDto(
        id: const BaseItemId("5"),
        name: "One",
        type: "Audio",
        albumArtist: "Various Artists",
        artists: ["U2"],
        album: "Now 21",
      ),
      _track("6", "Yes", "Yes Please", album: "Songs"),
      _track("7", "Yes", "Coldplay"),
    ];
    expect(withoutDuplicateSongs(tracks).map((track) => track.id.raw), ["1", "3", "4", "6", "7"]);
  });

  test("the same artist spelled differently is still the same artist", () {
    final tracks = [_track("1", "All the Small Things", "blink-182"), _track("2", "All The Small Things", "Blink 182")];
    expect(withoutDuplicateSongs(tracks), hasLength(1));
    final collaboration = [_track("3", "Song", "Main Artist"), _track("4", "Song", "Main Artist x Guest Artist")];
    expect(withoutDuplicateSongs(collaboration), hasLength(1));
    final accented = [_track("8", "Song", "Beyoncé"), _track("9", "Song", "Beyoncé x Ñengo Flow")];
    expect(withoutDuplicateSongs(accented), hasLength(1));
    // An "x" in a name isn't a collaboration.
    final names = [_track("5", "Song", "Malcolm X"), _track("6", "Song", "Malcolm"), _track("7", "Song", "X")];
    expect(withoutDuplicateSongs(names), hasLength(3));
  });

  test("an original left out still links its covers, whatever the order", () {
    final tracks = [
      _track("1", "Letterbomb", "Vitamin String Quartet", album: _vsq),
      _track("2", "Letterbomb", "Green Day", album: "American Idiot"),
      _track("3", "Letterbomb", "Original Broadway Cast Featuring Green Day"),
    ];
    expect(withoutDuplicateSongs(tracks).map((track) => track.id.raw), ["1"]);
    // Two covers before the original they share: neither names the other, yet only the first stays.
    final coversFirst = [tracks[0], tracks[2], tracks[1]];
    expect(withoutDuplicateSongs(coversFirst).map((track) => track.id.raw), ["1"]);
    // An original already queued keeps out both covers it links.
    expect(withoutDuplicateSongs([tracks[0], tracks[2]], already: [tracks[1]]), isEmpty);
  });

  test("an artist's name that's just a word in an album title isn't a cover credit", () {
    final tracks = [
      _track("1", "Home", "Live", album: "Secret Samadhi"),
      _track("2", "Home", "Michael Bublé", album: "Caught in the Act (Live)"),
    ];
    expect(withoutDuplicateSongs(tracks), hasLength(2));
  });

  test("a cover credit on one copy counts for the artist's other copies", () {
    final tracks = [
      _track("1", "Letterbomb", "Vitamin String Quartet", album: "Strings 2010"),
      _track("2", "Letterbomb", "Green Day", album: "American Idiot"),
      _track("3", "Letterbomb", "Vitamin String Quartet", album: _vsq),
    ];
    expect(withoutDuplicateSongs(tracks).map((track) => track.id.raw), ["1"]);
  });

  test("recordings that only link versions are never kept, and don't keep their versions out", () {
    final original = _track("2", "Letterbomb", "Green Day", album: "American Idiot");
    final tracks = [
      _track("1", "Letterbomb", "Vitamin String Quartet", album: _vsq),
      _track("3", "Letterbomb", "Original Broadway Cast Featuring Green Day"),
    ];
    expect(withoutDuplicateSongs(tracks, through: [original]).map((track) => track.id.raw), ["1"]);
    expect(withoutDuplicateSongs([tracks[1]], through: [original]).map((track) => track.id.raw), ["3"]);
    expect(withoutDuplicateSongs(const [], through: [original]), isEmpty);
  });

  test("many unrelated songs of the same title are sorted quickly", () {
    final tracks = [for (var i = 0; i < 2000; i++) _track("$i", "Intro", "Artist number $i", album: "Album $i")];
    final clock = Stopwatch()..start();
    expect(withoutDuplicateSongs(tracks), hasLength(2000));
    expect(clock.elapsedMilliseconds, lessThan(1500));
  });

  test("a mix keeps one version of a song: not its compilation copy or other versions", () {
    final tracks = [
      _track("1", "Wonderwall", "Oasis"),
      _track("2", "Wonderwall (Remastered)", "Oasis", album: "Time Flies"),
      _track("3", "Wonderwall (Live)", "Oasis"),
      _track("1", "Wonderwall", "Oasis"),
      // Nothing says this is a cover of Oasis, so it could be another song of the same name.
      _track("4", "Wonderwall", "Ryan Adams"),
      _track("5", "Champagne Supernova", "Oasis"),
    ];
    expect(withoutDuplicateSongs(tracks).map((track) => track.id.raw), ["1", "4", "5"]);
  });

  test("Spoonman's demo, rehearsal and remixes and the covers of Letterbomb each count once", () {
    final tracks = [
      _track("1", "Spoonman", "Soundgarden"),
      _track("2", "Spoonman (Rehearsal Version)", "Soundgarden"),
      _track("3", "Spoonman [Demo]", "Soundgarden"),
      _track("4", "Spoonman - Steve Fisk Remix", "Soundgarden"),
      _track("5", "Letterbomb", "Vitamin String Quartet", album: _vsq),
      _track("6", "Letterbomb", "Green Day"),
      _track("7", "Hey Jude - Remastered 2009", "The Beatles"),
      _track("8", "Hey Jude", "The Beatles"),
    ];
    expect(withoutDuplicateSongs(tracks).map((track) => track.id.raw), ["1", "5", "7"]);
  });

  test("titles that only differ outside version tags stay apart", () {
    expect(versionlessTitle("Peace (A Beginning)"), isNot(versionlessTitle("Peace (An End)")));
    expect(versionlessTitle("Hey Jude (2015 Mix)"), "hey jude");
    expect(versionlessTitle("Main Title (From \"Star Wars\")"), isNot(versionlessTitle("Main Title (From \"Jaws\")")));
    expect(versionlessTitle("Love - Part 2"), "love part 2");
    expect(versionlessTitle("Dive (Live at Pine Street Theatre)"), "dive");
    expect(versionlessTitle("Let's Go (feat. Big D & Twista)"), "lets go");
    expect(versionlessTitle("(Untitled)"), "untitled");
    final tracks = [_track("1", "Spoonman", "Soundgarden"), _track("2", "Spoon", "Soundgarden")];
    expect(withoutDuplicateSongs(tracks), hasLength(2));
  });

  test("numbered parts stay separate songs, while their versions don't", () {
    final tracks = [
      _track("1", "Another Brick in the Wall (Part 1)", "Pink Floyd"),
      _track("2", "Another Brick in the Wall (Part 2)", "Pink Floyd"),
      _track("3", "Another Brick in the Wall (Part 2) [Live]", "Pink Floyd"),
      _track("4", "Symphony (No. 5)", "Orchestra"),
      _track("5", "Symphony (No. 9)", "Orchestra"),
      _track("6", "Song - Part 1 - Live", "Band"),
      _track("7", "Song - Part 2 - Live", "Band"),
      _track("8", "Suite (Part 1: Sunrise)", "Band"),
      _track("9", "Suite (Part 2: Sunset)", "Band"),
      _track("10", "Sonata (I. Adagio sostenuto)", "Pianist"),
      _track("11", "Sonata (II. Allegretto)", "Pianist"),
      _track("12", "Sonata (II. Allegretto) [Live]", "Pianist"),
    ];
    expect(withoutDuplicateSongs(tracks).map((track) => track.id.raw), [
      "1", "2", "4", "5", "6", "7", "8", "9", "10", "11", //
    ]);
    // Words that only look like a number don't make a version a separate song.
    expect(versionlessTitle("Satisfaction (No Remix)"), "satisfaction");
    expect(versionlessTitle("Run (Live)"), "run");
    expect(versionlessTitle("(I Can't Get No) Satisfaction"), "satisfaction");
  });

  test("plural and undotted section labels, and parts after a version tag, stay separate songs", () {
    expect(
      versionlessTitle("Shine On You Crazy Diamond (Parts I-V)"),
      isNot(versionlessTitle("Shine On You Crazy Diamond (Parts VI-IX)")),
    );
    expect(versionlessTitle("Symphony (I Allegro)"), isNot(versionlessTitle("Symphony (II Adagio)")));
    expect(versionlessTitle("Symphony (II Adagio)"), isNot(versionlessTitle("Symphony (IV Allegro)")));
    expect(versionlessTitle("Suite - Live - Part 1"), isNot(versionlessTitle("Suite - Live - Part 2")));
  });

  test("sections inside a version suffix and large Roman numerals stay, stacked version tags go", () {
    expect(versionlessTitle("Suite - Part 1 Live"), "suite part 1");
    expect(versionlessTitle("Suite - Part 2 Live"), "suite part 2");
    expect(versionlessTitle("Variations (XIX Allegro)"), isNot(versionlessTitle("Variations (XX Andante)")));
    expect(versionlessTitle("Song - Live - Remastered 2009"), "song");
    expect(versionlessTitle("Song - Live"), "song");
    expect(versionlessTitle("Suite - I. Allegro Live"), "suite i allegro");
    expect(versionlessTitle("Suite - II. Adagio Live"), "suite ii adagio");
    expect(versionlessTitle("Suite - Parts I-II Live"), isNot(versionlessTitle("Suite - Parts I-III Live")));
    expect(versionlessTitle("Suite (Live - Part 1)"), "suite part 1");
    expect(versionlessTitle("Suite (Part 2 Live)"), versionlessTitle("Suite (Part 2)"));
    expect(versionlessTitle("Suite - Live - Part 1"), versionlessTitle("Suite - Part 1"));
    expect(versionlessTitle("Suite (Live - Part 2)"), "suite part 2");
  });

  test("version filters run on songs that may play, so a resting copy can't crowd out another", () {
    final tracks = [_track("1", "Letterbomb", "Green Day"), _track("2", "Letterbomb", "Vitamin String Quartet")];
    final allowed = tracks.where((track) => track.albumArtist != "Green Day");
    expect(withoutDuplicateSongs(allowed).map((track) => track.id.raw), ["2"]);
  });

  test("a title that is all brackets keeps its name, without its version tags", () {
    expect(versionlessTitle("(Nice Dream)"), "nice dream");
    expect(versionlessTitle("(Nice Dream) (Live)"), "nice dream");
    expect(versionlessTitle("(Untitled)"), "untitled");
    expect(versionlessTitle("(Nice Dream) (Part 1)"), "nice dream part 1");
    expect(versionlessTitle("(Untitled) (Part 1)"), isNot(versionlessTitle("(Nice Dream) (Part 1)")));
  });

  test("remix names with hyphens in them are recognised", () {
    expect(versionlessTitle("Song - X-Press 2 Remix"), "song");
    expect(versionlessTitle("Song - 12-inch Mix"), "song");
  });

  test("a song picked to start with beats an earlier version of it", () {
    final picked = _track("2", "Letterbomb", "Vitamin String Quartet", album: _vsq);
    final tracks = [_track("1", "Letterbomb", "Green Day"), _track("3", "Holiday", "Green Day"), picked];
    expect(withoutDuplicateSongs(tracks, keep: [picked]).map((track) => track.id.raw), ["3", "2"]);
  });

  test("songs already in the queue are left out", () {
    final queued = [_track("9", "Creep", "Radiohead")];
    final result = withoutDuplicateSongs([_track("10", "Creep", "Radiohead", album: "Best Of")], already: queued);
    expect(result, isEmpty);
  });

  test("only mixes and shuffles are cleaned, not albums or playlists", () {
    expect(isGeneratedSource(_source(QueueItemSourceType.allTracks, "x")), isTrue);
    expect(isGeneratedSource(_source(QueueItemSourceType.unknown, "aiDj")), isTrue);
    expect(isGeneratedSource(_source(QueueItemSourceType.album, "x")), isFalse);
    expect(isGeneratedSource(_source(QueueItemSourceType.playlist, "x")), isFalse);
    expect(isGeneratedSource(_source(QueueItemSourceType.unknown, "party")), isFalse);
  });
}
