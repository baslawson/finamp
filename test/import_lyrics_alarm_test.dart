import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/alarm_service.dart';
import 'package:finamp/services/library_matcher.dart';
import 'package:finamp/services/lyrics_search_service.dart';
import 'package:finamp/services/playlist_import_service.dart';
import 'package:flutter_test/flutter_test.dart';

BaseItemDto _track(String name, String artist) =>
    BaseItemDto(id: BaseItemId(name), name: name, albumArtist: artist, artists: [artist]);

void main() {
  group("library matcher", () {
    test("titles ignore featured artists, versions and punctuation", () {
      expect(LibraryMatcher.normalizeTitle("Stay (feat. Justin Bieber)"), "stay");
      expect(LibraryMatcher.normalizeTitle("Here Comes the Sun - Remastered 2019"), "here comes the sun");
      expect(LibraryMatcher.normalizeTitle("Don't Stop Me Now"), LibraryMatcher.normalizeTitle("Dont Stop Me Now"));
    });

    test("artists split on the usual separators", () {
      expect(LibraryMatcher.splitArtists("Olivia Rodrigo, Chappell Roan"), {"oliviarodrigo", "chappellroan"});
      expect(LibraryMatcher.splitArtists("Simon & Garfunkel"), {"simon", "garfunkel"});
      expect(LibraryMatcher.splitArtists("The Beatles"), {"beatles"});
    });

    test("needs both the title and an artist to match", () {
      const song = SongRef(title: "Yellow", artist: "Coldplay");
      expect(LibraryMatcher.score(song, _track("Yellow", "Coldplay")), 1.0);
      expect(LibraryMatcher.score(song, _track("Yellow", "Someone Else")), 0);
      expect(LibraryMatcher.score(song, _track("Viva la Vida", "Coldplay")), 0);
    });

    test("prefers the studio version over live ones", () {
      const song = SongRef(title: "Yellow", artist: "Coldplay");
      expect(
        LibraryMatcher.score(song, _track("Yellow (Live)", "Coldplay")),
        lessThan(LibraryMatcher.score(song, _track("Yellow", "Coldplay"))),
      );
    });
  });

  group("playlist text", () {
    test("reads Exportify CSV with quoted cells", () {
      final songs = PlaylistImportService.parseText(
        '"Track URI","Track Name","Artist Name(s)","Album Name"\n'
        '"spotify:track:1","Hello, Goodbye","The Beatles","Magical Mystery Tour"\n'
        '"spotify:track:2","Say ""Hi""","Someone","Album"',
      );
      expect(songs.map((song) => song.title), ["Hello, Goodbye", 'Say "Hi"']);
      expect(songs.first.artist, "The Beatles");
    });

    test("reads one Artist - Title per line", () {
      final songs = PlaylistImportService.parseText("1. Queen - Bohemian Rhapsody\nDaft Punk – One More Time\n\n");
      expect(songs.map((song) => "${song.artist}|${song.title}"), [
        "Queen|Bohemian Rhapsody",
        "Daft Punk|One More Time",
      ]);
    });
  });

  test("lyrics match a slightly misremembered line", () {
    const lyrics = "Is this the real life?\nIs this just fantasy?\nCaught in a landslide";
    expect(LyricsSearchService.containsLine(lyrics, "is this the real life is this just a fantasy"), isTrue);
    expect(LyricsSearchService.containsLine(lyrics, "hello darkness my old friend"), isFalse);
  });

  test("alarm fade starts quiet and ends at full volume", () {
    expect(AlarmService.fadeCurve(0), closeTo(0.03, 0.001));
    expect(AlarmService.fadeCurve(0.5), lessThan(0.5));
    expect(AlarmService.fadeCurve(1), 1.0);
    expect(AlarmService.fadeCurve(2), 1.0);
  });
}
