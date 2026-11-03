import 'dart:async';
import 'dart:math';

import 'package:finamp/services/playback_recovery.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';

// Exercise the real vendored AudioPlayer through its platform channels. Android
// ignores seek in the error/idle state, and load without an index starts at zero.
class _NativeAudio {
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late MockStreamHandlerEventSink events;
  final ready = Completer<void>();
  final loads = <int>[];
  final startPositions = <int?>[];
  final broken = <int>{};
  bool idle = false;
  int index = 0, seeks = 0, generation = 0;
  Completer<void>? loading, release;

  void install() {
    messenger.setMockMethodCallHandler(const MethodChannel('com.ryanheise.just_audio.methods'), (call) async {
      if (call.method == 'init') {
        final id = (call.arguments as Map<Object?, Object?>)['id']! as String;
        messenger.setMockStreamHandler(
          EventChannel('com.ryanheise.just_audio.events.$id'),
          MockStreamHandler.inline(
            onListen: (_, sink) {
              events = sink;
              if (!ready.isCompleted) ready.complete();
            },
          ),
        );
        messenger.setMockStreamHandler(
          EventChannel('com.ryanheise.just_audio.data.$id'),
          MockStreamHandler.inline(onListen: (_, _) {}),
        );
        messenger.setMockMethodCallHandler(MethodChannel('com.ryanheise.just_audio.methods.$id'), _handle);
      }
      return <String, Object?>{};
    });
  }

  Future<Object?> _handle(MethodCall call) async {
    final args = call.arguments as Map<Object?, Object?>? ?? {};
    if (call.method == 'load') {
      await ready.future;
      final owner = ++generation;
      final target = args['initialIndex'] as int? ?? 0;
      loads.add(target);
      startPositions.add(args['initialPosition'] as int?);
      if (release != null) {
        final wait = release!;
        release = null;
        loading?.complete();
        await wait.future;
      }
      if (owner != generation) throw PlatformException(code: '10000000', message: 'Connection aborted');
      index = target;
      idle = broken.contains(target);
      emit();
      if (idle) throw PlatformException(code: '0', message: 'Source error', details: {'index': index});
      return {'duration': const Duration(minutes: 3).inMicroseconds};
    }
    if (call.method == 'seek') {
      seeks++;
      if (!idle) {
        index = args['index'] as int? ?? index;
        emit();
      }
    }
    return <String, Object?>{};
  }

  void emit() => events.success({
    'processingState': idle ? 0 : 3,
    'updateTime': DateTime.now().millisecondsSinceEpoch,
    'updatePosition': 0,
    'bufferedPosition': 0,
    'duration': const Duration(minutes: 3).inMicroseconds,
    'currentIndex': index,
    if (idle) 'errorCode': 0,
    if (idle) 'errorMessage': 'Source error',
  });

