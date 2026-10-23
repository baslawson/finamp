import 'package:finamp/screens/year_in_music_screen.dart';
import 'package:finamp/services/listening_log_service.dart';
import 'package:flutter_test/flutter_test.dart';

ListenEntry _listen(DateTime time, String track, String artist, int minutes, {List<String> genres = const []}) =>
    ListenEntry(
      time: time,
      listened: Duration(minutes: minutes),
      trackId: track,
      track: track,
      artistId: artist,
      artist: artist,
      genres: genres,
    );

void main() {
  test("ranks a year's listens and ignores other years", () {
    final recap = YearRecap.fromEntries(2026, [
      _listen(DateTime(2026, 3, 1), "a", "Sting", 4, genres: ["Rock"]),
      _listen(DateTime(2026, 3, 2), "a", "Sting", 4, genres: ["rock"]),
      _listen(DateTime(2026, 7, 1), "b", "Bush", 5),
      _listen(DateTime(2025, 7, 1), "c", "Old", 60),
    ]);
    expect(recap.plays, 3);
    expect(recap.uniqueTracks, 2);
    expect(recap.listened, const Duration(minutes: 13));
    expect(recap.topTracks.first.name, "a");
    expect(recap.topArtists.map((artist) => artist.name), ["Sting", "Bush"]);
    expect(recap.topGenres.single.plays, 2);
    expect(recap.busiestMonth, 3);
  });

  test("round-trips listens through JSON", () {
    final entry = _listen(DateTime(2026, 1, 1, 12), "a", "Sting", 3, genres: ["Pop"]);
    final copy = ListenEntry.fromJson(entry.toJson());
    expect(copy.time, entry.time);
    expect(copy.listened, entry.listened);
    expect(copy.genres, ["Pop"]);
    expect(copy.album, isNull);
  });
}
