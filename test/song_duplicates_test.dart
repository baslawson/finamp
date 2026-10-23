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

void main() {
  test("the same song from a compilation counts as a duplicate, other versions don't", () {
    final tracks = [
      _track("1", "Wonderwall", "Oasis"),
      _track("2", "Wonderwall (Remastered)", "Oasis", album: "Time Flies"),
      _track("3", "Wonderwall (Live)", "Oasis"),
      _track("1", "Wonderwall", "Oasis"),
      _track("4", "Wonderwall", "Ryan Adams"),
    ];
    expect(withoutDuplicateSongs(tracks).map((track) => track.id.raw), ["1", "3", "4"]);
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
