import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:audio_service/audio_service.dart';
import 'package:finamp/l10n/app_localizations.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/screens/dj_voice_settings_screen.dart';
import 'package:finamp/services/ai_service.dart';
import 'package:finamp/services/analyzer_service.dart';
import 'package:finamp/services/crossfade_service.dart';
import 'package:finamp/services/dj_voice_service.dart';
import 'package:finamp/services/dj_voice_studio.dart';
import 'package:finamp/services/dj_show_audio.dart';
import 'package:finamp/services/music_player_background_task.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:integration_test/integration_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';
import 'package:rxdart/rxdart.dart';

class _Queue extends Fake implements QueueService {
  _Queue(this.variant);
  final String variant;
  late final items = [
    for (var index = 0; index < 2; index++)
      FinampQueueItem(
        item: MediaItem(
          id: 'dj-$variant-$index',
          title: 'Song $index',
          artist: 'Test artist',
          extras: {
            'itemJson': BaseItemDto(
              id: BaseItemId('dj-$variant-$index'),
              name: 'Song $index',
              artists: ['Test artist'],
            ).toJson(),
          },
        ),
        source: QueueItemSource.rawId(
          type: QueueItemSourceType.unknown,
          id: 'dj-$variant',
          name: const QueueItemSourceName(type: QueueItemSourceNameType.preTranslated, pretranslatedName: 'Test mix'),
        ),
      ),
  ];
  int index = 0;
  @override
  FinampLoopMode get loopMode => FinampLoopMode.none;
  @override
  FinampQueueItem getCurrentTrack() => items[index];
  @override
  FinampQueueInfo getQueue() => FinampQueueInfo(
    id: 'dj-recovery',
    previousTracks: items.take(index).toList(),
    currentTrack: items[index],
    nextUp: [],
    queue: items.skip(index + 1).toList(),
    source: items[index].source,
    saveState: SavedQueueState.saving,
    sourceLibrary: null,
  );
}

