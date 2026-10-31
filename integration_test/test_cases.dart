import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dbus/dbus.dart';
import 'package:finamp/components/AlbumScreen/album_screen_content.dart';
import 'package:finamp/components/Buttons/cta_huge.dart';
import 'package:finamp/components/dj_voice_controls.dart';
import 'package:finamp/components/normalization_details.dart';
import 'package:finamp/components/LoginScreen/login_server_selection_page.dart';
import 'package:finamp/components/MusicScreen/item_wrapper.dart';
import 'package:finamp/main.dart' as app;
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/music_slices.dart';
import 'package:finamp/menus/components/playbackActions/playback_actions.dart';
import 'package:finamp/screens/login_screen.dart';
import 'package:finamp/screens/music_screen.dart';
import 'package:finamp/screens/server_hub_screen.dart';
import 'package:finamp/services/analyzer_service.dart';
import 'package:finamp/services/ai_service.dart';
import 'package:finamp/services/dj_voice_service.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:finamp/services/finamp_user_helper.dart';
import 'package:finamp/services/headphone_eq_service.dart';
import 'package:finamp/services/loudness_cache.dart';
import 'package:finamp/services/normalization_session.dart';
import 'package:finamp/services/music_player_background_task.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:finamp/services/radio_service_helper.dart' as radio;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:integration_test/integration_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';

