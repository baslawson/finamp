import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:audio_service/audio_service.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/ai_service.dart';
import 'package:finamp/services/analyzer_service.dart';
import 'package:finamp/services/crossfade_service.dart';
import 'package:finamp/services/music_player_background_task.dart';
import 'package:finamp/services/playback_buffer_policy.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:integration_test/integration_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';
import 'package:rxdart/rxdart.dart';
import 'fixtures/crossfade_opus.dart';

const source = QueueItemSource.rawId(
  type: QueueItemSourceType.playlist,
  id: 'crossfade-regression',
  name: QueueItemSourceName(type: QueueItemSourceNameType.preTranslated, pretranslatedName: 'Crossfade test'),
);

class _Queue extends Fake implements QueueService {
  _Queue(this.entries);
  final List<FinampQueueItem> entries;
  int index = 0;
  @override
  FinampLoopMode get loopMode => FinampLoopMode.none;
  @override
  FinampQueueItem getCurrentTrack() => entries[index];
  @override
  FinampQueueInfo getQueue() => FinampQueueInfo(
    id: 'crossfade-test',
    previousTracks: entries.take(index).toList(),
    currentTrack: entries[index],
    nextUp: [],
    queue: entries.skip(index + 1).toList(),
    source: source,
    saveState: SavedQueueState.saving,
    sourceLibrary: null,
  );
}

/// Real native players with a minimal queue, independent of server availability.
class _Player extends Fake implements MusicPlayerBackgroundTask {
  _Player(this.native, this.files, this.testQueue) {
    native.currentIndexStream.listen((value) {
      if (value != null) testQueue.index = value;
    });
    native.playerStateStream.listen(
      (state) => playbackState.add(
        PlaybackState(
          playing: state.playing,
          processingState: AudioProcessingState.values.byName(state.processingState.name),
        ),
      ),
    );
  }
  final AudioPlayer native;
  final List<File> files;
  final _Queue testQueue;
  int seeks = 0;
  int userSeeks = 0;
  int normalizationRequests = 0, sourceRequests = 0;
  Completer<void>? seekGate;
  Completer<void>? normalizationGate;
  Uri? streamBase;
  File? bufferedCover;
  @override
  final playbackState = BehaviorSubject.seeded(PlaybackState());
  @override
  final mediaItem = BehaviorSubject<MediaItem?>();
  @override
  bool get karaokeActive => false;
  @override
  Duration? get playerDuration => native.duration;
  @override
  Duration get playbackPosition => native.position;
  @override
  double get speed => native.speed;
  @override
  String? get playerPlatformId => native.platformId;
  @override
  double get crossfadeBaseVolume => 1;
  @override
  double normalizationFactorFor(MediaItem track) => 1;
  @override
  Future<void> prepareNormalization(List<MediaItem> tracks) async {
    normalizationRequests++;
    await normalizationGate?.future;
  }

  @override
  Future<void> configureNormalization(String id, MediaItem track) async {}
  @override
  void forgetNormalization(String? id) {}
  @override
  Future<void> setTransitionVolume(double volume) => native.setVolume(volume);
  @override
  Future<void> setSpeed(double speed) => native.setSpeed(speed);
  @override
  Future<void> seek(Duration position, {bool userInitiated = true}) {
    if (userInitiated) userSeeks++;
    seeks++;
    if (seekGate != null && testQueue.index > 0) return seekGate!.future;
    return native.seek(position);
  }

