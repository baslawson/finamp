import 'dart:async';

import 'package:finamp/services/karaoke_playback.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a failed mix restores the original audio and position before resuming', () async {
    var audio = 'original', position = 42000;
    final events = <String>[];
    await expectLater(
      reloadKaraokeAudio(
        pause: () async {
          events.add('pause');
        },
        stillSelected: () => true,
        load: () async {
          audio = 'broken mix';
          position = 0;
          throw StateError('decoder failed');
        },
        ownsLoad: () => true,
        restore: () async {
          audio = 'original';
          position = 42000;
          events.add('restore');
        },
        resume: () {
          expect(audio, 'original');
          expect(position, 42000);
          events.add('resume');
        },
      ),
      throwsStateError,
    );
    expect(events, ['pause', 'restore', 'resume']);
  });

  for (final fails in [true, false]) {
    test('a superseded ${fails ? 'failed' : 'successful'} mix never restores or resumes the previous queue', () async {
      final started = Completer<void>(), release = Completer<void>();
      var generation = 1, queue = 'old', position = 42000;
      final operation = reloadKaraokeAudio(
        pause: () async {},
        stillSelected: () => generation == 1,
        load: () async {
          started.complete();
          await release.future;
          if (fails) throw StateError('old load interrupted');
        },
        ownsLoad: () => generation == 1,
        restore: () async {
          fail('must not replace the newer queue');
        },
        resume: () {
          fail('must not resume another queue');
        },
      );
      final result = fails ? expectLater(operation, throwsStateError) : operation;
      await started.future;
      generation++;
      queue = 'new album';
      position = 500;
      release.complete();
      await result;
      expect(queue, 'new album');
      expect(position, 500);
    });
  }

  test('skipping during pause cancels the mix before its source is applied', () async {
    var current = 'first song';
    await reloadKaraokeAudio(
      pause: () async {
        current = 'second song';
      },
      stillSelected: () => current == 'first song',
      load: () async {
        fail('must not load the old song');
      },
      ownsLoad: () => true,
      restore: () async {
        fail('nothing was changed');
      },
      resume: () {
        fail('the user now controls the second song');
      },
    );
    expect(current, 'second song');
  });

  test('an unsuccessful restore reports the error without starting unusable audio', () async {
    await expectLater(
      reloadKaraokeAudio(
        pause: () async {},
        stillSelected: () => true,
        load: () async {
          throw StateError('mix missing');
        },
        ownsLoad: () => true,
        restore: () async {
          throw StateError('original unavailable');
        },
        resume: () {
          fail('cannot resume a failed restore');
        },
      ),
      throwsA(isA<StateError>().having((e) => e.message, 'message', 'original unavailable')),
    );
  });

  test('changing the guide while paused keeps playback paused', () async {
    var loaded = false;
    await reloadKaraokeAudio(
      pause: () async {},
      stillSelected: () => true,
      load: () async {
        loaded = true;
      },
      ownsLoad: () => true,
      restore: () async {
        fail('load succeeded');
      },
    );
    expect(loaded, isTrue);
  });
}
