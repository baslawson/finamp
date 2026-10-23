import 'package:audio_service/audio_service.dart';
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

void main() {
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
