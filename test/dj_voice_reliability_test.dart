import 'dart:async';

import 'package:finamp/services/ai_service.dart';
import 'package:finamp/services/dj_voice_playback.dart';
import 'package:finamp/services/dj_voice_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';

void main() {
  const line = 'Next up, a little treasure from Queen. Settle in and enjoy the music, my friends.';

  group('voice player completion and error handling', () {
    late StreamController<ProcessingState> states;
    late StreamController<Object> errors;
    setUp(() {
      states = StreamController<ProcessingState>.broadcast();
      errors = StreamController<Object>.broadcast();
    });
    tearDown(() async {
      await states.close();
      await errors.close();
    });

    Future<ProcessingState> play(Future<void> Function() start, {Duration? timeout}) => waitForDjPlayback(
      states: states.stream,
      errors: errors.stream,
      play: start,
      currentState: () => ProcessingState.completed,
      timeout: timeout ?? const Duration(seconds: 1),
    );

    void expectReleased() {
      expect(states.hasListener, isFalse);
      expect(errors.hasListener, isFalse);
    }

    test('dismissal releases a stalled native player without needing an idle event', () async {
      final native = Completer<void>(), cancelled = Completer<void>();
      var restored = false;
      final playing = withDjDucking(
        duck: () async {},
        speak: () => waitForDjPlayback(
          states: states.stream,
          errors: errors.stream,
          play: () => native.future,
          currentState: () => ProcessingState.buffering,
          timeout: const Duration(seconds: 10),
          cancelled: cancelled.future,
        ),
        stopVoice: () async {},
        restore: () async {
          restored = true;
        },
      );
      await Future<void>.delayed(Duration.zero);
      cancelled.complete();
      await playing.timeout(const Duration(seconds: 1));
      expect(restored, isTrue);
      expectReleased();
      native.completeError(StateError('late failure from disconnected output'));
      await Future<void>.delayed(Duration.zero);
    });

    test('a rejected play command releases the processing listener without waiting for idle', () async {
      await expectLater(
        play(() async {
          throw StateError('play rejected');
        }),
        throwsStateError,
      );
      expectReleased();
    });

    test('a decoder error releases listeners while the play future is still pending', () async {
      final pending = Completer<void>();
      final playing = play(() => pending.future);
      final assertion = expectLater(playing, throwsStateError);
      errors.add(StateError('unsupported audio'));
      await assertion;
      expectReleased();
      pending.complete();
    });

    test('a stuck voice times out and releases all listeners', () async {
      final pending = Completer<void>();
      await expectLater(
        play(() => pending.future, timeout: const Duration(milliseconds: 20)),
        throwsA(isA<TimeoutException>()),
      );
      expectReleased();
      pending.complete();
    });

    test('stopping the voice finishes playback even if play never completes', () async {
      final pending = Completer<void>();
      final playing = play(() => pending.future);
      states.add(ProcessingState.idle);
      expect(await playing, ProcessingState.idle);
      expectReleased();
      pending.complete();
    });

    test('a late play failure after completion is consumed', () async {
      final pending = Completer<void>();
      final playing = play(() => pending.future);
      states.add(ProcessingState.completed);
      expect(await playing, ProcessingState.completed);
      pending.completeError(StateError('late native error'));
      await Future<void>.delayed(Duration.zero);
      expectReleased();
    });

    test('a synchronous native failure also releases listeners', () async {
      await expectLater(
        play(() {
          throw StateError('channel closed');
        }),
        throwsStateError,
      );
      expectReleased();
    });

    test('slow loading and buffering do not finish an announcement early', () async {
      final pending = Completer<void>();
      var ended = false;
      final playing = play(() => pending.future);
      unawaited(
        playing.then((_) {
          ended = true;
        }),
      );
      for (final state in [ProcessingState.loading, ProcessingState.buffering, ProcessingState.ready]) {
        states.add(state);
        await Future<void>.delayed(Duration.zero);
        expect(ended, isFalse, reason: state.name);
      }
      states.add(ProcessingState.completed);
      expect(await playing, ProcessingState.completed);
      expectReleased();
      pending.complete();
    });

    test('a reconnect error after buffering still stops the voice and restores music once', () async {
      final pending = Completer<void>();
      var stops = 0, restores = 0;
      final playing = withDjDucking(
        duck: () async {},
        speak: () => play(() => pending.future),
        stopVoice: () async {
          stops++;
        },
        restore: () async {
          restores++;
        },
      );
      final assertion = expectLater(playing, throwsStateError);
      await Future<void>.delayed(Duration.zero);
      states.add(ProcessingState.buffering);
      errors.add(StateError('audio output disconnected'));
      await assertion;
      expect(stops, 1);
      expect(restores, 1);
      expectReleased();
      pending.complete();
    });
  });

  test('slow characters accept natural pauses without treating them as repeated speech', () {
    for (final character in [
      DjVoiceCharacter.trailer,
      DjVoiceCharacter.meditation,
      DjVoiceCharacter.documentary,
      DjVoiceCharacter.pirate,
      DjVoiceCharacter.actionHero,
    ]) {
      expect(
        AiService.tooLongFor(line, const Duration(seconds: 11), minimumWordsPerSecond: character.minimumWordsPerSecond),
        isFalse,
        reason: character.name,
      );
    }
    expect(AiService.tooLongFor(line, const Duration(seconds: 11)), isTrue);
    for (final character in DjVoiceCharacter.values) {
      expect(
        AiService.tooLongFor(line, const Duration(seconds: 46), minimumWordsPerSecond: character.minimumWordsPerSecond),
        isTrue,
        reason: character.name,
      );
    }
  });

  test('music is restored when a new voice fails to load or play', () async {
    final events = <String>[];
    await expectLater(
      withDjDucking(
        duck: () async {
          events.add('duck');
        },
        speak: () async {
          events.add('failed clip');
          throw StateError('decoder failed');
        },
        stopVoice: () async {
          events.add('stop voice');
        },
        restore: () async {
          events.add('restore music');
        },
      ),
      throwsStateError,
    );
    expect(events, ['duck', 'failed clip', 'stop voice', 'restore music']);
  });

  test('a voice-player stop failure cannot leave the music permanently ducked', () async {
    var restored = false;
    await expectLater(
      withDjDucking(
        duck: () async {},
        speak: () async {},
        stopVoice: () async {
          throw StateError('native player failed');
        },
        restore: () async {
          restored = true;
        },
      ),
      throwsStateError,
    );
    expect(restored, isTrue);
  });

  test('a cancelled announcement still stops the voice and restores the music', () async {
    var stopped = false, restored = false;
    await withDjDucking(
      duck: () async {},
      speak: () async {},
      stopVoice: () async {
        stopped = true;
      },
      restore: () async {
        restored = true;
      },
    );
    expect(stopped && restored, isTrue);
  });

  test('a failure while starting the volume dip still releases it', () async {
    var restored = false;
    await expectLater(
      withDjDucking(
        duck: () async {
          throw StateError('audio channel interrupted');
        },
        speak: () async {
          fail('should not play after duck failed');
        },
        stopVoice: () async {},
        restore: () async {
          restored = true;
        },
      ),
      throwsStateError,
    );
    expect(restored, isTrue);
  });
}