class _Player extends Fake implements MusicPlayerBackgroundTask {
  final nativeRamps = <double>[];
  int fallbackDucks = 0;
  _Player(this.native, this.files, this.testQueue) {
    native.currentIndexStream.listen((index) {
      if (index != null) {
        testQueue.index = index;
        mediaItem.add(testQueue.items[index].item);
      }
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
  double _transition = 1, _voice = 1;
  @override
  final playbackState = BehaviorSubject.seeded(PlaybackState());
  @override
  final mediaItem = BehaviorSubject<MediaItem?>();
  @override
  bool get karaokeActive => false;
  @override
  double get speed => 1;
  @override
  double get djVoiceBaseVolume => 1;
  @override
  double get crossfadeBaseVolume => _voice;
  @override
  Duration? get playerDuration => native.duration;
  @override
  Duration get playbackPosition => native.position;
  @override
  String? get playerPlatformId => native.platformId;
  @override
  double normalizationFactorFor(MediaItem item) => 1;
  @override
  Future<void> prepareNormalization(List<MediaItem> items) async {}
  @override
  Future<void> configureNormalization(String id, MediaItem item) async {}
  @override
  void forgetNormalization(String? id) {}
  @override
  Future<void> setTransitionVolume(double value) {
    _transition = value;
    return native.setVolume(_transition * _voice);
  }

  @override
  Future<void> setVoiceVolume(double value) {
    fallbackDucks++;
    _voice = value;
    return native.setVolume(_transition * _voice);
  }

  @override
  Future<Duration?> rampVoiceVolume(double value, Duration duration) async {
    final lead = await const MethodChannel('com.ryanheise.just_audio.methods').invokeMethod<int>('setVoiceEnvelope', {
      'id': native.platformId,
      'gain': value,
      'durationMs': duration.inMilliseconds,
    });
    if (lead == null) return null;
    nativeRamps.add(value);
    return Duration(milliseconds: lead);
  }

  @override
  Future<AudioSource> audioSourceFor(FinampQueueItem item, {String? playSessionId}) async =>
      AudioSource.file(files[testQueue.items.indexOf(item)].path);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  for (final withShow in [false, true]) {
    testWidgets(
      withShow
          ? 'two hosts and saved jingles use the existing native voice and crossfade path'
          : 'automatic natural announcements survive writer failure across a native crossfade',
      (tester) async {
        final oldProfile = await DjVoiceService.loadProfile();
        final oldText = await AiService.getTextSettings();
        final oldKey = await AiService.getApiKey(AiProvider.gemini);
        final oldSpeech = await AiService.getSpeechSettings();
        final oldStudio = await DjVoiceStudioSettings.load();
        final oldOpenAiKey = await AiService.getApiKey(AiProvider.openai);
        String? jingleId;
        final oldAnalyzer = await AnalyzerService.getSettings();
        final oldCrossfade = await CrossfadeService.loadSettings();
        final folder = await Directory((await getTemporaryDirectory()).path).createTemp('dj-recovery-');
        final native = AudioPlayer();
        final queue = _Queue(withShow ? 'show' : 'recovery');
        final files = <File>[];
        final records = <String>[];
        final subscription = Logger.root.onRecord.listen((record) {
          if (record.loggerName == 'DjVoiceService' ||
              record.loggerName == 'CrossfadeService' ||
              record.loggerName == 'AiService') {
            records.add(record.message);
          }
        });
        var scripts = 0, recordings = 0, coHostScripts = 0, openAiRecordings = 0;
        try {
          // Announcement history deliberately survives initialize(). Give the
          // previous scenario's 30-second speaking guard time to expire.
          if (withShow) await Future<void>.delayed(const Duration(seconds: 31));
          for (var song = 0; song < 2; song++) {
            final pcm = ByteData(24000 * 16 * 2);
            for (var i = 0; i < pcm.lengthInBytes ~/ 2; i++) {
              pcm.setInt16(i * 2, (5000 * sin(2 * pi * (220 + song * 110) * i / 24000)).round(), Endian.little);
            }
            files.add(
              await File(
                '${folder.path}/$song.wav',
              ).writeAsBytes(AiService.wav(pcm.buffer.asUint8List(), sampleRate: 24000)),
            );
          }
          GetIt.instance.registerSingleton<QueueService>(queue);
          final player = _Player(native, files, queue);
          GetIt.instance.registerSingleton<MusicPlayerBackgroundTask>(player);
          await AnalyzerService.saveSettings(url: '', token: '');
          // This case exercises an unavailable writer's spoken introduction. API
          // backup success is covered independently; saved emulator keys must not
          // silently turn this into a different scenario.
          await AiService.setTextSettings(AiTextSettings(fallbacks: []));
          await AiService.setApiKey(AiProvider.gemini, 'integration-recovery-key');
          await AiService.setSpeechSettings(AiSpeechSettings(primary: AiProvider.gemini));
          await DjVoiceService.saveStudioSettings(
            withShow
                ? const DjVoiceStudioSettings(
                    routes: {DjVoiceCharacter.aussieMale: DjVoiceRoute(AiProvider.openai)},
                    pronunciations: [DjPronunciation('Song', 'Tune')],
                  )
                : const DjVoiceStudioSettings(),
          );
          if (withShow) {
            await AiService.setApiKey(AiProvider.openai, 'integration-openai-voice-key');
            final ident = ByteData(24000 * 2);
            for (var i = 0; i < 24000; i++) {
              ident.setInt16(i * 2, (2000 * sin(2 * pi * 440 * i / 24000)).round(), Endian.little);
            }
            jingleId = await DjJingleStore.save(AiService.wav(ident.buffer.asUint8List(), sampleRate: 24000));
          }
          await DjVoiceService.saveProfile(
            DjVoiceProfile(
              show: withShow
                  ? DjShowSettings(
                      duoChance: 100,
                      coHost: DjVoiceCharacter.aussieMale,
                      identityEnabled: true,
                      stationName: 'Test FM',
                      intro: 'Welcome to Test FM.',
                      jingleId: jingleId!,
                      jingleChance: 100,
                    )
                  : const DjShowSettings(),
              settings: const (
                mode: DjVoiceMode.always,
                every: 1,
                character: DjVoiceCharacter.energetic,
                aiVoice: true,
                volume: .7,
              ),
            ),
          );
          await DjVoiceService.resumeDj();
          final speechPcm = ByteData(24000 * 2 * 2);
          for (var i = 0; i < 24000 * 2; i++) {
            speechPcm.setInt16(i * 2, (3000 * sin(2 * pi * 180 * i / 24000)).round(), Endian.little);
          }
          final audio = base64Encode(speechPcm.buffer.asUint8List());
          await native.setAudioSources(files.map((file) => AudioSource.file(file.path)).toList());
          await http.runWithClient(
            () async {
              await DjVoiceService.initialize();
              await CrossfadeService.saveSettings((seconds: 4, keepAlbumsGapless: false));
              await tester.pumpWidget(
                MaterialApp(
                  localizationsDelegates: AppLocalizations.localizationsDelegates,
                  supportedLocales: AppLocalizations.supportedLocales,
                  home: const DjVoiceSettingsScreen(),
                ),
              );
              await tester.pump(const Duration(seconds: 1));
              expect(find.text('Announcements'), findsOneWidget);
              expect(find.text('Voice & character'), findsOneWidget);
              expect(find.text('Volume & music'), findsOneWidget);
              unawaited(native.play());
              final deadline = DateTime.now().add(const Duration(seconds: 40));
              while (DateTime.now().isBefore(deadline)) {
                await tester.pump(const Duration(milliseconds: 100));
                final completed = records.where((line) => line.startsWith('DJ line ended (completed)')).length;
                if (completed >= 2 &&
                    queue.index == 1 &&
                    !DjVoiceService.status.value.$1 &&
                    records.any((line) => line.contains('hand-over done in the main output'))) {
                  break;
                }
              }
              expect(scripts, 2, reason: records.join('\n'));
              expect(recordings, withShow ? 4 : 2);
              expect(coHostScripts, withShow ? 2 : 0);
              expect(openAiRecordings, withShow ? 2 : 0);
              expect(records.where((line) => line.contains('DJ commentary unavailable (HTTP 503)')), hasLength(2));
              expect(
                records.where((line) => line.startsWith('DJ line ended (completed)')),
                hasLength(2),
                reason: records.join('\n'),
              );
              expect(records.where((line) => line.contains('hand-over done in the main output')), hasLength(1));
              expect(
                records.where((line) => line.contains('two outputs') || line.contains("Couldn't prepare")),
                isEmpty,
              );
              expect(AiService.lastSpeechProvider.value, withShow ? AiProvider.openai : AiProvider.gemini);
              expect(native.playing, isTrue);
              expect(DjVoiceService.transcript.value, allOf(contains('Song 1'), contains('Test artist')));
              expect(native.volume, closeTo(1, .001));
              expect(player.nativeRamps.where((gain) => gain < 1), hasLength(2));
              expect(player.nativeRamps.where((gain) => gain == 1), hasLength(2));
              expect(player.fallbackDucks, 0, reason: 'Native envelopes should replace repeated Flutter duck updates');
              expect(records.where((line) => line == 'DJ voice player ready before music ducking'), hasLength(2));
            },
            () => MockClient((request) async {
              if (request.url.host == 'api.openai.com') {
                recordings++;
                openAiRecordings++;
                return http.Response.bytes(speechPcm.buffer.asUint8List(), 200);
              }
              if (request.method == 'GET') {
                return http.Response(
                  jsonEncode({
                    'models': [
                      {'name': 'models/gemini-3.8-flash'},
                      {'name': 'models/gemini-3.8-flash-tts'},
                    ],
                  }),
                  200,
                );
              }
              if (!request.url.path.contains('-tts')) {
                if (withShow && request.body.contains('second music host')) {
                  coHostScripts++;
                  return http.Response(
                    jsonEncode({
                      'candidates': [
                        {
                          'content': {
                            'parts': [
                              {
                                'text': jsonEncode({'line': 'A great choice to keep the music going.'}),
                              },
                            ],
                          },
                        },
                      ],
                    }),
                    200,
                  );
                }
                scripts++;
                return http.Response('{"error":{"message":"Unavailable"}}', 503);
              }
              recordings++;
              return http.Response(
                jsonEncode({
                  'candidates': [
                    {
                      'finishReason': 'STOP',
                      'content': {
                        'parts': [
                          {
                            'inlineData': {'mimeType': 'audio/L16;rate=24000', 'data': audio},
                          },
                        ],
                      },
                    },
                  ],
                }),
                200,
              );
            }),
          );
        } finally {
          await DjVoiceService.skipAnnouncement();
          await DjVoiceService.saveSettings((
            mode: DjVoiceMode.off,
            every: 2,
            character: DjVoiceCharacter.energetic,
            aiVoice: true,
            volume: .7,
          ));
          await CrossfadeService.saveSettings((seconds: 0, keepAlbumsGapless: oldCrossfade.keepAlbumsGapless));
          await native.dispose();
          await GetIt.instance.reset();
          await subscription.cancel();
          await DjVoiceService.saveProfile(oldProfile);
          await AiService.setApiKey(AiProvider.gemini, oldKey);
          await AiService.setTextSettings(oldText);
          await AiService.setSpeechSettings(oldSpeech);
          await DjVoiceService.saveStudioSettings(oldStudio);
          await AiService.setApiKey(AiProvider.openai, oldOpenAiKey);
          if (jingleId != null) await DjJingleStore.remove(jingleId);
          await AnalyzerService.saveSettings(url: oldAnalyzer.url ?? '', token: oldAnalyzer.token ?? '');
          await folder.delete(recursive: true);
        }
      },
    );
  }
}
