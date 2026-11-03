import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:audio_service/audio_service.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/services/ai_service.dart';
import 'package:finamp/services/dj_voice_service.dart';
import 'package:finamp/services/music_player_background_task.dart';
import 'package:finamp/services/playback_navigation.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getTemporaryPath() async => path;
}

class _Player extends Fake implements MusicPlayerBackgroundTask {
  @override
  final playbackState = BehaviorSubject.seeded(PlaybackState(playing: true));
  @override
  bool get karaokeActive => false;
  @override
  Duration get playerDuration => const Duration(minutes: 3);
  @override
  Duration playbackPosition = Duration.zero;
  @override
  double get djVoiceBaseVolume => 1;
  final volumes = <double>[];
  @override
  Future<void> setVoiceVolume(double value) async => volumes.add(value);
}

class _Queue extends Fake implements QueueService {
  final info = FinampQueueInfo(
    id: 'active-voice-navigation',
    previousTracks: [],
    nextUp: [],
    queue: [],
    currentTrack: FinampQueueItem(
      item: const MediaItem(id: 'active-voice-track', title: 'A song', artist: 'Artist'),
      source: QueueService.savedQueueSource,
    ),
    source: QueueService.savedQueueSource,
    saveState: SavedQueueState.saving,
    sourceLibrary: null,
  );
  @override
  FinampQueueInfo getQueue() => info;
  @override
  FinampQueueItem? getCurrentTrack() => info.currentTrack;
}

/// Exercise the actual voice AudioPlayer through its native protocol. It stays
/// playing until stopped, so navigation must release it and the music duck.
class _VoiceBackend {
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  int loads = 0, plays = 0, stops = 0;
  Completer<void>? loadGate;
  Completer<Map<String, Object?>>? playing;
  MockStreamHandlerEventSink? events;

  void stop() {
    stops++;
    events?.success({
      'processingState': 0,
      'updateTime': DateTime.now().millisecondsSinceEpoch,
      'updatePosition': 0,
      'bufferedPosition': 0,
      'currentIndex': 0,
    });
    if (playing != null && !playing!.isCompleted) playing!.complete({});
  }

  void install() {
    messenger.setMockMethodCallHandler(const MethodChannel('com.ryanheise.just_audio.methods'), (call) async {
      if (call.method == 'disposePlayer') stop();
      if (call.method == 'init') {
        final id = (call.arguments as Map<Object?, Object?>)['id']! as String;
        final ready = Completer<void>();
        messenger.setMockStreamHandler(
          EventChannel('com.ryanheise.just_audio.events.$id'),
          MockStreamHandler.inline(
            onListen: (_, sink) {
              events = sink;
              ready.complete();
            },
            onCancel: (_) => events = null,
          ),
        );
        messenger.setMockStreamHandler(
          EventChannel('com.ryanheise.just_audio.data.$id'),
          MockStreamHandler.inline(onListen: (_, _) {}),
        );
        messenger.setMockMethodCallHandler(MethodChannel('com.ryanheise.just_audio.methods.$id'), (command) async {
          if (command.method == 'load') {
            loads++;
            await ready.future;
            await loadGate?.future;
            events?.success({
              'processingState': 3,
              'updateTime': DateTime.now().millisecondsSinceEpoch,
              'updatePosition': 0,
              'bufferedPosition': 2000000,
              'duration': 2000000,
              'currentIndex': 0,
            });
            return {'duration': 2000000};
          }
          if (command.method == 'play') {
            plays++;
            playing = Completer<Map<String, Object?>>();
            return playing!.future;
          }
          if (command.method == 'pause') stop();
          return <String, Object?>{};
        });
      }
      return <String, Object?>{};
    });
  }
}

