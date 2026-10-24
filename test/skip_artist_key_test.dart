import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/artist_spacing.dart';
import 'package:finamp/services/radio_time_of_day.dart';
import 'package:finamp/services/skip_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test("a skip keeps the artist identity Radio judges candidates by, through saving and loading", () {
    final record = SkipRecord(
      trackId: "t",
      name: "Song",
      artist: "Various Artists",
      count: 1,
      last: DateTime(2026, 10, 24, 20),
      artistKey: "theband",
    );
    final loaded = SkipRecord.fromJson(record.toJson());
    expect(loaded.artist, "Various Artists");
    expect(loaded.artistKey, "theband");
    // Older records without it still load.
    expect(SkipRecord.fromJson({"id": "t", "n": "Song", "c": 1, "t": 0}).artistKey, isNull);
  });

  test("a skipped compilation song counts against its track artist at that hour", () {
    final compilation = BaseItemDto(
      id: BaseItemId("other"),
      name: "Other song",
      type: "Audio",
      artists: ["The Band"],
      albumArtist: "Various Artists",
    );
    final key = ArtistSpacing.artistKey(compilation);
    expect(key, "theband");
    final clock = RadioTimeOfDay(hour: 20, skips: [(trackId: "skipped", artist: key, energy: null, weight: 3.0)]);
    expect(
      clock.weight(trackId: "other", artist: ArtistSpacing.artistKey(compilation)),
      lessThan(clock.weight(trackId: "other", artist: "someoneelse")),
    );
  });
}
