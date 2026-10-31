import 'package:audio_service/audio_service.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/crossfade_service.dart';
import 'package:finamp/services/dj_intro_timing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

const _s = Duration(seconds: 1);

LyricLine _line(double seconds, String text) =>
    LyricLine(text: text, start: (seconds * Duration.microsecondsPerSecond).round() * 10);

FinampQueueItem _item(String id) => FinampQueueItem(
  item: MediaItem(
    id: id,
    title: id,
    extras: {
      'itemJson': {'Id': id, 'Name': id},
    },
  ),
  source: QueueItemSource.rawId(
    type: QueueItemSourceType.unknown,
    id: 'mix',
    name: const QueueItemSourceName(type: QueueItemSourceNameType.preTranslated, pretranslatedName: 'Mix'),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('plan', () {
    test('without vocals the line is centred on the change, as before', () {
      expect(DjIntroTiming.plan(_s * 10), (beforeChange: _s * 5, afterChange: Duration.zero));
    });

    test('a line that fits in the intro starts late enough to end before the singing', () {
      final plan = DjIntroTiming.plan(_s * 8, vocals: _s * 15);
      expect(plan.beforeChange, Duration.zero);
      expect(plan.afterChange, _s * 7 - DjIntroTiming.margin);
    });

    test('a very long intro waits at most the longest wait', () {
      expect(DjIntroTiming.plan(_s * 5, vocals: _s * 90).afterChange, DjIntroTiming.longestWait);
    });

    test('a line longer than the intro starts over the end of this song and still ends before the vocals', () {
      final plan = DjIntroTiming.plan(_s * 12, vocals: _s * 6);
      expect(plan.afterChange, Duration.zero);
      expect(plan.beforeChange, _s * 12 - (_s * 6 - DjIntroTiming.margin));
    });

    test('singing right at the start: the line finishes as the next song comes in', () {
      expect(DjIntroTiming.plan(_s * 10, vocals: _s), (beforeChange: _s * 10, afterChange: Duration.zero));
      // From the log: a 20 s line before a song whose vocals start at 1.08 s, 7.4 s of crossfade.
      final start = DjIntroTiming.startBeforeEnd(
        DjIntroTiming.plan(const Duration(milliseconds: 19980), vocals: const Duration(milliseconds: 1080)),
        overlap: const Duration(milliseconds: 7427),
      );
      expect(
        start - const Duration(milliseconds: 19980),
        const Duration(milliseconds: 7427),
        reason: 'ends as it is heard',
      );
    });

    test('a very long line before immediate singing starts at most the longest lead early', () {
      expect(DjIntroTiming.plan(_s * 40, vocals: _s).beforeChange, DjIntroTiming.longestLead);
    });
  });

  group('firstSungLine', () {
    test('skips empty and instrumental marker lines', () {
      expect(
        DjIntroTiming.firstSungLine([_line(0, ''), _line(3.5, '♪'), _line(12.25, 'Hello darkness')]),
        const Duration(milliseconds: 12250),
      );
    });

    test('unsynced lyrics give no timing', () {
      expect(DjIntroTiming.firstSungLine([LyricLine(text: 'Hello')]), isNull);
      expect(DjIntroTiming.firstSungLine(null), isNull);
    });
  });

  test('the setting is on by default and remembered', () async {
    final previous = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    addTearDown(() => SharedPreferencesAsyncPlatform.instance = previous);
    DjIntroTiming.reset();
    expect(await DjIntroTiming.isEnabled(), true);
    await DjIntroTiming.setEnabled(false);
    DjIntroTiming.reset();
    expect(await DjIntroTiming.isEnabled(), false);
  });

  group('under a crossfade', () {
    tearDown(() => CrossfadeService.settingsForTesting = (seconds: 0, keepAlbumsGapless: true));

    test('a line that fits in the intro starts before the change, so it still ends before the vocals', () {
      // A 10 s crossfade, an 8 s line and vocals 15 s into the next song: that song is heard 10 s before this one's
      // file ends, so waiting for the change would end the line 3 s into the singing.
      CrossfadeService.settingsForTesting = (seconds: 10, keepAlbumsGapless: false);
      final overlap = CrossfadeService.overlapBefore(_item('a'), _item('b'), _s * 200);
      expect(overlap, _s * 10);
      final plan = DjIntroTiming.plan(_s * 8, vocals: _s * 15);
      final start = DjIntroTiming.startBeforeEnd(plan, overlap: overlap);
      expect(start, _s * 3 + DjIntroTiming.margin);
      // Where the next song is when the line ends: 10 s of overlap less the start, plus the line.
      expect(overlap - start + _s * 8, _s * 15 - DjIntroTiming.margin);
    });

    test('without a crossfade the plan counts from the change, as before', () {
      expect(CrossfadeService.overlapBefore(_item('a'), _item('b'), _s * 200), Duration.zero);
      final plan = DjIntroTiming.plan(_s * 8, vocals: _s * 15);
      expect(DjIntroTiming.startBeforeEnd(plan), -plan.afterChange);
      expect(DjIntroTiming.startBeforeEnd(DjIntroTiming.plan(_s * 10)), _s * 5);
    });
  });
}