void main() async {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// The ProviderContainer initialized by main().
  /// All tests should create and attach to descendants of this to avoid errors.
  ProviderContainer? container;
  final mainErrors = <FlutterErrorDetails>[];
  bool mainCompleted = false;
  String resumeId = '';

  setUpAll(() async {
    // Disable audio output on windows and linux due to missing driver in CI
    if (Platform.isWindows || Platform.isLinux) {
      JustAudioMediaKit.nullBackend = true;
    }

    // If main throws an error, the future runZoneGuarded returns will never complete, so do not await it.
    // Wait up to 30 seconds for startup, retaining background errors throughout
    // the tests rather than waiting the full timeout after successful startup.
    unawaited(
      runZonedGuarded(
        () async {
          // Login testing flag redirects file accesses to testing folder and clears it on startup.
          // Download base directories are not redirected, so loginTesting flag should be avoided on mobile.
          // Note that this means mobile integration test runs will require manual file clearing outside of CI
          await app.main([], integrationTesting: true, loginTesting: !(Platform.isAndroid || Platform.isIOS));
          mainCompleted = true;
        },
        (e, stack) {
          // Linux throws DBusServiceUnknownException due to dbus service org.freedesktop.UPower
          // missing in CI.  Ignore.
          if (e is DBusServiceUnknownException) return;

          mainErrors.add(FlutterErrorDetails(exception: e, stack: stack));
        },
      ),
    );

    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (!mainCompleted && mainErrors.isEmpty && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    await Future<void>.delayed(const Duration(seconds: 3));
  });

  // These integration tests all rely on the previous one working.  Not good practice, but whatever.
  group('Integration Tests', () {
    testWidgets('Verify app loads without errors', (tester) async {
      // Running main in setup instead of here to prevent all logging from being attributed
      // to this test in output.
      for (var error in mainErrors) {
        debugPrint("Error thrown in main: ${error.exception}");
        if (error.stack != null) {
          debugPrintStack(stackTrace: error.stack!);
        }
      }

      expect(mainErrors.length, equals(0));
      expect(mainCompleted, equals(true));
      // A failed early lookup remains cached even after GetIt has the queue.
      // Check the real providers too, rather than only the absence of exceptions.
      final providers = GetIt.instance<ProviderContainer>();
      expect(providers.read(QueueService.queueProvider), isNotNull);
      expect(providers.read(radio.currentRadioAvailabilityStatusProvider), isA<radio.RadioModeAvailabilityStatus>());

      mainErrors.clear();

      // The testing harness tries to clear out all the async code between tests, and runs all the cases in individual
      // async contexts as part of this. I believe the expectation is that background services and realtime tasks will
      // all be replaced with mockups, for more consistent and self-contained tests. But this code doesn't do that and
      // has real persistent background services, so I've had errors occasionally showing up in earlier tests occasionally,
      // and a bunch of strange issues with providers were occurring. Giving each test its own child ProviderContainer
      // which inherits the global persistent providers from the original one set up in main seems to have solved those, but it's
      // all still a bit mysterious.
      container = GetIt.instance<ProviderContainer>();
      GetIt.instance.unregister<ProviderContainer>();
      await container!.pump();
      GetIt.instance.registerSingleton(ProviderContainer(parent: container));

      // This makes the screen sized correctly when watching integration test.
      // I don't know why this works or is needed.
      await tester.pumpWidget(Container(color: Colors.white));
      await tester.pumpWidget(app.Finamp());

      await tester.pumpAndSettle();

      // Verify FinampApp loaded.
      expect(find.byType(LoginScreen), findsOneWidget);
    });
    testWidgets('Playback notifications wait for queue registration', (tester) async {
      final services = GetIt.instance;
      final player = services<MusicPlayerBackgroundTask>();
      final queue = services<QueueService>();
      final originalProviders = services<ProviderContainer>();
      final startupProviders = ProviderContainer();
      final settings = FinampSettingsHelper.finampSettings;
      final originalRadio = settings.radioEnabled;
      final originalMode = settings.radioMode;
      settings.radioEnabled = true;
      settings.radioMode = RadioMode.random;
      // main's _setupProviders awaits settings before constructing the player.
      await startupProviders.read(finampSettingsProvider.future);
      await services.unregister<ProviderContainer>();
      services.registerSingleton<ProviderContainer>(startupProviders);
      await services.unregister<QueueService>();
      try {
        // Exercise the real handler with a fresh provider container, as during
        // AudioService.init, before the queue is registered. Yield between
        // events to model asynchronous preference reads in startup.
        for (var i = 0; i < 3; i++) {
          await player.refreshPlaybackStateAndMediaNotification();
          await Future<void>.delayed(Duration.zero);
        }
        expect(startupProviders.exists(QueueService.queueProvider), false);
        services.registerSingleton<QueueService>(queue);
        player.onQueueServiceAvailable();
        expect(startupProviders.read(QueueService.queueProvider), isNotNull);
        expect(
          startupProviders.read(radio.currentRadioAvailabilityStatusProvider),
          radio.RadioModeAvailabilityStatus.unavailableQueueEmpty,
        );
        await player.refreshPlaybackStateAndMediaNotification();
      } finally {
        if (!services.isRegistered<QueueService>()) services.registerSingleton<QueueService>(queue);
        settings.radioEnabled = originalRadio;
        settings.radioMode = originalMode;
        await services.unregister<ProviderContainer>();
        services.registerSingleton<ProviderContainer>(originalProviders);
        startupProviders.dispose();
      }
      expect(mainErrors, isEmpty);
    });
    testWidgets('Log in to demo server', (tester) async {
      GetIt.instance.unregister<ProviderContainer>(disposingFunction: (old) => old.dispose());
      await container!.pump();
      GetIt.instance.registerSingleton(ProviderContainer(parent: container));
      await tester.pumpWidget(app.Finamp());
      await tester.pumpAndSettle();

      final startButton = find.byType(CTAHuge);
      await tester.tap(startButton);
      await tester.pump();

      final urlEntry = find.byType(TextFormField);
      await tester.enterText(urlEntry, "https://demo.jellyfin.org/stable");

      final serverButton = find.byWidgetPredicate(
        (x) => x is JellyfinServerSelectionWidget && (x.baseUrl?.contains("demo.jellyfin.org") ?? false),
      );
      await tester.waitFor(serverButton);
      await tester.tap(serverButton);
      await tester.pump(Duration(seconds: 1));

      final customUserButton = find.text("Custom User");
      await tester.tap(customUserButton);
      await tester.pump(Duration(seconds: 1));

      final userTextField = find.byType(TextFormField).first;
      await tester.enterText(userTextField, "demo");
      final loginButton = find.text("Log In");
      await tester.tap(loginButton);

      final musicScreen = find.byType(MusicScreen);
      await tester.waitFor(musicScreen);
      await tester.pump(Duration(seconds: 1));

      // Verify login is complete and Music screen loaded
      expect(find.byType(MusicScreen), findsOneWidget);
    });
    testWidgets('Stream playback, pause, seek, resume and skip', (tester) async {
      GetIt.instance.unregister<ProviderContainer>(disposingFunction: (old) => old.dispose());
      await container!.pump();
      GetIt.instance.registerSingleton(ProviderContainer(parent: container));
      await tester.pumpWidget(app.Finamp());
      await tester.pump();
      FinampSetters.setAllowSplitScreen(false);

      final album = find.byType(ItemWrapper);
      await tester.waitFor(album);
      await tester.tap(album.first);

      final trackList = find.byType(TracksSliverList);
      await tester.waitFor(trackList);
      await tester.pumpAndSettle();

      final playButton = find.byType(PlayPlaybackAction);
      await tester.tap(playButton);
      await tester.pump();

      final playerScreen = find.byKey(Key("NowPlayingBar"));
      await tester.waitFor(playerScreen);
      await tester.pump();

      // Progress into song
      await Future<void>.delayed(Duration(seconds: 30));
      await tester.pump();
      final playerService = GetIt.instance<MusicPlayerBackgroundTask>();
      addTearDown(playerService.stop);
      final playbackPosition = playerService.playbackPosition;

      // Verify track has been playing for 30 seconds as expected.
      expect(playbackPosition.inSeconds, inInclusiveRange(15, 40));
      // Opening and saving DJ controls must not reload, seek or stop the song.
      final originalDjProfile = await DjVoiceService.loadProfile();
      final originalDj = originalDjProfile.settings;
      final originalProvider = await AiService.getProvider();
      final originalSpeech = await AiService.getSpeechSettings();
      final originalGeminiKey = await AiService.getApiKey(AiProvider.gemini);
      final originalOpenAiKey = await AiService.getApiKey(AiProvider.openai);
      final queueBeforeControls = GetIt.instance<QueueService>().getCurrentTrack()!.id;
      try {
        await DjVoiceService.saveSpeechSettings(
          AiSpeechSettings(primary: AiProvider.gemini, fallbacks: [AiProvider.openai]),
        );
        await DjVoiceService.saveSettings((
          mode: DjVoiceMode.aiDjOnly,
          every: 2,
          character: originalDj.character,
          aiVoice: originalDj.aiVoice,
          volume: 0.7,
        ));
        await tester.tap(playerScreen);
        // The playing progress slider schedules frames continuously. Give route
        // animations bounded time instead of waiting for the app to be idle.
        await tester.pump(const Duration(seconds: 1));
        await tester.tap(find.byTooltip('DJ voice'));
        await tester.pump(const Duration(seconds: 1));
        final sliders = find.descendant(of: find.byType(DjVoiceControls), matching: find.byType(Slider));
        await tester.drag(sliders.first, const Offset(200, 0));
        await tester.pump(const Duration(seconds: 1));
        await tester.drag(sliders.last, const Offset(-80, 0));
        await tester.pump(const Duration(seconds: 1));
        final editedDj = await DjVoiceService.loadSettings();
        expect(editedDj.every, 10);
        expect(editedDj.volume, isNot(0.7));
        expect(editedDj.character, originalDj.character);
        await tester.binding.handlePopRoute();
        await tester.pump(const Duration(seconds: 1));
        await tester.tap(find.byTooltip('DJ voice'));
        await tester.pump(const Duration(seconds: 1));
        expect(find.text('Talks every 10 songs'), findsOneWidget);
        expect(playerService.playbackState.value.playing, isTrue);
        expect(GetIt.instance<QueueService>().getCurrentTrack()!.id, queueBeforeControls);
        expect(playerService.playbackPosition, greaterThan(playbackPosition));
        final randomTiming = find.byKey(const ValueKey('djRandomTiming'));
        await tester.ensureVisible(randomTiming);
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(randomTiming);
        await tester.pump(const Duration(milliseconds: 500));
        expect((await DjVoiceService.loadProfile()).randomTiming, isTrue);
        expect(find.byKey(const ValueKey('djVoiceEvery')), findsNothing);
        await tester.binding.handlePopRoute();
        await tester.pump(const Duration(milliseconds: 500));
        await tester.tap(find.byTooltip('DJ voice'));
        await tester.pump(const Duration(milliseconds: 500));
        expect((await DjVoiceService.loadProfile()).randomTiming, isTrue);
        await tester.ensureVisible(randomTiming);
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(randomTiming);
        await tester.pump(const Duration(milliseconds: 500));
        expect((await DjVoiceService.loadProfile()).randomTiming, isFalse);
        expect(find.text('Talks every 10 songs'), findsOneWidget);
        expect(playerService.playbackState.value.playing, isTrue);
        expect(GetIt.instance<QueueService>().getCurrentTrack()!.id, queueBeforeControls);
        final lengthControl = find.byType(DropdownButtonFormField<DjAnnouncementLength>);
        await tester.ensureVisible(lengthControl);
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(lengthControl);
        await tester.pump(const Duration(milliseconds: 500));
        await tester.tap(find.text('Brief').last);
        await tester.pump(const Duration(milliseconds: 500));
        expect((await DjVoiceService.loadProfile()).length, DjAnnouncementLength.brief);

        final voiceApis = find.byKey(const ValueKey('voiceApiSettings'));
        await tester.ensureVisible(voiceApis);
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.descendant(of: voiceApis, matching: find.text('Voice API')));
        await tester.pump(const Duration(milliseconds: 500));
        final boostSwitch = find.byKey(const ValueKey('voiceBoost'));
        await tester.ensureVisible(boostSwitch);
        await tester.tap(boostSwitch);
        await tester.pump(const Duration(milliseconds: 500));
        expect((await AiService.getSpeechSettings()).boost, isFalse);
        final primaryApi = find.byType(DropdownButtonFormField<AiProvider>);
        await tester.ensureVisible(primaryApi);
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(primaryApi);
        await tester.pump(const Duration(milliseconds: 500));
        await tester.tap(find.text('OpenAI').last);
        await tester.pump(const Duration(milliseconds: 500));
        expect((await AiService.getSpeechSettings()).order, [AiProvider.openai, AiProvider.gemini]);
        final backup = find.byKey(const ValueKey('voiceApiFallback-gemini'));
        await tester.ensureVisible(backup);
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(backup);
        await tester.pump(const Duration(milliseconds: 500));
        expect((await AiService.getSpeechSettings()).fallbacks, isEmpty);
        await tester.tap(backup);
        await tester.pump(const Duration(milliseconds: 500));
        expect((await AiService.getSpeechSettings()).fallbacks, [AiProvider.gemini]);
        expect(GetIt.instance<QueueService>().getCurrentTrack()!.id, queueBeforeControls);
        expect(playerService.playbackState.value.playing, isTrue);

        // Exercise real WAV decoding and voice dismissal over native music,
        // without using a paid AI service or relying on an installed TTS engine.
        await AiService.setProvider(AiProvider.gemini);
        await AiService.setApiKey(AiProvider.gemini, 'integration-dj-test');
        await AiService.setApiKey(AiProvider.openai, 'integration-openai-test');
        final pcm = ByteData(24000 * 4 * 2);
        for (var i = 0; i < 24000 * 4; i++) {
          pcm.setInt16(i * 2, (3000 * sin(2 * pi * 180 * i / 24000)).round(), Endian.little);
        }
        final audio = base64Encode(pcm.buffer.asUint8List());
        var openaiRequests = 0, geminiRequests = 0;
        var voiceKeysCorrect = true;
        final voice = http.runWithClient(
          () => DjVoiceService.preview(
            'Here is a short DJ announcement for checking the music playback.',
            profile: const DjVoiceProfile(),
          ),
          () => MockClient((request) async {
            if (request.url.host == 'api.openai.com') {
              openaiRequests++;
              voiceKeysCorrect =
                  voiceKeysCorrect &&
                  request.headers['authorization'] == 'Bearer integration-openai-test' &&
                  request.headers['x-goog-api-key'] == null;
              return http.Response('', 503);
            }
            geminiRequests++;
            voiceKeysCorrect =
                voiceKeysCorrect &&
                request.headers['x-goog-api-key'] == 'integration-dj-test' &&
                request.headers['authorization'] == null;
            return http.Response(
              jsonEncode(
                request.method == 'GET'
                    ? {
                        'models': [
                          {'name': 'models/gemini-3.8-flash-tts'},
                        ],
                      }
                    : {
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
                      },
              ),
              200,
            );
          }),
        );
        final voiceDeadline = DateTime.now().add(const Duration(seconds: 10));
        while (!DjVoiceService.status.value.$1 && DateTime.now().isBefore(voiceDeadline)) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(DjVoiceService.status.value.$1, isTrue);
        expect(openaiRequests, 1);
        expect(geminiRequests, 2);
        expect(voiceKeysCorrect, isTrue);
        expect(AiService.lastSpeechProvider.value, AiProvider.gemini);
        expect(find.text('Last voice API: Gemini'), findsOneWidget);
        expect((await AiService.getSpeechSettings()).primary, AiProvider.openai);
        expect((await AiService.getSpeechSettings()).boost, isFalse);
        await tester.pump(const Duration(milliseconds: 1400));
        expect(playerService.crossfadeBaseVolume, lessThan(playerService.djVoiceBaseVolume * .5));
        await tester.ensureVisible(find.text('Skip announcement'));
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.text('Skip announcement'));
        await voice.timeout(const Duration(seconds: 10));
        await tester.pump(const Duration(milliseconds: 300));
        expect(DjVoiceService.status.value.$1, isFalse);
        expect(playerService.crossfadeBaseVolume, closeTo(playerService.djVoiceBaseVolume, .001));
        expect(playerService.playbackState.value.playing, isTrue);
        expect(GetIt.instance<QueueService>().getCurrentTrack()!.id, queueBeforeControls);
        expect(DjVoiceService.transcript.value, 'Here is a short DJ announcement for checking the music playback.');
        var replayRequests = 0;
        await http.runWithClient(
          DjVoiceService.replayAnnouncement,
          () => MockClient((_) async {
            replayRequests++;
            throw StateError('Replay must reuse its saved audio without a network request');
          }),
        );
        expect(replayRequests, 0);
        expect(DjVoiceService.status.value.$1, isFalse);
        expect(playerService.crossfadeBaseVolume, closeTo(playerService.djVoiceBaseVolume, .001));
        expect(playerService.playbackState.value.playing, isTrue);
        expect(GetIt.instance<QueueService>().getCurrentTrack()!.id, queueBeforeControls);
        await tester.tap(find.text('Temporary quiet'));
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(find.text('15 minutes'));
        await tester.pump(const Duration(milliseconds: 400));
        expect(DjVoiceService.isQuiet, isTrue);
        await tester.tap(find.text('Resume DJ'));
        await tester.pump(const Duration(milliseconds: 400));
        expect(DjVoiceService.isQuiet, isFalse);
        await tester.binding.handlePopRoute();
        await tester.pump(const Duration(seconds: 1));
        await tester.binding.handlePopRoute();
        await tester.pump(const Duration(seconds: 1));
      } finally {
        await DjVoiceService.resumeDj();
        await DjVoiceService.saveProfile(originalDjProfile);
        await AiService.setApiKey(AiProvider.gemini, originalGeminiKey);
        await AiService.setApiKey(AiProvider.openai, originalOpenAiKey);
        await DjVoiceService.saveSpeechSettings(originalSpeech);
        await AiService.setProvider(originalProvider);
      }
      await playerService.pause(disableFade: true);
      final paused = playerService.playbackPosition;
      await Future<void>.delayed(const Duration(seconds: 2));
      expect((playerService.playbackPosition - paused).inMilliseconds.abs(), lessThan(1000));
      expect(playerService.playbackState.value.playing, isFalse);

      const target = Duration(seconds: 12);
      await playerService.seek(target);
      await tester.pump();
      expect((playerService.playbackPosition - target).inMilliseconds.abs(), lessThan(1500));
      unawaited(playerService.play(disableFade: true));
      await Future<void>.delayed(const Duration(seconds: 4));
      await tester.pump();
      expect(playerService.playbackPosition, greaterThan(target + const Duration(seconds: 2)));
      expect(playerService.playbackState.value.playing, isTrue);

      final queue = GetIt.instance<QueueService>();
      resumeId = queue.getCurrentTrack()!.baseItem.id.raw;
      if (queue.getQueue().upcomingTrackCount == 0) {
        // Demo albums can contain one song. An explicit Next Up request still
        // exercises a real native transition and its distinct queue entry.
        final current = queue.getCurrentTrack()!.baseItem;
        await queue.addToNextUp(PlayableSlice.simple([current], QueueItemSource.fromBaseItem(current)));
      }
      final before = queue.getCurrentTrack()!.id;
      await playerService.skipToNext();
      await Future<void>.delayed(const Duration(seconds: 2));
      await tester.pump();
      expect(queue.getCurrentTrack()!.id, isNot(before));
      expect(mainErrors, isEmpty, reason: 'Background errors must fail the device smoke test');

      // Check normalization while this player and its UI are still live: the
      // widget-test teardown stops the native audio service between test cases.
      {
        final player = GetIt.instance<MusicPlayerBackgroundTask>();
        unawaited(player.play(disableFade: true));
        await Future<void>.delayed(const Duration(seconds: 1));
        await tester.pump();
        expect(player.playbackState.value.playing, isTrue);
        final queue = GetIt.instance<QueueService>();
        final track = queue.getCurrentTrack()!;
        final server = GetIt.instance<FinampUserHelper>().currentUser!.serverId;
        final settings = FinampSettingsHelper.finampSettings;
        final old = (settings.volumeNormalizationActive, settings.normalizationLevel, settings.volumeNormalizationMode);
        final analyzer = await AnalyzerService.getSettings();
        Future<void> measure(double? lufs) async {
          LoudnessCache.instance.invalidateRequests();
          await http.runWithClient(
            () => LoudnessCache.instance.fetch(server, [track.baseItem.id.raw]),
            () => MockClient(
              (_) async => http.Response(
                jsonEncode({
                  if (lufs != null) track.baseItem.id.raw: {'version': 1, 'lufs': lufs, 'truePeak': -1},
                }),
                200,
              ),
            ),
          );
        }

        try {
          await AnalyzerService.saveSettings(url: 'https://analyzer.invalid', token: 'test');
          FinampSetters.setVolumeNormalizationActive(true);
          FinampSetters.setVolumeNormalizationMode(VolumeNormalizationMode.trackBased);
          FinampSetters.setNormalizationLevel(0);
          await tester.pump(const Duration(milliseconds: 200));
          await measure(-8);
          FinampSetters.setNormalizationLevel(1);
          await tester.pump(const Duration(milliseconds: 200));
          await player.configureNormalization(player.playerPlatformId!, track.item);
          final frozen = NormalizationSession.playback.get(server, track.item.id)!;
          expect(frozen.source, NormalizationSource.track);
          expect(frozen.gainDb, closeTo(-6 - HeadphoneEqService.headroomDb, .001));
          final position = player.playbackPosition;
          await measure(-20);
          await player.configureNormalization(player.playerPlatformId!, track.item);
          expect(identical(NormalizationSession.playback.get(server, track.item.id), frozen), isTrue);
          expect(getGainForCurrentPlayback(track.item, track.baseItem), frozen.gainDb);
          unawaited(
            showDialog<void>(
              context: tester.element(find.byType(Scaffold).first),
              builder: (_) => NormalizationDetailsDialog(item: track.baseItem),
            ),
          );
          await tester.pump(const Duration(milliseconds: 500));
          expect(find.text('Track normalization'), findsOneWidget);
          expect(find.textContaining('Volume adjustment:'), findsOneWidget);
          expect(find.textContaining('This adjustment stays steady'), findsOneWidget);
          await tester.tap(find.text('Close'));
          await Future<void>.delayed(const Duration(seconds: 1));
          await tester.pump();
          expect(queue.getCurrentTrack()!.id, track.id);
          expect(player.playbackPosition, greaterThan(position));
        } finally {
          await measure(null);
          FinampSetters.setVolumeNormalizationActive(old.$1);
          FinampSetters.setNormalizationLevel(old.$2);
          FinampSetters.setVolumeNormalizationMode(old.$3);
          await AnalyzerService.saveSettings(url: analyzer.url ?? '', token: analyzer.token ?? '');
        }
      }
      expect(mainErrors, isEmpty, reason: 'Normalization must not add background playback errors');
    });

    testWidgets('Server hub, TV pairing and explicit queue resume', (tester) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final previous = await AnalyzerService.getSettings();
      var created = false, closed = false, authenticated = true, correctRoomName = false;
      server.listen((request) async {
        if (request.uri.path.startsWith('/hub/')) {
          authenticated =
              authenticated &&
              request.headers.value('X-Api-Key') == 'test-hub' &&
              (request.headers.value('X-Jellyfin-Token')?.isNotEmpty ?? false);
        }
        final payload = await utf8.decoder.bind(request).join();
        final data = payload.isEmpty ? <String, dynamic>{} : Map<String, dynamic>.from(jsonDecode(payload) as Map);
        Object body = {};
        switch (request.uri.path) {
          case '/hub/api/status':
            body = {'administrator': true};
          case '/hub/api/sync':
            body = {
              'stations': <dynamic>[],
              'preferences': null,
              'history': <dynamic>[],
              'queue': {
                'ids': [resumeId],
                'index': 0,
                'positionMs': 12000,
              },
            };
          case '/hub/api/sync/items':
            body = <dynamic>[];
          case '/hub/api/blocked':
            body = {'ids': <String>[]};
          case '/hub/api/rooms':
            created = true;
            correctRoomName = data['name'] == 'Karaoke party';
            body = {
              'id': 'room1',
              'name': 'TV test',
              'code': '123456',
              'screen': 'screen-test',
              'control': 'control-test',
            };
          case '/hub/api/rooms/room1':
            closed = true;
        }
        request.response.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
        request.response.write(jsonEncode(body));
        await request.response.close();
      });
      addTearDown(() async {
        await GetIt.instance<MusicPlayerBackgroundTask>().stop();
        await AnalyzerService.saveSettings(url: previous.url ?? '', token: previous.token ?? '');
        await server.close(force: true);
      });
      await AnalyzerService.saveSettings(url: 'http://127.0.0.1:${server.port}', token: 'test-hub');
      await tester.pumpWidget(const MaterialApp(home: ServerHubScreen()));
      await tester.waitFor(find.text('Open server controls'));
      await tester.tap(find.text('Create room'));
      await tester.waitFor(find.text('Pairing code: 123456'));
      expect(created, isTrue);
      expect(correctRoomName, isTrue);
      await tester.ensureVisible(find.text('Close room'));
      await tester.tap(find.text('Close room'));
      await tester.pumpAndSettle();
      expect(closed, isTrue);
      await tester.ensureVisible(find.text('Resume here'));
      await tester.tap(find.text('Resume here'));
      final player = GetIt.instance<MusicPlayerBackgroundTask>();
      for (var i = 0; i < 20 && player.paused; i++) {
        await tester.pump(const Duration(seconds: 1));
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      expect(player.paused, isFalse);
      expect(player.playbackPosition.inSeconds, greaterThanOrEqualTo(10));
      expect(authenticated, isTrue);
      expect(mainErrors, isEmpty);
    });
    // TODO add test where we migrate from old settings data?
  });
}

extension WaitForElement on WidgetTester {
  Future<void> waitFor(Finder finder, {int seconds = 20, bool realtime = true}) async {
    int i = 0;
    while (true) {
      await pump(Duration(seconds: 1));
      if (any(finder)) {
        return;
      }
      if (i >= seconds) {
        throw "$finder never found expected widget after $seconds seconds.";
      }
      i++;
      if (realtime) {
        await Future<void>.delayed(Duration(seconds: 1));
      }
    }
  }
}
