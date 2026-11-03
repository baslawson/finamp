import 'package:audio_service/audio_service.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/services/ai_service.dart';
import 'package:finamp/services/crossfade_service.dart';
import 'package:flutter_test/flutter_test.dart';

MediaItem _track(String album, int index) => MediaItem(
  id: "$album$index",
  title: "Track $index",
  extras: {
    "itemJson": {"AlbumId": album, "IndexNumber": index},
  },
);

FinampQueueItem _entry(String track) => FinampQueueItem(
  item: MediaItem(
    id: track,
    title: track,
    extras: {
      'itemJson': {'Id': track, 'Name': track},
    },
  ),
  source: QueueItemSource.rawId(
    type: QueueItemSourceType.unknown,
    id: 'mix',
    name: const QueueItemSourceName(type: QueueItemSourceNameType.preTranslated, pretranslatedName: 'Mix'),
  ),
);

void main() {
  test("a change held for the news doesn't crossfade, only that one, until the next song plays", () {
    final (current, next, other) = (_entry('a'), _entry('b'), _entry('c'));
    addTearDown(CrossfadeService.releaseChange);
    expect(CrossfadeService.fadeSeconds('a', 'b', 8), 8);
    expect(CrossfadeService.holdChange(current, next), isTrue);
    expect(CrossfadeService.fadeSeconds('a', 'b', 8), 0);
    expect(CrossfadeService.fadeSeconds('b', 'c', 8), 8, reason: 'only that change');
    expect(CrossfadeService.fadeSeconds('a', 'c', 8), 8);
    expect(CrossfadeService.holdChange(current, next), isTrue, reason: 'asked again on every tick');
    CrossfadeService.releaseChange(unlessEntry: current.id);
    expect(CrossfadeService.fadeSeconds('a', 'b', 8), 0, reason: 'its song still plays');
    CrossfadeService.releaseChange(unlessEntry: next.id);
    expect(CrossfadeService.fadeSeconds('a', 'b', 8), 8, reason: 'the next song plays');
    expect(CrossfadeService.holdChange(current, other), isTrue);
    CrossfadeService.releaseChange();
    expect(CrossfadeService.fadeSeconds('a', 'c', 8), 8);
  });

  test("crossfade keeps the overall loudness steady", () {
    for (final t in [0.0, 0.25, 0.5, 0.75, 1.0]) {
      final volumes = CrossfadeService.curve(t);
      expect(volumes.out * volumes.out + volumes.into * volumes.into, closeTo(1.0, 0.0001));
    }
    expect(CrossfadeService.curve(0).out, 1.0);
    expect(CrossfadeService.curve(1).into, 1.0);
  });

  test("consecutive album tracks stay gapless", () {
    expect(CrossfadeService.keepsGapless(_track("a", 1), _track("a", 2)), isTrue);
    expect(CrossfadeService.keepsGapless(_track("a", 1), _track("a", 5)), isFalse);
    expect(CrossfadeService.keepsGapless(_track("a", 1), _track("b", 2)), isFalse);
  });

  test("AI speech PCM gets a valid WAV header", () {
    final wav = AiService.wav(List.filled(480, 0), sampleRate: 24000);
    expect(wav.length, 44 + 480);
    expect(String.fromCharCodes(wav.sublist(0, 4)), "RIFF");
    expect(String.fromCharCodes(wav.sublist(8, 12)), "WAVE");
    // Sample rate, little endian.
    expect(wav[24] | wav[25] << 8 | wav[26] << 16, 24000);
  });
}
