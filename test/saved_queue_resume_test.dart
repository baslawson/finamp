// AudioDevice can't be built without the experimental AudioDeviceType.
// ignore_for_file: experimental_member_use

import 'dart:async';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:finamp/services/network_status.dart';
import 'package:finamp/services/playback_recovery.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late SavedQueueResume resume;

  setUp(() {
    NetworkStatus.hasNetwork = () async => true;
    NetworkStatus.changes = () => const Stream.empty();
    resume = SavedQueueResume();
  });

  test("a press while Android keeps the network away plays once the queue loads", () async {
    var attempts = 0;
    final playable = await resume.resume((_) async {
      if (++attempts < 3) throw const SocketException("Software caused connection abort");
      return true;
    }, firstPause: Duration.zero);
    expect(playable, isTrue);
    expect(attempts, 3);
  });

  test("pausing while it waits cancels the press", () async {
    var attempts = 0;
    final playable = resume.resume((_) async {
      attempts++;
      throw const SocketException("Gone");
    }, firstPause: const Duration(milliseconds: 500));
    await pumpEventQueue();
    resume.paused();
    expect(await playable, isFalse, reason: "the listener paused, so nothing should start");
    expect(attempts, 1);
  });

  test("pausing during the very first load cancels the press, with the queue still loaded", () async {
    final loading = Completer<bool>();
    final playable = resume.resume((_) => loading.future);
    resume.paused();
    loading.complete(true);
    expect(await playable, isFalse);
  });

  test("a pause before the press doesn't cancel it", () async {
    resume.paused();
    var attempts = 0;
    final playable = await resume.resume((_) async {
      if (++attempts == 1) throw const SocketException("Gone");
      return true;
    }, firstPause: Duration.zero);
    expect(playable, isTrue);
  });

  test("pressing again after a pause still plays", () async {
    var attempts = 0;
    final failing = Completer<void>();
    final first = resume.resume((_) async {
      if (++attempts == 1) {
        failing.complete();
        throw const SocketException("Gone");
      }
      return true;
    }, firstPause: const Duration(milliseconds: 20));
    await failing.future;
    resume.paused();
    final second = resume.resume((_) async => false, firstPause: Duration.zero);
    expect(await first, isTrue);
    expect(await second, isTrue);
  });

  test("presses during a load share it", () async {
    var attempts = 0;
    final loading = Completer<bool>();
    Future<bool> load(bool Function() _) {
      attempts++;
      return loading.future;
    }

    final first = resume.resume(load);
    final second = resume.resume(load);
    loading.complete(true);
    expect(await first, isTrue);
    expect(await second, isTrue);
    expect(attempts, 1);
  });

  test("the load can check that the press still stands", () async {
    late bool Function() stillWanted;
    final loading = Completer<bool>();
    final playable = resume.resume((check) {
      stillWanted = check;
      return loading.future;
    });
    expect(stillWanted(), isTrue);
    resume.paused();
    expect(stillWanted(), isFalse);
    loading.complete(true);
    await playable;
  });

  group("losing the sound while a press waits", () {
    late StreamController<AudioInterruptionEvent> interruptions;
    late StreamController<void> becomingNoisy;
    late StreamController<AudioDevicesChangedEvent> devicesChanged;
    late bool Function() stillWanted;
    late Completer<bool> loading;
    late Future<bool> playable;

    AudioDevice device({required bool isOutput}) => AudioDevice(
      id: "1",
      name: "Speaker",
      isInput: !isOutput,
      isOutput: isOutput,
      type: isOutput ? AudioDeviceType.bluetoothA2dp : AudioDeviceType.bluetoothSco,
    );

    setUp(() {
      interruptions = StreamController(sync: true);
      becomingNoisy = StreamController(sync: true);
      devicesChanged = StreamController(sync: true);
      resume.watch(
        interruptions: interruptions.stream,
        becomingNoisy: becomingNoisy.stream,
        devicesChanged: devicesChanged.stream,
      );
      loading = Completer();
      playable = resume.resume((check) {
        stillWanted = check;
        return loading.future;
      });
    });

    tearDown(() async {
      loading.complete(true);
      await playable;
    });

    test("headphones coming out cancel it", () {
      becomingNoisy.add(null);
      expect(stillWanted(), isFalse);
    });

    test("a speaker disconnecting cancels it, also without the audio focus", () {
      devicesChanged.add(AudioDevicesChangedEvent(devicesRemoved: {device(isOutput: true)}));
      expect(stillWanted(), isFalse);
    });

    test("another app or a call taking the sound cancels it", () {
      interruptions.add(AudioInterruptionEvent(true, AudioInterruptionType.pause));
      expect(stillWanted(), isFalse);
    });

    test("an interruption of unknown kind cancels it", () {
      interruptions.add(AudioInterruptionEvent(true, AudioInterruptionType.unknown));
      expect(stillWanted(), isFalse);
    });

    test("what doesn't take the sound away leaves it standing", () {
      interruptions.add(AudioInterruptionEvent(true, AudioInterruptionType.duck));
      interruptions.add(AudioInterruptionEvent(false, AudioInterruptionType.pause));
      devicesChanged.add(AudioDevicesChangedEvent(devicesRemoved: {device(isOutput: false)}));
      devicesChanged.add(AudioDevicesChangedEvent(devicesAdded: {device(isOutput: true)}));
      expect(stillWanted(), isTrue);
    });
  });

  test("a press after the last one finished loads again", () async {
    var attempts = 0;
    Future<bool> load(bool Function() _) async {
      attempts++;
      return true;
    }

    await resume.resume(load);
    await resume.resume(load);
    expect(attempts, 2);
  });

  test("it says once when there was no connection after all", () async {
    var told = 0;
    final first = resume.resume(
      (_) async => throw const SocketException("Gone"),
      patience: Duration.zero,
      onNoConnection: () => told++,
    );
    final second = resume.resume(
      (_) async => throw const SocketException("Gone"),
      patience: Duration.zero,
      onNoConnection: () => told++,
    );
    await expectLater(first, throwsA(isA<SocketException>()));
    await expectLater(second, throwsA(isA<SocketException>()));
    expect(told, 1);
  });

  test("other failures aren't blamed on the connection", () async {
    var told = 0;
    await expectLater(
      resume.resume((_) async => throw StateError("Broken"), onNoConnection: () => told++),
      throwsStateError,
    );
    expect(told, 0);
  });
}