Future<void> _until(FutureOr<bool> Function() done) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!await done()) {
    if (DateTime.now().isAfter(deadline)) fail('Active DJ did not finish the expected operation');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Future<void> exerciseNavigation({bool preview = false, bool loading = false, bool ducking = false}) async {
    final oldPreferences = SharedPreferencesAsyncPlatform.instance;
    final oldPaths = PathProviderPlatform.instance;
    final folder = await Directory.systemTemp.createTemp('finamp-active-dj-');
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    PathProviderPlatform.instance = _Paths(folder.path);
    final player = _Player(), queue = _Queue(), native = _VoiceBackend()..install();
    if (loading) native.loadGate = Completer<void>();
    // Keep the automatic opening out of preview cases, even when tests run
    // independently and the service has no recent speech to suppress it.
    if (preview) player.playbackPosition = const Duration(seconds: 135);
    final pcm = ByteData(24000 * 2 * 2);
    for (var i = 0; i < pcm.lengthInBytes ~/ 2; i++) {
      pcm.setInt16(i * 2, (3000 * sin(2 * pi * 140 * i / 24000)).round(), Endian.little);
    }
    try {
      await http.runWithClient(
        () async {
          await AiService.setProvider(AiProvider.gemini);
          await AiService.setApiKey(AiProvider.gemini, 'test-key');
          GetIt.instance.registerSingleton<QueueService>(queue);
          GetIt.instance.registerSingleton<MusicPlayerBackgroundTask>(player);
          await DjVoiceService.saveProfile(
            const DjVoiceProfile(
              settings: (
                mode: DjVoiceMode.always,
                every: 1,
                character: DjVoiceCharacter.pirate,
                aiVoice: true,
                volume: .7,
              ),
            ),
          );
          await DjVoiceService.initialize();
          final audition = preview ? DjVoiceService.preview('Try this sample voice.') : null;
          if (loading) {
            await _until(() => native.loads > 0);
            expect(player.volumes, isEmpty, reason: 'A stalled voice load must not dip the music');
          } else if (ducking) {
            await _until(() => player.volumes.any((volume) => volume < 1));
            expect(native.plays, 0);
          } else {
            await _until(() => native.plays > 0);
            expect(player.volumes.last, lessThan(1));
          }
          final navigation = PlaybackNavigation.shared.begin(
            PlaybackNavigationKind.seekForward,
            queueId: queue.info.id,
          );
          player.playbackPosition = const Duration(seconds: 135);
          navigation.complete(targetItemId: queue.info.currentTrack!.id);
          // A second command during dismissal must not restart speech or leave
          // the music at the ducked level.
          if (ducking) {
            PlaybackNavigation.shared
                .begin(PlaybackNavigationKind.previous, queueId: queue.info.id)
                .complete(targetItemId: queue.info.currentTrack!.id);
          }
          await _until(() => !DjVoiceService.status.value.$1);
          if (loading) {
            expect(player.volumes, isEmpty);
            native.loadGate!.complete();
          } else {
            expect(player.volumes.last, 1);
          }
          await audition;
          await Future<void>.delayed(const Duration(milliseconds: 250));
          if (!loading) expect(native.stops, greaterThan(0));
          expect(native.plays, loading || ducking ? 0 : 1);
          expect(player.playbackState.value.playing, isTrue);
          if (loading) {
            // The cancelled load must also leave the player usable. This
            // explicitly starts new speech after rejecting the late result.
            final recovery = DjVoiceService.preview('A new sample after cancellation.');
            await _until(() => native.plays == 1);
            PlaybackNavigation.shared
                .begin(PlaybackNavigationKind.restart, queueId: queue.info.id)
                .complete(targetItemId: queue.info.currentTrack!.id);
            await recovery;
            expect(player.volumes.last, 1);
            expect(native.stops, greaterThan(0));
          }
        },
        () => MockClient((request) async {
          if (request.method == 'GET') {
            return http.Response(
              jsonEncode({
                'models': [
                  {'name': 'models/gemini-3.8-flash-tts'},
                ],
              }),
              200,
            );
          }
          final parts = request.url.path.contains('-tts')
              ? [
                  {
                    'inlineData': {'mimeType': 'audio/l16;rate=24000', 'data': base64Encode(pcm.buffer.asUint8List())},
                  },
                ]
              : [
                  {
                    'text': jsonEncode({'line': 'A great song is starting now.'}),
                  },
                ];
          return http.Response(
            jsonEncode({
              'candidates': [
                {
                  'finishReason': 'STOP',
                  'content': {'parts': parts},
                },
              ],
            }),
            200,
          );
        }),
      );
    } finally {
      if (native.loadGate != null && !native.loadGate!.isCompleted) native.loadGate!.complete();
      player.playbackState.add(PlaybackState(playing: false));
      await GetIt.instance.reset();
      await DjVoiceService.initialize();
      await _until(() async => (await folder.list().toList()).isEmpty);
      await player.playbackState.close();
      SharedPreferencesAsyncPlatform.instance = oldPreferences;
      PathProviderPlatform.instance = oldPaths;
      await folder.delete(recursive: true);
    }
  }

  test('seeking during audible speech stops the voice and fully restores the music', exerciseNavigation);
  test('navigation cancels a stalled voice load without dipping the music or playing its late result', () async {
    await exerciseNavigation(preview: true, loading: true);
  });
  test('rapid forward then Back during music ducking cancels speech and fully restores the music', () async {
    await exerciseNavigation(preview: true, ducking: true);
  });
}
