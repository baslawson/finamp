import 'package:audio_service/audio_service.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/lyrics_timeline.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Ticks are 100 ns: one second is 10 000 000.
  const second = 10000000;

  test('lines and cues move to the remix, and lines cut from its start keep their place at the start', () {
    final timeline = LyricsTimeline.fromJson({'tempo': 2, 'offset': -1.5})!;
    final moved = timeline.apply(
      LyricDto(
        lyrics: [
          LyricLine(text: 'cut', start: 2 * second),
          LyricLine(
            text: 'kept',
            start: 4 * second,
            cues: [LyricLineCue(position: 0, start: 2 * second, endPosition: 4, end: 6 * second)],
          ),
          LyricLine(text: 'unsynced'),
        ],
      ),
    );
    expect(moved.lyrics!.map((line) => (line.text, line.start)), [
      ('cut', 0),
      ('kept', second ~/ 2),
      ('unsynced', null),
    ]);
    final cue = moved.lyrics![1].cues!.single;
    expect((cue.position, cue.start, cue.endPosition, cue.end), (0, 0, 4, 15 * second ~/ 10));
  });

  test('only a usable timeline is read back', () {
    final timeline = LyricsTimeline(tempo: 0.97, offset: const Duration(milliseconds: 3750));
    final read = LyricsTimeline.fromJson(timeline.toJson())!;
    expect((read.tempo, read.offset), (0.97, const Duration(milliseconds: 3750)));
    for (final bad in [
      null,
      'x',
      {'tempo': 0, 'offset': 1},
      {'tempo': -1, 'offset': 1},
      {'tempo': double.nan, 'offset': 1},
      {'tempo': 1, 'offset': double.infinity},
      {'tempo': 1, 'offset': null},
    ]) {
      expect(LyricsTimeline.fromJson(bad), isNull, reason: '$bad');
    }
  });

  FinampQueueItem remix(Map<String, dynamic> extras) => FinampQueueItem(
    item: MediaItem(
      id: 'm',
      title: 'Singer over Band',
      extras: {
        'itemJson': {'Id': 'a', 'Name': 'Singer over Band', 'RunTimeTicks': 300 * second},
        ...extras,
      },
    ),
    source: QueueItemSource.rawId(
      type: QueueItemSourceType.unknown,
      id: 'savedKaraoke',
      name: const QueueItemSourceName(type: QueueItemSourceNameType.preTranslated, pretranslatedName: 'Mashups'),
    ),
  );

  test('the lyrics move only while the remix itself plays, not another mix in its place', () {
    final singer = BaseItemDto.fromJson({
      'Id': 'a',
      'Name': 'Singer song',
      'RunTimeTicks': 200 * second,
      'Artists': ['Singer'],
    });
    final timeline = const LyricsTimeline(tempo: 1.1, offset: Duration(seconds: 2)).ofSong(singer);
    final track = remix({LyricsTimeline.key: timeline.toJson(), 'downloadedTrackPath': r'C:\saved\mashup.flac'});
    expect(LyricsTimeline.playing(track, 'C:/saved/mashup.flac')?.tempo, 1.1);
    expect(LyricsTimeline.playing(track, 'C:/karaoke/singer.flac'), isNull);
    expect(LyricsTimeline.playing(track, null), isNull);
    expect(
      LyricsTimeline.playing(remix({'downloadedTrackPath': 'C:/saved/mashup.flac'}), 'C:/saved/mashup.flac'),
      isNull,
    );

    // Looking lyrics up by name uses the original song's title and length, not the remix's.
    final shown = BaseItemDto.fromJson({
      'Id': 'a',
      'Name': 'Singer over Band',
      'RunTimeTicks': 300 * second,
      'Artists': ['Singer', 'Band'],
    });
    final original = LyricsTimeline.of(track)!.original(shown);
    expect((original.id.raw, original.name, original.runTimeTicks), ('a', 'Singer song', 200 * second));
    expect(original.artists, ['Singer']);
    expect(shown.name, 'Singer over Band');
    expect(const LyricsTimeline(tempo: 1, offset: Duration.zero).original(shown), same(shown));

    // The track lasts as long as what plays: the remix (here the backing song's length), or the singer's song.
    expect(LyricsTimeline.lengthWhile(track, 'C:/saved/mashup.flac'), const Duration(seconds: 300));
    expect(LyricsTimeline.lengthWhile(track, 'C:/karaoke/singer.flac'), const Duration(seconds: 200));
    expect(LyricsTimeline.lengthWhile(remix({'downloadedTrackPath': 'x'}), 'x'), isNull);
  });
}