  @override
  Future<AudioSource> audioSourceFor(FinampQueueItem item, {String? playSessionId}) async {
    sourceRequests++;
    if (bufferedCover != null) {
      return ClippingAudioSource(child: AudioSource.file(bufferedCover!.path), end: const Duration(seconds: 24));
    }
    if (streamBase != null) {
      return ClippingAudioSource(
        child: AudioSource.uri(streamBase!.resolve('next/${testQueue.entries.indexOf(item)}.webm')),
        end: const Duration(seconds: 24),
      );
    }
    return AudioSource.file(files[testQueue.entries.indexOf(item)].path);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('local Opus output baseline without a crossfade', (tester) async {
    final folder = await Directory((await getTemporaryDirectory()).path).createTemp('opus-baseline-');
    final file = await File('${folder.path}/baseline.webm').writeAsBytes(base64Decode(crossfadeOpusBase64));
    final native = AudioPlayer();
    const channel = MethodChannel('com.unicornsonlsd.finamp/crossfade');
    try {
      await native
          .setAudioSource(ClippingAudioSource(child: AudioSource.file(file.path), end: const Duration(seconds: 24)))
          .timeout(const Duration(seconds: 20));
      await channel.invokeMethod<void>('arm', {'main': native.platformId, 'next': 'no-secondary-baseline'});
      unawaited(native.play());
      final end = DateTime.now().add(const Duration(seconds: 16));
      while (DateTime.now().isBefore(end)) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final stats = await channel.invokeMapMethod<String, dynamic>('diagnostics');
      debugPrint('Local Opus baseline: $stats; position ${native.position}');
      // Hardware AudioTrack underruns are recorded, not treated as a mixer
      // assertion: this emulator can report them even with one local decoder.
      // The deterministic native harness asserts zero mixer-caused underruns.
      expect(native.playing, isTrue);
      expect(native.position, greaterThan(const Duration(seconds: 14)));
    } finally {
      await channel.invokeMethod<void>('disarm');
      await native.dispose();
      await folder.delete(recursive: true);
    }
  });
  testWidgets('streamed Opus completes catch-up with a slow main stream and network stalls', (tester) async {
    final opus = base64Decode(crossfadeOpusBase64);
    final folder = await Directory((await getTemporaryDirectory()).path).createTemp('crossfade-opus-test-');
    final buffered = await File('${folder.path}/buffered.webm').writeAsBytes(opus);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final incomingRelease = Completer<void>();
    final records = <String>[];
    var mainRequests = 0, networkStalls = 0;
    Future<void> serve(HttpRequest request) async {
      try {
        final slowMainCopy = request.uri.path.contains('/1.');
        records.add('HTTP ${request.uri.path} ${request.headers.value(HttpHeaders.rangeHeader) ?? 'from start'}');
        mainRequests++;
        // The live container has no end-of-file duration probe; clipping below
        // supplies the known duration without downloading the stalled copy.
        final range = slowMainCopy
            ? null
            : RegExp(r'bytes=(\d+)-(\d*)').firstMatch(request.headers.value(HttpHeaders.rangeHeader) ?? '');
        final start = range == null ? 0 : int.parse(range.group(1)!);
        final end = range == null || range.group(2)!.isEmpty
            ? opus.length - 1
            : min(opus.length - 1, int.parse(range.group(2)!));
        if (start >= opus.length) {
          request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          return;
        }
        request.response.headers.set(HttpHeaders.contentTypeHeader, 'audio/webm');
        request.response.headers.set(HttpHeaders.acceptRangesHeader, slowMainCopy ? 'none' : 'bytes');
        if (range != null) {
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/${opus.length}');
        }
        if (!slowMainCopy) request.response.contentLength = end - start + 1;
        for (var offset = start; offset <= end; offset += 2048) {
          request.response.add(opus.sublist(offset, min(end + 1, offset + 2048)));
          await request.response.flush();
          // Keep the outgoing/cover streams ready. Hold the main copy behind
          // the already-heard ~8 s until its boundary, then inject a 300 ms
          // stall and feed large chunks. Tiny HTTP flushes made the previous
          // test server slower than real time, obscuring the catch-up behavior.
          if (slowMainCopy) {
            if (offset == 8192) {
              await incomingRelease.future;
              networkStalls++;
              await Future<void>.delayed(const Duration(milliseconds: 300));
            }
            await Future<void>.delayed(const Duration(milliseconds: 250));
          }
        }
      } on SocketException {
        // Seeks and disposal can cancel an in-flight HTTP range.
      } on HttpException {
        // The player may close a duration probe as soon as it has the header.
      } finally {
        await request.response.close().catchError((Object _) {});
      }
    }

    server.listen((request) => unawaited(serve(request)));
    final base = Uri.parse('http://127.0.0.1:${server.port}/');
    final native = AudioPlayer(
      audioLoadConfiguration: AudioLoadConfiguration(
        androidLoadControl: AndroidLoadControl(
          minBufferDuration: Duration(seconds: 90),
          maxBufferDuration: Duration(seconds: 90),
          bufferForPlaybackDuration: Duration(seconds: 5),
          bufferForPlaybackAfterRebufferDuration: Duration(seconds: 10),
          targetBufferBytes: PlaybackBufferPolicy.mainBudget(PlaybackBufferPolicy.defaultBudgetBytes),
        ),
      ),
    );
    final entries = [
      for (var i = 0; i < 2; i++)
        FinampQueueItem(
          source: source,
          item: MediaItem(
            id: 'opus-$i',
            title: 'Streamed Opus $i',
            duration: const Duration(seconds: 24),
            extras: {'itemJson': BaseItemDto(id: BaseItemId('opus-$i'), name: 'Streamed Opus $i').toJson()},
          ),
        ),
    ];
    final queue = _Queue(entries);
    final player = _Player(native, [], queue)
      ..streamBase = base
      ..bufferedCover = buffered;
    final subscription = Logger.root.onRecord
        .where((r) => r.loggerName == 'CrossfadeService')
        .listen((r) => records.add(r.message));
    final oldSettings = await CrossfadeService.loadSettings();
    final oldAnalyzer = await AnalyzerService.getSettings();
    try {
      GetIt.instance.registerSingleton<QueueService>(queue);
      GetIt.instance.registerSingleton<MusicPlayerBackgroundTask>(player);
      await AnalyzerService.saveSettings(url: 'https://analyzer.invalid', token: 'test');
      await http.runWithClient(
        () => AnalyzerService.analysis(entries.map((entry) => entry.baseItemId.raw).toList()),
        () => MockClient(
          (_) async => http.Response(
            jsonEncode({
              for (final entry in entries) entry.baseItemId.raw: {'duration': 24, 'end': 20},
            }),
            200,
          ),
        ),
      );
      await native
          .setAudioSources([
            ClippingAudioSource(child: AudioSource.file(buffered.path), end: const Duration(seconds: 24)),
          ])
          .timeout(
            const Duration(seconds: 20),
            onTimeout: () {
              throw TestFailure('Opus preparation stalled: ${records.join('; ')}');
            },
          );
      await CrossfadeService.saveSettings((seconds: 4, keepAlbumsGapless: false));
      unawaited(native.play());
      DateTime? finished;
      Duration? previous;
      Duration maximumBacktrack = Duration.zero;
      var mainCopyAdded = false;
      final deadline = DateTime.now().add(const Duration(seconds: 65));
      while (DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 100));
        if (!mainCopyAdded && native.position >= const Duration(seconds: 21)) {
          // The cover copy is already playing. Make the main copy arrive late,
          // rather than opening it at t=0 and accidentally testing an HTTP
          // socket timeout while a response waits for the t=24 s boundary.
          mainCopyAdded = true;
          await native.addAudioSource(
            ClippingAudioSource(child: AudioSource.uri(base.resolve('main/1.webm')), end: const Duration(seconds: 24)),
          );
        }
        if (queue.index == 1) {
          if (!incomingRelease.isCompleted) incomingRelease.complete();
          if (previous != null) {
            final backwards = previous - native.position;
            if (backwards > maximumBacktrack) maximumBacktrack = backwards;
          }
          previous = native.position;
        }
        if (records.any((line) => line.contains('hand-over done in the main output'))) finished ??= DateTime.now();
        if (finished != null && DateTime.now().difference(finished) >= const Duration(seconds: 2)) break;
      }
      expect(finished, isNotNull, reason: records.join('\n'));
      expect(maximumBacktrack, lessThanOrEqualTo(const Duration(milliseconds: 100)), reason: records.join('\n'));
      expect(queue.index, 1);
      expect(native.playing, isTrue);
      expect(player.seeks, 0);
      expect(mainRequests, greaterThan(0));
      expect(player.sourceRequests, greaterThan(0));
      expect(networkStalls, greaterThan(0));
      final stats = await const MethodChannel(
        'com.unicornsonlsd.finamp/crossfade',
      ).invokeMapMethod<String, dynamic>('diagnostics');
      expect(
        stats?['drainedFrames'],
        greaterThan(0),
        reason: 'The streamed case must exercise decoder-independent ring output',
      );
      expect(records.where((line) => line.contains('scheduled by PCM timestamps')), hasLength(1));
      expect(
        records.where((line) => line.contains('Crossfade skipped') || line.contains('stream load error')),
        isEmpty,
      );
      debugPrint('Opus hand-over diagnostics: ${records.join('\n')}');
    } finally {
      if (!incomingRelease.isCompleted) incomingRelease.complete();
      await CrossfadeService.saveSettings((seconds: 0, keepAlbumsGapless: oldSettings.keepAlbumsGapless));
      await native.dispose();
      await GetIt.instance.reset();
      await subscription.cancel();
      await server.close(force: true);
      await folder.delete(recursive: true);
      await AnalyzerService.saveSettings(url: oldAnalyzer.url ?? '', token: oldAnalyzer.token ?? '');
    }
  });
  testWidgets('an unsupported native crossfade cannot leave the main player muted behind a stalled seek', (
    tester,
  ) async {
    final folder = await Directory((await getTemporaryDirectory()).path).createTemp('crossfade-fallback-test-');
    final native = AudioPlayer();
    final records = <String>[];
    final subscription = Logger.root.onRecord.where((r) => r.loggerName == 'CrossfadeService').listen((r) {
      records.add(r.message);
    });
    final oldSettings = await CrossfadeService.loadSettings();
    final oldAnalyzer = await AnalyzerService.getSettings();
    _Player? player;
    _Queue? queue;
    try {
      final files = <File>[];
      final entries = <FinampQueueItem>[];
      for (var song = 0; song < 3; song++) {
        // Force the first transition to reject native mixing. The following
        // pair has matching formats, so a later native crossfade must still work.
        final rate = song == 0 ? 24000 : 48000;
        final pcm = ByteData(rate * 12 * 2);
        for (var i = 0; i < rate * 12; i++) {
          pcm.setInt16(i * 2, (5000 * sin(2 * pi * (220 + song * 110) * i / rate)).round(), Endian.little);
        }
        files.add(
          await File(
            '${folder.path}/$song.wav',
          ).writeAsBytes(AiService.wav(pcm.buffer.asUint8List(), sampleRate: rate)),
        );
        final item = BaseItemDto(id: BaseItemId('fallback-$song'), name: 'Fallback song $song');
        entries.add(
          FinampQueueItem(
            source: source,
            item: MediaItem(id: item.id.raw, title: item.name!, extras: {'itemJson': item.toJson()}),
          ),
        );
      }
      queue = _Queue(entries);
      player = _Player(native, files, queue)
        ..seekGate = Completer<void>()
        ..normalizationGate = Completer<void>();
      GetIt.instance.registerSingleton<QueueService>(queue);
      GetIt.instance.registerSingleton<MusicPlayerBackgroundTask>(player);
      await AnalyzerService.saveSettings(url: 'https://analyzer.invalid', token: 'test');
      await http.runWithClient(
        () => AnalyzerService.analysis(entries.map((entry) => entry.baseItemId.raw).toList()),
        () => MockClient(
          (_) async => http.Response(
            jsonEncode({
              for (final entry in entries) entry.baseItemId.raw: {'duration': 12, 'end': 12},
            }),
            200,
          ),
        ),
      );
      await native.setAudioSources(files.map((file) => AudioSource.file(file.path)).toList());
      await native.seek(const Duration(seconds: 5));
      await CrossfadeService.saveSettings((seconds: 4, keepAlbumsGapless: false));
      unawaited(native.play());
      // Cancellation while analysis is pending must not let its late result
      // create a player or arm the bridge over a later transition.
      final prepareDeadline = DateTime.now().add(const Duration(seconds: 3));
      while (player.normalizationRequests == 0 && DateTime.now().isBefore(prepareDeadline)) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(player.normalizationRequests, greaterThan(0));
      await CrossfadeService.saveSettings((seconds: 0, keepAlbumsGapless: false));
      final cancelledGate = player.normalizationGate!;
      player.normalizationGate = Completer<void>();
      await CrossfadeService.saveSettings((seconds: 4, keepAlbumsGapless: false));
      final replacementDeadline = DateTime.now().add(const Duration(seconds: 3));
      while (player.normalizationRequests < 2 && DateTime.now().isBefore(replacementDeadline)) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(player.normalizationRequests, 2);
      cancelledGate.complete();
      await tester.pump(const Duration(milliseconds: 300));
      expect(player.sourceRequests, 0, reason: 'Cancelled preparation must not start a late player');
      player.normalizationGate!.complete();
      var checkedFirst = false;
      var retried = false;
      final deadline = DateTime.now().add(const Duration(seconds: 40));
      while (DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 100));
        if (queue.index == 0 && !retried && records.any((line) => line.contains('Crossfade skipped'))) {
          retried = true;
          expect(await CrossfadeService.tryNow(), isTrue);
        }
        if (queue.index == 1 && native.position >= const Duration(seconds: 3) && !checkedFirst) {
          expect(native.playing, isTrue);
          expect(
            native.volume,
            closeTo(1, .0001),
            reason:
                'A stalled fallback seek must not leave playing=true with the main output muted: ${records.join('; ')}',
          );
          expect(player.seeks, 1, reason: 'Only the deliberate Try now seek may run; no two-output seek/speed chase');
          checkedFirst = true;
        }
        if (queue.index == 2 && records.any((line) => line.contains('hand-over done in the main output'))) break;
      }
      expect(checkedFirst, isTrue, reason: records.join('\n'));
      expect(retried, isTrue);
      expect(queue.index, 2);
      expect(records.where((line) => line.contains('Crossfade skipped')), hasLength(2), reason: records.join('\n'));
      expect(records.where((line) => line.contains('scheduled by PCM timestamps')), hasLength(1));
      expect(records.where((line) => line.contains('hand-over done in the main output')), hasLength(1));
      expect(records.where((line) => line.contains('hand-over drift')), isEmpty);
      expect(player.seeks, 1);
      expect(player.userSeeks, 0, reason: 'Internal crossfade seeks must not dismiss the DJ as user navigation');
      expect(native.volume, closeTo(1, .0001));
      expect(native.playing, isTrue);
    } finally {
      await CrossfadeService.saveSettings((seconds: 0, keepAlbumsGapless: oldSettings.keepAlbumsGapless));
      // Release the deliberately stalled old path even when its regression
      // assertion fails, before disposing the players and registered services.
      if (queue != null) queue.index = 2;
      if (player?.seekGate case final gate? when !gate.isCompleted) gate.complete();
      if (player?.normalizationGate case final gate? when !gate.isCompleted) gate.complete();
      await tester.pump(const Duration(seconds: 2));
      await native.dispose();
      await subscription.cancel();
      await GetIt.instance.reset();
      await AnalyzerService.saveSettings(url: oldAnalyzer.url ?? '', token: oldAnalyzer.token ?? '');
      await folder.delete(recursive: true);
    }
  });
  testWidgets('native crossfades keep the audio clock correct across fades, ordinary tracks and seeks', (tester) async {
    final folder = await Directory((await getTemporaryDirectory()).path).createTemp('crossfade-test-');
    final native = AudioPlayer();
    final records = <String>[];
    final fadeStarts = <DateTime>[];
    final subscription = Logger.root.onRecord.where((r) => r.loggerName == 'CrossfadeService').listen((r) {
      records.add(r.message);
      if (r.message.startsWith('Crossfading into ')) fadeStarts.add(DateTime.now());
    });
    final oldSettings = await CrossfadeService.loadSettings();
    final oldAnalyzer = await AnalyzerService.getSettings();
    try {
      final files = <File>[];
      final entries = <FinampQueueItem>[];
      for (var song = 0; song < 4; song++) {
        final pcm = ByteData(24000 * 24 * 2);
        for (var i = 0; i < 24000 * 20; i++) {
          pcm.setInt16(i * 2, (5000 * sin(2 * pi * (220 + song * 110) * i / 24000)).round(), Endian.little);
        }
        files.add(
          await File(
            '${folder.path}/$song.wav',
          ).writeAsBytes(AiService.wav(pcm.buffer.asUint8List(), sampleRate: 24000)),
        );
        final item = BaseItemDto(id: BaseItemId('crossfade-$song'), name: 'Song $song');
        entries.add(
          FinampQueueItem(
            source: source,
            item: MediaItem(id: item.id.raw, title: item.name!, extras: {'itemJson': item.toJson()}),
          ),
        );
      }
      final queue = _Queue(entries);
      final player = _Player(native, files, queue);
      GetIt.instance.registerSingleton<QueueService>(queue);
      GetIt.instance.registerSingleton<MusicPlayerBackgroundTask>(player);
      await AnalyzerService.saveSettings(url: 'https://analyzer.invalid', token: 'test');
      await http.runWithClient(
        () => AnalyzerService.analysis(entries.map((e) => e.baseItemId.raw).toList()),
        () => MockClient(
          (_) async => http.Response(
            jsonEncode({
              for (final entry in entries) entry.baseItemId.raw: {'duration': 24, 'end': 20},
            }),
            200,
          ),
        ),
      );
      await native.setAudioSources(files.map((file) => AudioSource.file(file.path)).toList());
      await native.seek(const Duration(seconds: 8));
      await CrossfadeService.saveSettings((seconds: 4, keepAlbumsGapless: false));
      unawaited(native.play());
      final deadline = DateTime.now().add(const Duration(seconds: 85));
      final last = <int, Duration>{};
      var ordinaryTransition = false;
      var cancelledPreroll = false;
      var pausedPreroll = false;
      DateTime? ordinaryStarted;
      while (DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 100));
        final scheduled = records.where((r) => r.contains('scheduled by PCM timestamps')).length;
        if (queue.index == 0 && scheduled > 0 && !cancelledPreroll) {
          // Seeking out of a silent pre-roll must discard it, without starting the next song.
          cancelledPreroll = true;
          await player.seek(const Duration(seconds: 8));
          await tester.pump(const Duration(milliseconds: 500));
          expect(queue.index, 0);
          expect(native.position, lessThan(const Duration(seconds: 10)));
        } else if (queue.index == 0 && scheduled >= 2 && !pausedPreroll) {
          pausedPreroll = true;
          await native.pause();
          await tester.pump(const Duration(milliseconds: 200));
          final pausedAt = native.position;
          await tester.pump(const Duration(milliseconds: 600));
          expect((native.position - pausedAt).abs(), lessThan(const Duration(milliseconds: 100)));
          unawaited(native.play());
        }
        if (queue.index == 3) {
          ordinaryStarted ??= DateTime.now();
          final heardFor = DateTime.now().difference(ordinaryStarted);
          expect(
            (native.position - heardFor).abs(),
            lessThan(const Duration(seconds: 2)),
            reason: 'An ordinary track must not inherit the previous crossfade clock correction',
          );
          if (heardFor > const Duration(seconds: 3)) break;
          continue;
        }
        // Wait for native hand-over to finish before checking its corrected clock.
        final done = records.where((r) => r.contains('hand-over done in the main output')).length;
        if (queue.index > 0 && done >= queue.index) {
          final position = native.position;
          final heardFor = DateTime.now().difference(fadeStarts[queue.index - 1]);
          expect(
            (position - heardFor).abs(),
            lessThan(const Duration(seconds: 2)),
            reason:
                'Song ${queue.index}: the clock must follow the audio already heard, '
                'not accumulate corrections from earlier crossfades (${records.join('; ')})',
          );
          final previous = last[queue.index];
          if (previous != null) expect(position + const Duration(milliseconds: 100), greaterThanOrEqualTo(previous));
          last[queue.index] = position;
          if (queue.index == 2 && position > const Duration(seconds: 10) && !ordinaryTransition) {
            ordinaryTransition = true;
            await CrossfadeService.saveSettings((seconds: 0, keepAlbumsGapless: false));
          }
        }
      }
      expect(
        records.where((r) => r.contains('hand-over done in the main output')),
        hasLength(2),
        reason: records.join('\n'),
      );
      expect(cancelledPreroll && pausedPreroll, isTrue, reason: 'Silent pre-roll seek and pause must be exercised');
      expect(player.seeks, 1, reason: 'Only the deliberate pre-roll seek may flush the native mix');
      expect(player.userSeeks, 1);
      expect(records.where((r) => r.contains('scheduled by PCM timestamps')), hasLength(3));
      expect(
        records.where((r) => r.contains('two outputs') || r.contains('hand-over drift') || r.contains('given up')),
        isEmpty,
      );
      expect(native.playing, isTrue);
      expect(last.keys, containsAll([1, 2]));
      expect(ordinaryStarted, isNotNull, reason: 'The ordinary track transition must be exercised');
      await player.seek(const Duration(seconds: 5));
      expect(player.userSeeks, 2);
      await tester.pump(const Duration(milliseconds: 500));
      expect(native.position, greaterThanOrEqualTo(const Duration(seconds: 5)));
      expect(native.position, lessThan(const Duration(seconds: 6)));
      expect(native.playing, isTrue);
    } finally {
      await CrossfadeService.saveSettings((seconds: 0, keepAlbumsGapless: oldSettings.keepAlbumsGapless));
      await native.dispose();
      await subscription.cancel();
      await GetIt.instance.reset();
      await AnalyzerService.saveSettings(url: oldAnalyzer.url ?? '', token: oldAnalyzer.token ?? '');
      await folder.delete(recursive: true);
    }
  });
}