  Future<void> fail(AudioPlayer player) async {
    final failed = player.processingStateStream.firstWhere((state) => state == ProcessingState.idle);
    idle = true;
    broken.add(index);
    emit();
    await failed;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _NativeAudio native;
  late AudioPlayer player;
  late ShuffleOrder order;
  var ownsQueue = true;
  final synchronizedIndices = <int>[];

  Future<void> recover({int maxSkips = 3, void Function(Object)? onFailure}) => recoverPlaybackAfterError(
    player: player,
    ownsQueue: () => ownsQueue,
    shuffleOrder: order,
    maxSkips: maxSkips,
    onFailure: onFailure,
    duringReload: (index, reload) async {
      synchronizedIndices.add(index);
      await reload();
    },
  );

  setUp(() async {
    ownsQueue = true;
    synchronizedIndices.clear();
    native = _NativeAudio()..install();
    player = AudioPlayer(
      handleInterruptions: false,
      handleAudioSessionActivation: false,
      androidApplyAudioAttributes: false,
    );
    addTearDown(player.dispose);
    order = DefaultShuffleOrder(random: Random(8));
    await player.setAudioSources(
      [for (var i = 0; i < 5; i++) AudioSource.uri(Uri.parse('file:///track-$i.mp3'), tag: 'track-$i')],
      initialIndex: 0,
      shuffleOrder: order,
    );
    await player.play();
    native.loads.clear();
    native.startPositions.clear();
  });

  Future<bool> reload(Duration position) => reloadAfterError(
    player: player,
    ownsQueue: () => ownsQueue,
    shuffleOrder: order,
    position: position,
    duringReload: (index, reload) async {
      synchronizedIndices.add(index);
      await reload();
    },
  );

  test("the decoder giving up is told apart from other errors", () {
    expect(
      isDecoderFailure(
        PlayerException(
          1,
          'MediaCodecAudioRenderer error, index=1, format=Format(0, null, null, audio/opus, null, -1, und, '
          '[-1, -1, -1.0, null], [2, 48000]), format_supported=YES [ERROR_CODE_DECODING_FAILED <- k <- CodecException]',
          3,
        ),
      ),
      isTrue,
    );
    expect(isDecoderFailure(PlayerException(0, 'Source error', 3)), isFalse);
    expect(isDecoderFailure(Exception('ERROR_CODE_DECODING_FAILED')), isFalse);
  });

  test('after the decoder gives up, the same track loads again where it was, still paused', () async {
    await player.seek(Duration.zero, index: 2);
    await player.pause();
    await native.fail(player);
    // The decoder works again once the sound has moved to the new output.
    native.broken.clear();
    native.loads.clear();
    native.startPositions.clear();
    expect(await reload(const Duration(seconds: 90)), isTrue);
    expect(native.loads, [2]);
    expect(native.startPositions, [const Duration(seconds: 90).inMicroseconds]);
    expect(player.currentIndex, 2);
    expect(player.audioSources, hasLength(5));
    expect(player.playing, isFalse);
    expect(synchronizedIndices, [2]);
  });

  test('a shuffled queue keeps its order when a track loads again', () async {
    await player.setShuffleModeEnabled(true);
    final indices = List<int>.of(player.shuffleIndices);
    await native.fail(player);
    native.broken.clear();
    final current = player.currentIndex!;
    expect(await reload(const Duration(seconds: 5)), isTrue);
    expect(player.shuffleIndices, indices);
    expect(player.currentIndex, current);
    expect(synchronizedIndices, [indices.indexOf(current)]);
  });

  test("a track that won't load again is reported, so it can be skipped", () async {
    await native.fail(player);
    expect(await reload(const Duration(seconds: 30)), isFalse);
  });

  for (final owned in [true, false]) {
    test(
      "the queue changing as a track loads again ${owned ? 'is reported' : "isn't reported once a newer queue took over"}",
      () async {
        await native.fail(player);
        ownsQueue = owned;
        final reloaded = await reloadAfterError(
          player: player,
          ownsQueue: () => ownsQueue,
          shuffleOrder: order,
          position: const Duration(seconds: 30),
          duringReload: (_, _) async => throw StateError('Playback recovery queue changed'),
        );
        expect(reloaded, !owned);
      },
    );
  }

  test("a track failing again after a newer queue took over isn't reported, so nothing is skipped", () async {
    await native.fail(player);
    native.loading = Completer<void>();
    final release = native.release = Completer<void>();
    final reloading = reload(const Duration(seconds: 30));
    await native.loading!.future;
    ownsQueue = false;
    release.complete();
    expect(await reloading, isTrue);
  });

  test("a track's progress is kept by the track, not by its place in the queue", () {
    final last = LastPlayed()..note('a', const Duration(seconds: 90));
    // Moved in the queue while paused: still the same track, so still at 1:30.
    expect(last.of('a'), const Duration(seconds: 90));
    expect(last.of('b'), Duration.zero, reason: "another track's progress isn't used");
    last.note('b', const Duration(seconds: 12));
    expect(last.of('a'), Duration.zero);
    expect(last.of('b'), const Duration(seconds: 12));
  });

  test('a track gets one more try after the decoder gives up, not one per failure', () {
    final retries = DecoderRetries();
    final now = DateTime(2026, 11, 1, 8, 39);
    expect(retries.allow('a', now), isTrue);
    expect(retries.allow('a', now.add(const Duration(seconds: 20))), isFalse, reason: 'failed again: damaged');
    expect(retries.allow('b', now.add(const Duration(seconds: 30))), isTrue);
    expect(retries.allow('a', now.add(const Duration(minutes: 5))), isTrue, reason: 'a new disconnect, later');
  });

  test('the old seek followed by load retries the first failed song', () async {
    await native.fail(player);
    await player.seek(Duration.zero, index: player.nextIndex);
    await expectLater(player.load(), throwsA(isA<PlayerException>()));
    expect(native.loads.last, 0);
    expect(native.index, 0);
  });

  test('recovery loads the next song directly and retains the entire playlist', () async {
    final sources = List<AudioSource>.of(player.audioSources);
    await native.fail(player);
    await recover();
    expect(native.loads, [1]);
    expect(native.seeks, 0);
    expect(player.currentIndex, 1);
    expect(player.audioSources, orderedEquals(sources));
    expect(player.playing, isTrue);
    expect(synchronizedIndices, [1]);
  });

  test('shuffled recovery preserves order, source tags and the effective queue index', () async {
    await player.setShuffleModeEnabled(true);
    final indices = List<int>.of(player.shuffleIndices);
    final next = player.nextIndex;
    await native.fail(player);
    await recover();
    expect(native.loads, [next]);
    expect(player.shuffleIndices, indices);
    expect(order.indices, indices);
    expect(player.currentIndex, next);
    expect(player.sequenceState.currentSource?.tag, 'track-$next');
    expect(synchronizedIndices, [indices.indexOf(next!)]);
    // Explicit shuffle still uses the original policy after recovery.
    await player.shuffle();
    expect(player.shuffleIndices, unorderedEquals(indices));
  });

  test('a second broken song is skipped without returning to the first one', () async {
    final failures = <Object>[];
    native.broken.add(1);
    await native.fail(player);
    await recover(onFailure: failures.add);
    expect(native.loads, [1, 2]);
    expect(player.currentIndex, 2);
    expect(player.playing, isTrue);
    expect(failures, hasLength(1));
  });

  test('consecutive failures stop after the retry budget and retain the queue', () async {
    native.broken.addAll([1, 2, 3, 4]);
    await native.fail(player);
    await recover(maxSkips: 2);
    expect(native.loads, [1, 2]);
    expect(player.playing, isFalse);
    expect(player.audioSources, hasLength(5));
  });

  test('a pause during recovery is not undone after the song loads', () async {
    await native.fail(player);
    native.loading = Completer<void>();
    final release = native.release = Completer<void>();
    final recovering = recover();
    await native.loading!.future;
    final pausing = player.pause();
    release.complete();
    await Future.wait([recovering, pausing]);
    expect(player.currentIndex, 1);
    expect(player.playing, isFalse);
  });

  test('a newer playlist supersedes recovery without being restored or paused', () async {
    await native.fail(player);
    native.loading = Completer<void>();
    final release = native.release = Completer<void>();
    final recovering = recover();
    await native.loading!.future;
    ownsQueue = false;
    native.broken.clear();
    final replacing = player.setAudioSource(AudioSource.uri(Uri.parse('file:///new.mp3'), tag: 'new playlist'));
    release.complete();
    await Future.wait<Object?>([recovering, replacing]);
    expect(player.audioSources, hasLength(1));
    expect(player.sequenceState.currentSource?.tag, 'new playlist');
    expect(player.playing, isTrue);
  });

  test('an obsolete error cannot load or pause a newer queue', () async {
    ownsQueue = false;
    await recover();
    expect(native.loads, isEmpty);
    expect(player.playing, isTrue);
  });

  test('repeat-all does not retry the failed song when every other entry failed', () async {
    await player.setLoopMode(LoopMode.all);
    native.broken.addAll([1, 2, 3, 4]);
    await native.fail(player);
    await recover(maxSkips: 10);
    expect(native.loads, [1, 2, 3, 4]);
    expect(player.playing, isFalse);
  });
}
