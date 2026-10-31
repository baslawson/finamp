import 'dart:async';
import 'package:finamp/services/rolling_reserve_service.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/l10n/app_localizations.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart' as jellyfin_models;
import 'package:finamp/services/headphone_eq_service.dart';
import 'package:finamp/services/current_track_metadata_provider.dart';
import 'package:finamp/services/favorite_provider.dart';
import 'package:finamp/services/finamp_user_helper.dart';
import 'package:finamp/services/playback_history_service.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:finamp/services/radio_service_helper.dart' as radio_service_helper;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get_it/get_it.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:logging/logging.dart';
import 'package:rxdart/rxdart.dart';

import 'android_auto_helper.dart';
import 'finamp_settings_helper.dart';
import 'metadata_provider.dart';
import 'loudness_cache.dart';
import 'loudness_normalization.dart';
import 'normalization_session.dart';
import 'analyzer_service.dart';
import 'crossfade_service.dart';
import 'playback_buffer_policy.dart';
import 'karaoke_playback.dart';
import 'playback_recovery.dart';
import 'playback_navigation.dart';
import 'pause_cause.dart';

enum FadeDirection { fadeIn, fadeOut, none }

class FadeState {
  // current fade volume
  late final double fadeVolume;

  // volume step sizes for fade-in and fade-out
  final double volumeFadeOutStepSize;
  final double volumeFadeInStepSize;

  // current fade direction
  final FadeDirection fadeDirection;

  FadeState({
    required this.fadeVolume,
    this.volumeFadeInStepSize = 0.0,
    this.volumeFadeOutStepSize = 0.0,
    this.fadeDirection = FadeDirection.none,
  });

  FadeState copyWith({
    double? recoverVolume,
    double? fadeVolume,
    double? volumeFadeInStepSize,
    double? volumeFadeOutStepSize,
    FadeDirection? fadeDirection,
  }) {
    return FadeState(
      fadeVolume: fadeVolume ?? this.fadeVolume,
      volumeFadeInStepSize: volumeFadeInStepSize ?? this.volumeFadeInStepSize,
      volumeFadeOutStepSize: volumeFadeOutStepSize ?? this.volumeFadeOutStepSize,
      fadeDirection: fadeDirection ?? this.fadeDirection,
    );
  }
}

class PlayerVolumeController {
  static final _volumeLogger = Logger("Volume");

  PlayerVolumeController(this._player) {
    _updateVolume();
  }

  final AudioPlayer _player;

  double _internalVolume = FinampSettingsHelper.finampSettings.currentVolume;
  double _replayGainVolume = 1.0;
  double _fadeVolume = 1.0;
  double _sleepFadeVolume = 1.0;
  double _transitionVolume = 1.0;
  double _alarmVolume = 1.0;
  double _voiceVolume = 1.0;
  bool isDucked = false;
  bool nativeVoiceDucking = false;

  Future<void> setInternalVolume(double volume) {
    if (volume == _internalVolume) return Future.value();
    _internalVolume = volume;
    FinampSetters.setCurrentVolume(volume);
    return _updateVolume();
  }

  Future<void> setReplayGainVolume(double volume) {
    if (volume == _replayGainVolume) return Future.value();
    _replayGainVolume = volume;
    return _updateVolume();
  }

  Future<void> setFadeVolume(double volume) {
    if (volume == _fadeVolume) return Future.value();
    _fadeVolume = volume;
    return _updateVolume();
  }

  /// Volume factor used to gently fade out playback before a sleep timer ends.
  Future<void> setSleepFadeVolume(double volume) {
    if (volume == _sleepFadeVolume) return Future.value();
    _sleepFadeVolume = volume;
    return _updateVolume();
  }

  /// Volume factor used by the music alarm to fade in.
  Future<void> setAlarmVolume(double volume) {
    if (volume == _alarmVolume) return Future.value();
    _alarmVolume = volume;
    return _updateVolume();
  }

  /// Volume factor that lowers the music while the DJ talks.
  Future<void> setVoiceVolume(double volume, {bool force = false}) {
    if (volume == _voiceVolume && !force) return Future.value();
    _voiceVolume = volume;
    return _updateVolume();
  }

  /// The volume a second player should use to sound as loud as this one, apart from fades and gain.
  double get baseVolume =>
      (_internalVolume * _sleepFadeVolume * _alarmVolume * _voiceVolume * (isDucked ? 0.3 : 1.0)).clamp(0.0, 1.0);

  /// The volume the DJ's voice follows: everything that sets the music's level (an alarm's fade-in, a sleep fade,
  /// ducking), but not the dip for the voice itself.
  double get voiceBaseVolume =>
      (_internalVolume * _sleepFadeVolume * _alarmVolume * (isDucked ? 0.3 : 1.0)).clamp(0.0, 1.0);

  /// Volume factor used by DJ transitions to fade between songs.
  Future<void> setTransitionVolume(double volume) {
    if (volume == _transitionVolume) return Future.value();
    _transitionVolume = volume;
    return _updateVolume();
  }

  void duck() {
    if (isDucked) return;
    isDucked = true;
    _updateVolume();
  }

  void unduck() {
    if (!isDucked) return;
    isDucked = false;
    _updateVolume();
  }

  Future<void> _updateVolume() {
    var vol1 = _internalVolume.clamp(0.0, 1.0);
    var vol2 = _replayGainVolume.clamp(0.0, 1.0);
    var vol3 = _fadeVolume.clamp(0.0, 1.0);
    var vol4 = _sleepFadeVolume.clamp(0.0, 1.0);
    var vol5 = _transitionVolume.clamp(0.0, 1.0);
    var vol6 = _alarmVolume.clamp(0.0, 1.0);
    var vol7 = nativeVoiceDucking ? 1.0 : _voiceVolume.clamp(0.0, 1.0);
    var duckingFactor = isDucked ? 0.3 : 1.0;
    var totalVol = vol1 * vol2 * vol3 * vol4 * vol5 * vol6 * vol7 * duckingFactor;
    // Fine rather than info: fades update the volume several times a second.
    _volumeLogger.fine(
      "Setting volume to $totalVol - user: $_internalVolume gain: $_replayGainVolume fade: $_fadeVolume, sleep fade: $_sleepFadeVolume, ducking: $isDucked",
    );
    return _player.setVolume(totalVol.clamp(0.0, 1.0));
  }
}

/// This provider handles the currently playing music so that multiple widgets
/// can control music.
class MusicPlayerBackgroundTask extends BaseAudioHandler with SeekHandler, QueueHandler {
  final _androidAutoHelper = GetIt.instance<AndroidAutoHelper>();

  AppLocalizations? _appLocalizations;

  late final AudioPlayer _player;
  late final AudioPipeline _audioPipeline;
  late final List<AndroidAudioEffect> _androidAudioEffects;
  late final List<DarwinAudioEffect> _iosAudioEffects;

  /// Device equalizer used for headphone correction presets (Android only).
  late final AndroidEqualizer? equalizer;

  /// The player's Android audio session, which night mode attaches its compressor to.
  Stream<int?> get androidAudioSessionIdStream => _player.androidAudioSessionIdStream;

  final _audioServiceBackgroundTaskLogger = Logger("MusicPlayerBackgroundTask");
  final _volumeNormalizationLogger = Logger("VolumeNormalization");
  final _outputLogger = Logger("Output");

  /// Time window used to ignore spurious play/pause callbacks immediately
  /// after a skip command from certain Bluetooth headsets. Behavior before this fix was that a double-tap on such headsets would trigger a skip followed by an unintended pause, because the headset sent play/pause events immediately after the skip event. With this guard, if a play/pause event is received within this window after a skip command, it will be ignored.
  static const Duration _skipPlayPauseGuardWindow = Duration(milliseconds: 50);

  /// Timestamp of the most recent explicit skip command (next/previous).
  DateTime? _lastSkipCommandAt;

  // Init the new sleep timer with a length of 0
  // SleepTimer sleepTimer = SleepTimer(SleepTimerType.duration, 0);

  /// Holds the current sleep timer, if any. This is a ValueNotifier so that
  /// widgets like SleepTimerButton can update when the sleep timer is/isn't
  /// null.
  final ValueNotifier<SleepTimer?> _timer = ValueNotifier<SleepTimer?>(null);
  ValueListenable<SleepTimer?> get timer => _timer;

  Future<bool> Function()? _queueCallbackPreviousTrack;

  List<int> get shuffleIndices => _player.shuffleIndices;
  List<AudioSource> get audioSources => _player.audioSources;

  late final PlayerVolumeController _volume = PlayerVolumeController(_player);
  Duration minBufferDuration = Duration(seconds: 90);

  final _audioFadeStepDuration = Duration(milliseconds: 50);
  late final BehaviorSubject<FadeState> fadeState;

  final outputSwitcherChannel = MethodChannel('com.unicornsonlsd.finamp/output_switcher');

  /// Some Bluetooth headsets send skip and pause/play media button events in
  /// very quick succession for a double-tap skip gesture. This guard ignores a
  /// trailing play/pause event if it arrives right after skip, preventing an
  /// unintended pause while still allowing normal controls outside the window.
  bool get _shouldIgnorePlayPauseAfterRecentSkip {
    final lastSkipCommandAt = _lastSkipCommandAt;
    if (lastSkipCommandAt == null) return false;

    final elapsed = DateTime.now().difference(lastSkipCommandAt);
    if (elapsed <= _skipPlayPauseGuardWindow) {
      _audioServiceBackgroundTaskLogger.fine(
        "Ignoring play/pause because skip was ${elapsed.inMilliseconds}ms ago (threshold ${_skipPlayPauseGuardWindow.inMilliseconds}ms)",
      );
      return true;
    }
    return false;
  }

  Future<void> showOutputSwitcherDialog() async {
    if (!Platform.isAndroid) {
      return;
    }
    try {
      _outputLogger.fine("Showing output switcher dialog");
      await outputSwitcherChannel.invokeMethod('showOutputSwitcherDialog');
      _outputLogger.finer("Output switcher dialog shown");
    } on PlatformException catch (e) {
      _outputLogger.severe("Failed to show output switcher dialog: ${e.message}");
    } catch (e) {
      _outputLogger.severe("Failed to show output switcher dialog: $e");
    }
  }

  Future<void> openBluetoothSettings() async {
    if (!Platform.isAndroid) {
      return;
    }
    try {
      _outputLogger.fine("Opening Bluetooth settings");
      await outputSwitcherChannel.invokeMethod('openBluetoothSettings');
    } on PlatformException catch (e) {
      _outputLogger.severe("Failed to open Bluetooth settings: ${e.message}");
    } catch (e) {
      _outputLogger.severe("Failed to open Bluetooth settings: $e");
    }
  }

  Future<List<FinampOutputRoute>> getRoutes() async {
    if (!Platform.isAndroid) {
      return [];
    }
    try {
      final List<Object?>? rawObjects = await outputSwitcherChannel.invokeMethod<List<Object?>>('getRoutes');

      final routes =
          rawObjects
              ?.map((obj) => Map<String, dynamic>.from(obj as Map))
              .map((route) => FinampOutputRoute.fromJson(route))
              .toList() ??
          [];
      return routes;
    } on PlatformException catch (e) {
      _outputLogger.severe("Failed to get routes: ${e.message}");
      return [];
    } catch (e) {
      _outputLogger.severe("Failed to get routes: $e");
      return [];
    }
  }

  Future<void> setOutputToDeviceSpeaker() async {
    if (!Platform.isAndroid) {
      return;
    }
    try {
      await outputSwitcherChannel.invokeMethod('setOutputToDeviceSpeaker');
    } on PlatformException catch (e) {
      _outputLogger.severe("Failed to switch output: ${e.message}");
    } catch (e) {
      _outputLogger.severe("Failed to switch output: $e");
    }
  }

  Future<void> setOutputToBluetoothDevice() async {
    if (!Platform.isAndroid) {
      return;
    }
    try {
      await outputSwitcherChannel.invokeMethod('setOutputToBluetoothDevice');
    } on PlatformException catch (e) {
      _outputLogger.severe("Failed to switch output: ${e.message}");
    } catch (e) {
      _outputLogger.severe("Failed to switch output: $e");
    }
  }

  Future<void> setOutputToRoute(FinampOutputRoute route) async {
    if (!Platform.isAndroid) {
      return;
    }
    try {
      await outputSwitcherChannel.invokeMethod('setOutputToRouteByName', {'name': route.name});
    } on PlatformException catch (e) {
      _outputLogger.severe("Failed to switch output: ${e.message}");
    } catch (e) {
      _outputLogger.severe("Failed to switch output: $e");
    }
  }

  static Future<void> configureAudioSession() async {
    final session = await AudioSession.instance;
    await session.configure(
      FinampSettingsHelper.finampSettings.duckOnAudioInterruption
          ? const AudioSessionConfiguration.music()
          : const AudioSessionConfiguration.music().copyWith(
              // disable Android automatic ducking (https://developer.android.com/media/optimize/audio-focus#automatic_ducking)
              // so that we can handle it manually, by setting the content type to "speech"
              // if we instead set `willPauseOnDucked` to `true`, Android will send us pause events instead of duck events
              // and then we don't know how to properly handle them (is this just a notification or a phone call?)
              androidAudioAttributes: const AndroidAudioAttributes(
                contentType: AndroidAudioContentType.speech,
                usage: AndroidAudioUsage.media,
              ),
            ),
    );
  }

  MusicPlayerBackgroundTask() {
    _audioServiceBackgroundTaskLogger.info("Starting audio service");

    if (Platform.isWindows || Platform.isLinux) {
      _audioServiceBackgroundTaskLogger.info("Initializing media-kit for Windows/Linux");
      JustAudioMediaKit.title = "Finamp";
      JustAudioMediaKit.prefetchPlaylist = true; // cache upcoming tracks, enable gapless playback
      JustAudioMediaKit.bufferSize = FinampSettingsHelper.finampSettings.bufferSizeMegabytes * 1024 * 1024;
      JustAudioMediaKit.ensureInitialized(linux: true, windows: true, macOS: false, iOS: false, android: false);
    }

    _androidAudioEffects = [];
    _iosAudioEffects = [];

    equalizer = Platform.isAndroid ? AndroidEqualizer() : null;
    if (equalizer != null) {
      _androidAudioEffects.add(equalizer!);
      unawaited(HeadphoneEqService.applySaved(equalizer!));
    }

    _audioPipeline = AudioPipeline(androidAudioEffects: _androidAudioEffects, darwinAudioEffects: _iosAudioEffects);

    Duration maxBufferDuration = Duration(
      seconds: max(minBufferDuration.inSeconds, FinampSettingsHelper.finampSettings.bufferDuration.inSeconds),
    );

    AudioSession.instance.then((session) {
      bool wasPlayingBeforeInterruption = false;
      session.interruptionEventStream.listen((event) {
        // Logged however it's handled: with ducking on, the player pauses for it on its own.
        _outputLogger.info(
          'Audio interruption ${event.begin ? 'began' : 'ended'}: ${event.type.name} (another app or the system took the sound)',
        );
        bool customInterruptionHandlingNeeded = !FinampSettingsHelper.finampSettings.duckOnAudioInterruption;
        if (!customInterruptionHandlingNeeded) {
          return;
        }
        if (event.begin) {
          switch (event.type) {
            case AudioInterruptionType.duck:
              // if we are in here, then ducking should be disabled anyway, so this is a no-op
              break;
            case AudioInterruptionType.pause:
            case AudioInterruptionType.unknown:
              // Another app started playing audio and we should pause.
              wasPlayingBeforeInterruption = _player.playing;
              pause(cause: 'another app or the system taking the sound');
              break;
          }
        } else {
          switch (event.type) {
            case AudioInterruptionType.duck:
              // The interruption ended and we should unduck.
              // keeping this in here won't hurt, and ensures we never become stuck in a ducked state
              _volume.unduck();
              break;
            case AudioInterruptionType.pause:
              // The interruption ended and we should resume.
              if (wasPlayingBeforeInterruption) {
                play();
              }
              break;
            case AudioInterruptionType.unknown:
              // The interruption ended but we should not resume.
              break;
          }
        }
      });
      session.becomingNoisyEventStream.listen((_) {
        _outputLogger.info('Headphones or speaker disconnected while playing');
        // The user unplugged/disconnected the headphones/speaker/car, so we should pause ~~or lower~~ the volume.
        if (FinampSettingsHelper.finampSettings.duckOnAudioInterruption) {
          // if this is enabled, we let the [AudioPlayer] handle this automatically, via [handleInterruptions]
        } else {
          // if ducking is disabled, the audio player doesn't handle interruptions on its own, so we need to make sure to pause
          pause(cause: 'the headphones or speaker disconnecting');
        }
      });
      session.devicesChangedEventStream.listen((event) {
        _outputLogger.info('Devices added:   ${event.devicesAdded}');
        _outputLogger.info('Devices removed: ${event.devicesRemoved}');
      });
    });

    _player = AudioPlayer(
      maxSkipsOnError: 0,
      handleInterruptions: FinampSettingsHelper.finampSettings.duckOnAudioInterruption,
      androidAudioOffloadPreferences: AndroidAudioOffloadPreferences(
        // Native playback suspends offload while normalization needs PCM.
        audioOffloadMode: FinampSettingsHelper.finampSettings.forceAudioOffloadingOnAndroid
            ? AndroidAudioOffloadMode.enabled
            : AndroidAudioOffloadMode.disabled,
        isGaplessSupportRequired: true,
        isSpeedChangeSupportRequired: true,
      ),
      audioLoadConfiguration: AudioLoadConfiguration(
        androidLoadControl: AndroidLoadControl(
          targetBufferBytes: FinampSettingsHelper.finampSettings.bufferDisableSizeConstraints
              ? null
              : PlaybackBufferPolicy.mainBudget(1024 * 1024 * FinampSettingsHelper.finampSettings.bufferSizeMegabytes),
          // minBufferDuration: FinampSettingsHelper.finampSettings.bufferDuration, //!!! there are issues with the bufferForPlaybackDuration setting, the min duration seemingly has to be smaller than that. so we're using the default
          // it seems like the player won't fetch more than [minBufferDuration], even if the buffer isn't filled yet
          // so if we ignore size constraints, we just set the minimum to the specified buffer size, but allow fetching even more to reduce the request frequency
          minBufferDuration: FinampSettingsHelper.finampSettings.bufferDisableSizeConstraints
              ? maxBufferDuration
              : minBufferDuration,
          maxBufferDuration:
              // allows the player to fetch a bit more data in exchange for reduced request frequency
              FinampSettingsHelper.finampSettings.bufferDisableSizeConstraints
              ? (maxBufferDuration + Duration(seconds: 90))
              : maxBufferDuration,
          prioritizeTimeOverSizeThresholds: FinampSettingsHelper
              .finampSettings
              .bufferDisableSizeConstraints, // targetBufferBytes sets the absolute maximum, but if this false and maxBufferDuration is reached, buffering will end
          bufferForPlaybackDuration: Duration(seconds: 5),
          bufferForPlaybackAfterRebufferDuration: Duration(seconds: 10),
        ),
        darwinLoadControl: DarwinLoadControl(
          // preferredForwardBufferDuration:
          //     FinampSettingsHelper.finampSettings.bufferDuration,
          preferredForwardBufferDuration: FinampSettingsHelper.finampSettings.bufferDisableSizeConstraints
              ? FinampSettingsHelper.finampSettings.bufferDuration
              : null, // let system decide
        ),
      ),
      audioPipeline: _audioPipeline,
    );

    _player.onPlatformId = (id) {
      final track = _normalizingTrack ?? mediaItem.valueOrNull;
      if (track != null) unawaited(configureNormalization(id, track));
    };
    unawaited(LoudnessCache.instance.load().then((_) => _applyVolumeNormalization(mediaItem.valueOrNull)));
    AnalyzerService.configurationChanges.stream.listen((_) {
      LoudnessCache.instance.invalidateRequests();
      if (_normalizingTrack != null) unawaited(prepareNormalization([_normalizingTrack!]));
    });
    HeadphoneEqService.onHeadroomChanged = (_) async {
      NormalizationSession.playback.clear();
      await _refreshNormalization();
    };

    // Propagate all events from the audio player to AudioService clients.
    int? replayQueueIndex;
    _player.playbackEventStream.listen((event) async {
      final playerSequence = _player.sequenceState.sequence;
      if (playerSequence.isNotEmpty) {
        if (event.currentIndex != replayQueueIndex) {
          replayQueueIndex = event.currentIndex;
          if (replayQueueIndex != null && playerSequence.elementAtOrNull(replayQueueIndex!) != null) {
            var queueItem =
                // event.currentIndex is based on the original sequence, not the effectiveSequence
                playerSequence[replayQueueIndex!].tag as FinampQueueItem?;
            if (queueItem != null) {
              _applyVolumeNormalization(queueItem.item);
            }
          }
        }
      }
      playbackState.add(_transformEvent(event));
    }, onError: (Object error, StackTrace stackTrace) => unawaited(_skipUnplayable(error)));

    var previousNormalization = _normalizationSettings;
    var previouslyOffline = FinampSettingsHelper.finampSettings.isOffline;
    FinampSettingsHelper.finampSettingsListener.addListener(() {
      final offline = FinampSettingsHelper.finampSettings.isOffline;
      if (previouslyOffline && !offline) {
        LoudnessCache.instance.invalidateRequests();
        if (_normalizingTrack != null) unawaited(prepareNormalization([_normalizingTrack!]));
      }
      previouslyOffline = offline;
      final current = _normalizationSettings;
      if (previousNormalization == current) return;
      previousNormalization = current;
      NormalizationSession.playback.clear();
      unawaited(_refreshNormalization());
    });

    // Re-evaluate intentional album playback when the queue context changes.
    mediaItem.listen((currentTrack) {
      _applyVolumeNormalization(currentTrack);
    });

    // But sleepTimer doesn't want to listen on queue changes
    mediaItem.distinct().listen((currentTrack) {
      sleepTimer?.onTrackCompleted(trackEndedNormally: false, track: currentTrack);
    });

    _player.errorStream.listen((error) {
      _audioServiceBackgroundTaskLogger.severe("Player error: $error", error);
      // Errors while playing (like a file no extractor can read) come here, not as stream errors.
      unawaited(_skipUnplayable(error));
    });

    // trigger sleep timer early if we're almost at the end of the final track
    _player.positionStream.listen((position) {
      if (sleepTimer?.remainingTracks == 1 &&
          ((mediaItem.value?.duration ?? Duration.zero) - position).inMilliseconds / _player.speed <=
              // even if fade out is disabled, we stop a bit early to avoid advancing to the next track
              max(
                Duration(milliseconds: 500).inMilliseconds,
                FinampSettingsHelper.finampSettings.audioFadeOutDuration.inMilliseconds,
              )) {
        _audioServiceBackgroundTaskLogger.info(
          "Sleep timer: triggering early end of final track "
          "(remaining position: ${((mediaItem.value?.duration ?? Duration.zero) - position).inMilliseconds}ms, "
          "threshold: ${max(Duration(milliseconds: 500).inMilliseconds, FinampSettingsHelper.finampSettings.audioFadeOutDuration.inMilliseconds)}ms)",
        );
        sleepTimer?.onTrackCompleted(trackEndedNormally: true, track: mediaItem.value);
      }
    });

    // Special processing for state transitions.
    _player.processingStateStream.listen((event) async {
      if (event == ProcessingState.completed) {
        await handleEndOfQueue();
      }
    });

    fadeState = BehaviorSubject.seeded(FadeState(fadeVolume: 1.0));
  }

  SleepTimer? get sleepTimer => _timer.value;

  /// this could be useful for updating queue state from this player class, but isn't used right now due to limitations with just_audio
  void setQueueCallbacks({required Future<bool> Function() previousTrackCallback}) {
    _queueCallbackPreviousTrack = previousTrackCallback;
  }

  int _queueLoadGeneration = 0;
  // Queue edits also invalidate karaoke recovery, without cancelling ordinary queue loads.
  int _queueRevision = 0;
  ShuffleOrder? _queueShuffleOrder;
  String? _karaokeQueueId;
  String? _karaokeMediaId;
  File? _karaokeFile;
  LoudnessMeasurement? _karaokeMeasurement;
  Future<void> _karaokeOperation = Future.value();
  bool _karaokeSwitching = false;
  ({String song, File file, LoudnessMeasurement? measurement})? _savedKaraoke;

  bool get karaokeActive =>
      _karaokeSwitching ||
      mediaItem.valueOrNull?.extras?['karaokeSaved'] == true ||
      (_karaokeFile != null && mediaItem.valueOrNull?.id == _karaokeMediaId);

  /// The karaoke mix the current song plays, if any. A saved song keeps its own mix until another is applied.
  String? get karaokeMixPath {
    final current = mediaItem.valueOrNull;
    if (_karaokeFile != null && current?.id == _karaokeMediaId) return _karaokeFile!.path;
    if (current?.extras?['karaokeSaved'] != true) return null;
    return current?.extras?['downloadedTrackPath'] as String?;
  }

  Future<void> playSavedKaraoke(
    jellyfin_models.BaseItemDto item,
    File file,
    LoudnessMeasurement? measurement,
    String sourceName,
  ) async {
    _karaokeSwitching = true;
    try {
      await CrossfadeService.cancelForKaraoke();
      _savedKaraoke = (song: item.id.raw, file: file, measurement: measurement);
      await GetIt.instance<QueueService>().startPlayback(
        items: [item],
        beginPlaying: false,
        source: QueueItemSource.rawId(
          type: QueueItemSourceType.unknown,
          id: 'savedKaraoke',
          name: QueueItemSourceName(type: QueueItemSourceNameType.preTranslated, pretranslatedName: sourceName),
        ),
        order: FinampPlaybackOrder.linear,
      );
      final current = _player.sequenceState.currentSource?.tag;
      if (current is! FinampQueueItem ||
          current.baseItem.id != item.id ||
          current.item.extras?['karaokeSaved'] != true) {
        throw StateError('The saved karaoke song could not be loaded');
      }
      unawaited(play());
    } finally {
      _savedKaraoke = null;
      _karaokeSwitching = false;
    }
  }

  /// Replace only the selected queue entry's audio; its Jellyfin identity, lyrics and queue order stay intact.
  /// Calls are serialized so leaving the screen during a load always restores the original afterwards.
  Future<void> setKaraokeMix({required String queueId, File? file, LoudnessMeasurement? measurement}) {
    final operation = _karaokeOperation.catchError((Object _) {}).then((_) async {
      if (file == null && _karaokeQueueId != queueId) return;
      _karaokeSwitching = true;
      try {
        await CrossfadeService.cancelForKaraoke();
        final sequence = _player.sequenceState.sequence;
        final index = _player.currentIndex;
        if (index == null || index >= sequence.length) return;
        final current = sequence[index].tag as FinampQueueItem;
        if (file != null && current.id != queueId) return;
        if (file == null && _karaokeQueueId != queueId) return;
        final items = sequence.map((s) => s.tag as FinampQueueItem).toList();
        final position = _player.position;
        final playing = _player.playing;
        final generation = _queueLoadGeneration;
        final previous = (_karaokeQueueId, _karaokeMediaId, _karaokeFile, _karaokeMeasurement);
        final order = _queueShuffleOrder;
        final indices = List<int>.from(_player.shuffleIndices);
        final priorOverride = order is NextUpShuffleOrder ? order.shuffleIndicesOverride : null;
        var loadGeneration = generation;
        var queueRevision = _queueRevision;
        bool ownsLoad() => loadGeneration == _queueLoadGeneration && queueRevision == _queueRevision;
        Future<void> reload() async {
          loadGeneration = _queueLoadGeneration + 1;
          queueRevision = _queueRevision + 1;
          await GetIt.instance<QueueService>().duringPlayerReload(queueIndex ?? 0, () async {
            await setQueueItems(
              items,
              initialIndex: index,
              initialPosition: position,
              shuffleOrder: order,
              rethrowErrors: true,
            );
          });
        }

        try {
          await reloadKaraokeAudio(
            pause: () => pause(disableFade: true),
            stillSelected: () =>
                ownsLoad() &&
                _player.currentIndex == index &&
                listEquals(
                  items.map((item) => item.id).toList(),
                  _player.sequenceState.sequence.map((source) => (source.tag as FinampQueueItem).id).toList(),
                ),
            load: () async {
              _karaokeQueueId = file == null ? null : queueId;
              _karaokeMediaId = file == null ? null : current.item.id;
              _karaokeFile = file;
              _karaokeMeasurement = measurement;
              if (order is NextUpShuffleOrder) order.shuffleIndicesOverride = indices;
              await reload();
            },
            ownsLoad: ownsLoad,
            restore: () async {
              _karaokeQueueId = previous.$1;
              _karaokeMediaId = previous.$2;
              _karaokeFile = previous.$3;
              _karaokeMeasurement = previous.$4;
              await reload();
            },
            resume: playing
                ? () {
                    if (GetIt.instance<QueueService>().getCurrentTrack()?.id == current.id) {
                      unawaited(play(disableFade: true));
                    }
                  }
                : null,
          );
        } finally {
          if (order is NextUpShuffleOrder && identical(order.shuffleIndicesOverride, indices)) {
            order.shuffleIndicesOverride = priorOverride;
          }
        }
      } finally {
        _karaokeSwitching = false;
      }
    });
    _karaokeOperation = operation;
    return operation;
  }

  double? _karaokeGain(MediaItem track) {
    final saved = track.extras?['karaokeLoudness'];
    final measurement = track.id == _karaokeMediaId && _karaokeFile != null
        ? _karaokeMeasurement
        : saved is Map
        ? LoudnessMeasurement.fromJson(Map<String, dynamic>.from(saved))
        : null;
    return (track.id == _karaokeMediaId && _karaokeFile != null) || track.extras?['karaokeSaved'] == true
        ? normalizationGain(
            level: LoudnessLevel.fromSetting(FinampSettingsHelper.finampSettings.normalizationLevel),
            measurement: measurement,
            headroomDb: HeadphoneEqService.headroomDb,
          )
        : null;
  }

  Future<Duration?> setQueueItems(
    List<FinampQueueItem> queueItems, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
    ShuffleOrder? shuffleOrder,
    bool rethrowErrors = false,
  }) async {
    final generation = ++_queueLoadGeneration;
    _queueRevision++;
    try {
      _queueShuffleOrder = shuffleOrder;
      final saved = _savedKaraoke;
      if (saved != null) {
        for (final entry in queueItems.where((entry) => entry.baseItem.id.raw == saved.song)) {
          final measurement = saved.measurement;
          entry.item = entry.item.copyWith(
            extras: {
              ...?entry.item.extras,
              'downloadedTrackPath': saved.file.path,
              'karaokeSaved': true,
              if (measurement != null)
                'karaokeLoudness': {'version': 1, 'lufs': measurement.lufs, 'truePeak': measurement.truePeak},
            },
          );
          _karaokeQueueId = entry.id;
          _karaokeMediaId = entry.item.id;
          _karaokeFile = saved.file;
          _karaokeMeasurement = measurement;
        }
      }
      if (!queueItems.any((item) => item.id == _karaokeQueueId)) {
        _karaokeQueueId = null;
        _karaokeMediaId = null;
        _karaokeFile = null;
        _karaokeMeasurement = null;
      }
      final initialTrack = queueItems.elementAtOrNull(initialIndex ?? 0)?.item;
      if (initialTrack != null) {
        await LoudnessCache.instance.load();
        final request = prepareNormalization([initialTrack]);
        if (LoudnessCache.instance.get(_loudnessNamespace, loudnessTrackId(initialTrack)) != null) {
          unawaited(request);
        } else {
          // An unreachable analyzer must not hold up music playback. A late
          // response can still update the current track through the cache stream.
          await request.timeout(const Duration(milliseconds: 750), onTimeout: () {});
        }
      }
      if (generation != _queueLoadGeneration) return null;
      final start = initialIndex ?? 0;
      unawaited(
        prepareNormalization(
          queueItems.skip(start).followedBy(queueItems.take(start)).take(2000).map((entry) => entry.item).toList(),
        ),
      );
      _normalizingTrack = queueItems.elementAtOrNull(initialIndex ?? 0)?.item;
      List<AudioSource> audioSources = [];

      for (final queueItem in queueItems) {
        audioSources.add(await _queueItemToAudioSource(queueItem));
      }
      if (generation != _queueLoadGeneration) return null;
      if (initialTrack != null && _player.platformId != null) {
        await configureNormalization(_player.platformId!, initialTrack);
      }
      if (generation != _queueLoadGeneration) return null;
      return await _player.setAudioSources(
        audioSources,
        preload: preload,
        initialIndex: initialIndex,
        initialPosition: initialPosition,
        shuffleOrder: shuffleOrder,
      );
    } on PlayerException catch (e) {
      if (rethrowErrors) rethrow;
      _audioServiceBackgroundTaskLogger.severe("Player error code ${e.code}: ${e.message}");
      GlobalSnackbar.error(e);
    } on PlayerInterruptedException catch (e) {
      if (rethrowErrors) rethrow;
      _audioServiceBackgroundTaskLogger.warning("Player interrupted: ${e.message}");
      GlobalSnackbar.error(e);
    } catch (e) {
      if (rethrowErrors) rethrow;
      _audioServiceBackgroundTaskLogger.severe("Player error ${e.toString()}");
      GlobalSnackbar.error(e);
    }
    return null;
  }

  Future<void> appendFinampQueueItem(FinampQueueItem queueItem) async {
    _queueRevision++;
    return _player.addAudioSource(await _queueItemToAudioSource(queueItem));
  }

  /// [isCurrent], checked once the songs are prepared: false leaves the queue as it is (it was replaced meanwhile).
  /// Whether the songs went in.
  Future<bool> appendFinampQueueItems(List<FinampQueueItem> queueItems, {bool Function()? isCurrent}) async {
    _queueRevision++;
    final sources = await Future.wait(queueItems.map(_queueItemToAudioSource));
    if (isCurrent?.call() == false) return false;
    await _player.addAudioSources(sources);
    return true;
  }

  Future<void> insertFinampQueueItemAt(int index, FinampQueueItem queueItem) async {
    _queueRevision++;
    return _player.insertAudioSource(index, await _queueItemToAudioSource(queueItem));
  }

  /// [isCurrent] as for [appendFinampQueueItems].
  Future<bool> insertFinampQueueItems(int index, List<FinampQueueItem> queueItems, {bool Function()? isCurrent}) async {
    _queueRevision++;
    final sources = await Future.wait(queueItems.map(_queueItemToAudioSource));
    if (isCurrent?.call() == false) return false;
    await _player.insertAudioSources(index, sources);
    return true;
  }

  Future<void> moveFinampQueueItem(int currentIndex, int newIndex) {
    _queueRevision++;
    return _player.moveAudioSource(currentIndex, newIndex);
  }

  Future<void> removeFinampQueueItemAt(int index) {
    _queueRevision++;
    return _player.removeAudioSourceAt(index);
  }

  Future<void> removeFinampQueueItemRange(int start, int end) {
    _queueRevision++;
    return _player.removeAudioSourceRange(start, end);
  }

  Future<void> clearFinampQueueItems() {
    _queueRevision++;
    return _player.clearAudioSources();
  }

  /// Fully dispose the player instance.  Should only be called during app shutdown.
  Future<void> dispose() => _player.dispose();

  @override
  Future<void> play({bool disableFade = false}) async {
    _audioServiceBackgroundTaskLogger.info(
      "play() start: disableFade=$disableFade, playing=${_player.playing}, fadeDirection=${fadeState.value.fadeDirection}, currentIndex=${_player.currentIndex}, position=${_player.position}",
    );
    final queueService = GetIt.instance<QueueService>();
    if (queueService.getCurrentTrack() == null) {
      _audioServiceBackgroundTaskLogger.info(
        "play() received with no current item, awaiting saved-queue restore before starting playback",
      );
      bool queueAvailable;
      try {
        queueAvailable = await queueService.ensureQueueLoaded();
      } catch (e) {
        _audioServiceBackgroundTaskLogger.warning("Saved-queue restore failed while handling remote play command: $e");
        queueAvailable = audioSources.isNotEmpty;
      }

      if (!queueAvailable) {
        _audioServiceBackgroundTaskLogger.info("No saved queue available to resume, ignoring play() command");
        return;
      }
    }
    if (_shouldIgnorePlayPauseAfterRecentSkip) {
      return;
    }
    playRequests.add(null);
    if (!disableFade && FinampSettingsHelper.finampSettings.audioFadeInDuration > Duration.zero) {
      return fadeInAndPlay();
    } else {
      await _volume.setFadeVolume(1.0);
      return _player.play();
    }
  }

  double get speed => _player.speed;

  @override
  Future<void> setSpeed(final double speed) async {
    return _player.setSpeed(speed);
  }

  Future<void> setPitch(final double pitch) async {
    return _player.setPitch(pitch);
  }

  void setVolume(final double volume) async {
    return _volume.setInternalVolume(volume);
  }

  /// Each pause or stop asked for, and by whom: the DJ, holding the music for the news, resumes only if none came since,
  /// and a reload that was playing plays on.
  final pauseRequests = StreamController<PauseBy>.broadcast(sync: true);

  /// Each play carried out (even one that only turns a fade-out back), so a reload follows the latest choice.
  final playRequests = StreamController<void>.broadcast(sync: true);

  /// Paused by the DJ to read the news: the music is still meant to be playing, so a reload plays on, and the system
  /// is told it is (standing still), so Android keeps the app running in the background and lets the music resume.
  bool get heldForNews => _heldForNews;

  /// Whether the player itself plays, which the playback state doesn't show while [heldForNews].
  Stream<bool> get playerPlaying => _player.playingStream;
  bool _heldForNews = false;
  set heldForNews(bool value) {
    if (_heldForNews == value) return;
    _heldForNews = value;
    unawaited(refreshPlaybackStateAndMediaNotification());
  }

  void _requestPause(PauseBy by) {
    // The listener's pause or stop ends the news hold at once: from then on the music is meant to stay paused.
    if (by == PauseBy.listener) heldForNews = false;
    pauseRequests.add(by);
  }

  @override
  Future<void> pause({bool disableFade = false, PauseBy by = PauseBy.listener, String? cause}) async {
    cause ??= pauseCause(StackTrace.current);
    // A headset's trailing pause just after a skip is ignored, so it isn't reported as one asked for.
    final ignored = _shouldIgnorePlayPauseAfterRecentSkip;
    if (!ignored) _requestPause(by);
    await CrossfadeService.interruptTempoMatching();
    _audioServiceBackgroundTaskLogger.info(
      "pause() start: by $cause, disableFade=$disableFade, playing=${_player.playing}, fadeDirection=${fadeState.value.fadeDirection}, currentIndex=${_player.currentIndex}, position=${_player.position}",
    );
    if (ignored) {
      return;
    }
    if (!disableFade && FinampSettingsHelper.finampSettings.audioFadeOutDuration > Duration.zero) {
      return fadeOutAndPause();
    } else {
      return _player.pause();
    }
  }

  int getFadeSteps(Duration fadeDuration) {
    return (fadeDuration.inMilliseconds / _audioFadeStepDuration.inMilliseconds).toInt();
  }

  double _getVolumeFadeInStepSize() {
    final steps = getFadeSteps(FinampSettingsHelper.finampSettings.audioFadeInDuration);
    return 1.0 / steps;
  }

  double _getVolumeFadeOutStepSize() {
    final steps = getFadeSteps(FinampSettingsHelper.finampSettings.audioFadeOutDuration);
    return 1.0 / steps;
  }

  Future<void> _fadeAudio(FadeDirection direction) async {
    fadeState.add(
      FadeState(
        fadeVolume: direction == FadeDirection.fadeIn ? 0.0 : 1.0,
        volumeFadeInStepSize: _getVolumeFadeInStepSize(),
        volumeFadeOutStepSize: _getVolumeFadeOutStepSize(),
        fadeDirection: direction,
      ),
    );

    // Prepare fade-in
    Future<void>? fut;
    if (direction == FadeDirection.fadeIn) {
      await _volume.setFadeVolume(0.0);
      fut = _player.play();
    }

    bool cancelled = false;
    await Stream.periodic(
      _audioFadeStepDuration,
      (_) => fadeState.value,
    ).takeWhile((fade) => fade.fadeDirection != FadeDirection.none && !cancelled).forEach((state) async {
      switch (state.fadeDirection) {
        case FadeDirection.fadeIn:
          var newVolume = state.fadeVolume + state.volumeFadeInStepSize;
          await _volume.setFadeVolume(newVolume);
          fadeState.add(state.copyWith(fadeVolume: newVolume));
          if (newVolume >= 1.0) {
            fadeState.add(state.copyWith(fadeDirection: FadeDirection.none));
            cancelled = true;
          }
          break;
        case FadeDirection.fadeOut:
          var newVolume = state.fadeVolume - state.volumeFadeOutStepSize;
          await _volume.setFadeVolume(newVolume);
          fadeState.add(state.copyWith(fadeVolume: newVolume));
          if (newVolume <= 0.0) {
            fadeState.add(state.copyWith(fadeDirection: FadeDirection.none));
            cancelled = true;

            fut = _player.pause();
          }
          break;
        default:
          break;
      }
    });

    return fut;
  }

  Future<void> fadeOutAndPause() async {
    await CrossfadeService.interruptTempoMatching();
    switch (fadeState.value.fadeDirection) {
      case FadeDirection.fadeOut:
        return;
      case FadeDirection.fadeIn:
        // change fade direction
        fadeState.add(fadeState.value.copyWith(fadeDirection: FadeDirection.fadeOut));
        return;
      case FadeDirection.none:
        return _fadeAudio(FadeDirection.fadeOut);
    }
  }

  Future<void> fadeInAndPlay() async {
    switch (fadeState.value.fadeDirection) {
      case FadeDirection.fadeIn:
        return;
      case FadeDirection.fadeOut:
        // change fade direction
        fadeState.add(fadeState.value.copyWith(fadeDirection: FadeDirection.fadeIn));
        return;
      case FadeDirection.none:
        return _fadeAudio(FadeDirection.fadeIn);
    }
  }

  Future<void> togglePlayback() {
    // Held for the news counts as playing, as everything shows it: the toggle pauses.
    if ((_player.playing || _heldForNews) && fadeState.value.fadeDirection != FadeDirection.fadeOut) {
      return pause();
    } else {
      return play();
    }
  }

  @override
  Future<void> stop() async {
    _requestPause(PauseBy.listener);
    try {
      _audioServiceBackgroundTaskLogger.info("Audio service received stop command");

      if (FinampSettingsHelper.finampSettings.clearQueueOnStopEvent) {
        await GetIt.instance<QueueService>().stopAndClearQueue();
      } else {
        // stop the player to release native assets but do not clear queue or reset playback state
        await stopPlayback();
      }
    } catch (e) {
      _audioServiceBackgroundTaskLogger.severe(e);
      return Future.error(e);
    }
  }

  Future<void> stopPlayback() async {
    _requestPause(PauseBy.listener);
    await CrossfadeService.interruptTempoMatching();
    try {
      if (sleepTimer != null) {
        _audioServiceBackgroundTaskLogger.info("Stopping playback with active sleep timer");
      }
      clearSleepTimer();

      await _player.stop();
    } catch (e) {
      _audioServiceBackgroundTaskLogger.severe(e);
      return Future.error(e);
    }
  }

  Future<void> handleEndOfQueue() async {
    try {
      _audioServiceBackgroundTaskLogger.info("Queue completed.");
      // A full stop will trigger a re-shuffle with an unshuffled first
      // item, so only pause.
      await pause(disableFade: true, cause: 'the end of the queue');
      if (FinampSettingsHelper.finampSettings.radioEnabled) {
        // Skipping to zero with empty queue re-triggers queue complete event
        // while radio is enable, we should never reach the end of the queue
        // if we end up reaching it, e.g. because the current radio mode becomes available (offline, etc.), we want to pause without resetting the queue, so that the user can fix the radio issue and resume, if desired.
        // Seek back a bit to avoid resetting the track to position zero when the queue is updated
        await seek(playbackPosition - Duration(milliseconds: 500), userInitiated: false);
      } else {
        if (_player.effectiveIndices.isNotEmpty) {
          await skipToIndex(0, userInitiated: false);
        }
      }
    } catch (e) {
      _audioServiceBackgroundTaskLogger.severe(e);
      return Future.error(e);
    }
  }

  int getPlayPositionInSeconds() {
    return _player.position.inSeconds;
  }

  PlaybackNavigationCommand? _beginNavigation(PlaybackNavigationKind kind, {bool userInitiated = true}) {
    if (!userInitiated) return null;
    final queue = GetIt.instance.isRegistered<QueueService>() ? GetIt.instance<QueueService>().getQueue() : null;
    final current = _player.sequenceState.currentSource?.tag;
    return PlaybackNavigation.shared.begin(
      kind,
      queueId: queue?.id,
      fromItemId: current is FinampQueueItem ? current.id : queue?.currentTrack?.id,
    );
  }

  void _completeNavigation(PlaybackNavigationCommand? command) {
    if (command == null) return;
    final item = _player.sequenceState.currentSource?.tag;
    command.complete(targetItemId: item is FinampQueueItem ? item.id : null);
  }

  @override
  Future<void> skipToPrevious({bool forceSkip = false}) async {
    await CrossfadeService.interruptTempoMatching();
    _audioServiceBackgroundTaskLogger.fine(
      "skipToPrevious() start: forceSkip=$forceSkip, playing=${_player.playing}, fadeDirection=${fadeState.value.fadeDirection}, hasPrevious=${_player.hasPrevious}, loopMode=${_player.loopMode}, currentIndex=${_player.currentIndex}, position=${_player.position}",
    );
    _lastSkipCommandAt = DateTime.now();
    bool doSkip = true;
    final navigation = _beginNavigation(PlaybackNavigationKind.previous);

    try {
      if (_queueCallbackPreviousTrack != null) {
        doSkip = await _queueCallbackPreviousTrack!();
      } else {
        doSkip = _player.position.inSeconds < 5;
      }

      // This can only be true if on first track while loop mode is off
      if (!_player.hasPrevious) {
        await _player.seek(Duration.zero);
      } else {
        if (doSkip || forceSkip) {
          if (_player.loopMode == LoopMode.one) {
            // if the user manually skips to the previous track, they probably want to actually skip to the previous track
            await skipByOffset(
              -1,
              userInitiated: false,
            ); //!!! don't use _player.previousIndex here, because that adjusts based on loop mode
          } else {
            await _player.seekToPrevious();
          }
        } else {
          await _player.seek(Duration.zero);
        }
      }
    } catch (e) {
      _audioServiceBackgroundTaskLogger.severe(e);
      return Future.error(e);
    } finally {
      _completeNavigation(navigation);
    }
  }

  int _unplayableInARow = 0;
  DateTime? _lastUnplayable;
  bool _skippingUnplayable = false;

  /// Finamp+: a track that can't be played (a broken or unreadable file) used to stop playback altogether. Go on with
  /// the next one instead, unless several fail in a row (then something bigger is wrong, like the connection).
  Future<void> _skipUnplayable(Object error) async {
    // The same failure can be reported both as a player error and as a stream error.
    if (_skippingUnplayable || _karaokeSwitching || error is PlayerInterruptedException) return;
    if (error is PlayerException && error.index != null && error.index != _player.currentIndex) return;
    _audioServiceBackgroundTaskLogger.warning("Couldn't play current track, skipping it: $error");
    final now = DateTime.now();
    final recent = _lastUnplayable != null && now.difference(_lastUnplayable!) < const Duration(seconds: 30);
    _unplayableInARow = recent ? _unplayableInARow + 1 : 1;
    _lastUnplayable = now;
    _skippingUnplayable = true;
    final generation = ++_queueLoadGeneration;
    final revision = ++_queueRevision;
    bool ownsQueue() => generation == _queueLoadGeneration && revision == _queueRevision;
    try {
      await recoverPlaybackAfterError(
        player: _player,
        ownsQueue: ownsQueue,
        duringReload: GetIt.instance<QueueService>().duringPlayerReload,
        shuffleOrder: _queueShuffleOrder,
        maxSkips: max(0, 4 - _unplayableInARow),
        onFailure: (error) {
          _unplayableInARow++;
          _audioServiceBackgroundTaskLogger.warning("Couldn't load the next track: $error");
        },
      );
    } catch (e) {
      _audioServiceBackgroundTaskLogger.warning("Couldn't go on after an unplayable track: $e");
      if (ownsQueue()) await _player.pause();
    } finally {
      _skippingUnplayable = false;
    }
  }

  @override
  Future<void> skipToNext() async {
    await CrossfadeService.interruptTempoMatching();
    _audioServiceBackgroundTaskLogger.fine(
      "skipToNext() start: playing=${_player.playing}, fadeDirection=${fadeState.value.fadeDirection}, hasNext=${_player.hasNext}, loopMode=${_player.loopMode}, currentIndex=${_player.currentIndex}, position=${_player.position}",
    );
    _lastSkipCommandAt = DateTime.now();
    final navigation = _beginNavigation(PlaybackNavigationKind.next);
    try {
      if (_player.loopMode == LoopMode.one || !_player.hasNext) {
        // if the user manually skips to the next track, they probably want to actually skip to the next track
        await skipByOffset(
          1,
          userInitiated: false,
        ); //!!! don't use _player.nextIndex here, because that adjusts based on loop mode
      } else {
        await _player.seekToNext();
      }
      _audioServiceBackgroundTaskLogger.finer("_player.nextIndex: ${_player.nextIndex}");
    } catch (e) {
      _audioServiceBackgroundTaskLogger.severe(e);
      return Future.error(e);
    } finally {
      _completeNavigation(navigation);
    }
  }

  Future<void> skipByOffset(int offset, {bool userInitiated = true}) async {
    await CrossfadeService.interruptTempoMatching();
    _audioServiceBackgroundTaskLogger.fine("skipping by offset: $offset");
    final navigation = _beginNavigation(
      offset > 0
          ? PlaybackNavigationKind.next
          : offset < 0
          ? PlaybackNavigationKind.previous
          : PlaybackNavigationKind.restart,
      userInitiated: userInitiated,
    );

    try {
      int queueIndex = _player.shuffleModeEnabled
          ? shuffleIndices.indexOf((_player.currentIndex ?? 0)) + offset
          : (_player.currentIndex ?? 0) + offset;
      if (queueIndex >= _player.effectiveIndices.length) {
        if (_player.loopMode == LoopMode.off) {
          //!!! seek to end of track to for the player to handle the end of queue
          // this is hacky, but seems to be the only way to get the proper events that the playback history service needs
          //TODO Finamp should probably use its own event system that is able to convey the necessary information
          return await _player.seek(_player.duration);
        }
        queueIndex %= (_player.effectiveIndices.length);
      }
      if (queueIndex < 0) {
        if (_player.loopMode == LoopMode.off) {
          queueIndex = 0;
        } else {
          queueIndex %= (_player.effectiveIndices.length);
        }
      }
      await _player.seek(Duration.zero, index: _player.shuffleModeEnabled ? shuffleIndices[queueIndex] : queueIndex);
    } catch (e) {
      _audioServiceBackgroundTaskLogger.severe(e);
      return Future.error(e);
    } finally {
      _completeNavigation(navigation);
    }
  }

  Future<void> skipToIndex(int index, {bool userInitiated = true}) async {
    await CrossfadeService.interruptTempoMatching();
    _audioServiceBackgroundTaskLogger.fine("skipping to index: $index");
    final navigation = _beginNavigation(PlaybackNavigationKind.select, userInitiated: userInitiated);

    try {
      await _player.seek(Duration.zero, index: _player.shuffleModeEnabled ? shuffleIndices[index] : index);
    } catch (e) {
      _audioServiceBackgroundTaskLogger.severe(e);
      return Future.error(e);
    } finally {
      _completeNavigation(navigation);
    }
  }

  @override
  Future<void> seek(Duration position, {bool userInitiated = true}) async {
    if (!CrossfadeService.isHandoverSeek) await CrossfadeService.interruptTempoMatching();
    final navigation = userInitiated
        ? _beginNavigation(
            position == Duration.zero
                ? PlaybackNavigationKind.restart
                : position < playbackPosition
                ? PlaybackNavigationKind.seekBackward
                : PlaybackNavigationKind.seekForward,
          )
        : null;
    try {
      await _player.seek(position);
    } catch (e) {
      _audioServiceBackgroundTaskLogger.severe(e);
      return Future.error(e);
    } finally {
      _completeNavigation(navigation);
    }
  }

  Future<void> shuffle() async {
    try {
      await _player.shuffle();
    } catch (e) {
      _audioServiceBackgroundTaskLogger.severe(e);
      return Future.error(e);
    }
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    try {
      switch (shuffleMode) {
        case AudioServiceShuffleMode.all:
          await _player.setShuffleModeEnabled(true);
          break;
        case AudioServiceShuffleMode.none:
          await _player.setShuffleModeEnabled(false);
          break;
        default:
          return await Future<void>.error(
            "Unsupported AudioServiceShuffleMode! Received ${shuffleMode.toString()}, requires all or none.",
          );
      }
      _audioServiceBackgroundTaskLogger.info("Set shuffle mode to $shuffleMode");
    } catch (e) {
      _audioServiceBackgroundTaskLogger.severe(e);
      rethrow;
    }
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    try {
      switch (repeatMode) {
        case AudioServiceRepeatMode.all:
          await _player.setLoopMode(LoopMode.all);
          break;
        case AudioServiceRepeatMode.none:
          await _player.setLoopMode(LoopMode.off);
          break;
        case AudioServiceRepeatMode.one:
          await _player.setLoopMode(LoopMode.one);
          break;
        default:
          return await Future<void>.error(
            "Unsupported AudioServiceRepeatMode! Received ${repeatMode.toString()}, requires all, none, or one.",
          );
      }
      _audioServiceBackgroundTaskLogger.info("Set repeat mode to $repeatMode");
    } catch (e) {
      _audioServiceBackgroundTaskLogger.severe(e);
      rethrow;
    }
  }

  /// Returns the top-level browsable categories for use in a media browser.
  List<MediaItem> _getRootMenu() {
    return [
      MediaItem(
        id: MediaItemId(contentType: ContentType.albums, parentType: MediaItemParentType.rootCollection).toString(),
        // ignore: deprecated_member_use_from_same_package
        title: _appLocalizations?.albums ?? ContentType.albums.toString(),
        playable: false,
      ),
      MediaItem(
        id: MediaItemId(
          contentType: ContentType.performingArtists,
          parentType: MediaItemParentType.rootCollection,
        ).toString(),
        // ignore: deprecated_member_use_from_same_package
        title: _appLocalizations?.artists ?? ContentType.performingArtists.toString(),
        playable: false,
      ),
      MediaItem(
        id: MediaItemId(contentType: ContentType.playlists, parentType: MediaItemParentType.rootCollection).toString(),
        // ignore: deprecated_member_use_from_same_package
        title: _appLocalizations?.playlists ?? ContentType.playlists.toString(),
        playable: false,
      ),
      MediaItem(
        id: MediaItemId(contentType: ContentType.genres, parentType: MediaItemParentType.rootCollection).toString(),
        // ignore: deprecated_member_use_from_same_package
        title: _appLocalizations?.genres ?? ContentType.genres.toString(),
        playable: false,
      ),
      MediaItem(
        id: MediaItemId(contentType: ContentType.tracks, parentType: MediaItemParentType.rootCollection).toString(),
        // ignore: deprecated_member_use_from_same_package
        title: _appLocalizations?.tracks ?? ContentType.tracks.toString(),
        playable: false,
      ),
    ];
  }

  /// Implements a media browser, like used in Android Auto.
  /// Called with the ID of a non-playable (and therefore browsable) [MediaItem], and returns a list of its children.
  /// We jerry-rig the [parentMediaId] to be a JSON string that can be parsed into a [MediaItemId] object, otherwise we don't have a way to tell which item the parentMediaId refers to.
  /// There are some special IDs that might be passed to this method:
  /// - [AudioService.browsableRootId] is passed when the client requests the root menu (the list of top-level categories)
  /// - [AudioService.recentRootId] is passed when the client requests the recent items (e.g. in the "For you" section of Android Auto).
  @override
  Future<List<MediaItem>> getChildren(String parentMediaId, [Map<String, dynamic>? options]) async {
    // display root category/parent
    if (parentMediaId == AudioService.browsableRootId) {
      _appLocalizations ??= await AppLocalizations.delegate.load(
        FinampSettingsHelper.finampSettings.locale ?? const Locale("en", "US"),
      );

      return _getRootMenu();
    } else if (parentMediaId == AudioService.recentRootId) {
      // return await _androidAutoHelper.getRecentItems();
      // return playlists for now
      return await _androidAutoHelper.getMediaItems(
        MediaItemId(contentType: ContentType.playlists, parentType: MediaItemParentType.rootCollection),
      );
    } else {
      try {
        final itemId = MediaItemId.fromJson(jsonDecode(parentMediaId) as Map<String, dynamic>);

        return await _androidAutoHelper.getMediaItems(itemId);
      } catch (e) {
        _audioServiceBackgroundTaskLogger.severe(e);
        return super.getChildren(parentMediaId);
      }
    }
  }

  /// Called when a media item is requested to be played.
  /// We jerry-rig the [mediaId] to be a JSON string that can be parsed into a [MediaItemId] object, otherwise we don't have a way to tell which item the mediaId refers to.
  @override
  Future<void> playFromMediaId(String mediaId, [Map<String, dynamic>? extras]) async {
    try {
      if (mediaId == QueueItemSourceNameType.shuffleAll.name) {
        return await _androidAutoHelper.shuffleAllTracks();
      }
      final mediaItemId = MediaItemId.fromJson(jsonDecode(mediaId) as Map<String, dynamic>);

      return await _androidAutoHelper.playFromMediaId(mediaItemId);
    } catch (e) {
      _audioServiceBackgroundTaskLogger.severe(e);
      return super.playFromMediaId(mediaId, extras);
    }
  }

  /// Called when a media browser performs a search, e.g. using a search bar or to correct a voice search.
  /// Currently, the [extras] parameter isn't passed correctly by AudioService, so some of the metadata available during a voice search isn't available here, that's why we store the [lastSearchQuery] to use it here.
  @override
  Future<List<MediaItem>> search(String query, [Map<String, dynamic>? extras]) async {
    _audioServiceBackgroundTaskLogger.info("search: $query ; extras: $extras");

    final previousItemTitle = _androidAutoHelper.lastSearchQuery?.extras?["android.intent.extra.title"] as String?;

    final currentSearchQuery = AndroidAutoSearchQuery(query, extras);

    if (previousItemTitle != null) {
      // when voice searching for a track with title + artist, Android Auto / Google Assistant combines the title and artist into a single query, with no way to differentiate them
      // so we try to instead use the title provided in the extras right after the voice search, and just search for that
      if (query.contains(previousItemTitle)) {
        // if the the title is fully contained in the query, we can assume that the user clicked on the "Search Results" button on the player screen
        currentSearchQuery.rawQuery = previousItemTitle;
        currentSearchQuery.extras = _androidAutoHelper.lastSearchQuery?.extras;
      } else {
        // otherwise, we assume they're searching for something else, and discard the previous search query
        _androidAutoHelper.setLastSearchQuery(null);
      }
    }

    final results = await _androidAutoHelper.searchItems(currentSearchQuery);
    return results;
  }

  /// Called when the user asks for an item to be played based on a query.
  /// In this case, the search needs to be performed and the "best" result should be played immediately.
  /// [extras] can contain additional information about the search, like the original query, a title, artist, or album (all optional and filled in by e.g. the Voice Assistant for popular items. Provided fields can indicate which type of item was requested).
  @override
  Future<void> playFromSearch(String query, [Map<String, dynamic>? extras]) async {
    _audioServiceBackgroundTaskLogger.info("playFromSearch: $query ; extras: $extras");
    final searchQuery = AndroidAutoSearchQuery(query, extras);
    _androidAutoHelper.setLastSearchQuery(searchQuery);
    await _androidAutoHelper.playFromSearch(searchQuery);
  }

  @override
  Future<dynamic> customAction(String name, [Map<String, dynamic>? extras]) async {
    late final CustomPlaybackActions action;
    try {
      action = CustomPlaybackActions.values.firstWhere((element) => element.name == name);
    } catch (e) {
      _audioServiceBackgroundTaskLogger.severe("Custom action '$name' not found.", e);
      return super.customAction(name, extras);
    }

    switch (action) {
      case CustomPlaybackActions.shuffle:
        final queueService = GetIt.instance<QueueService>();
        return queueService.togglePlaybackOrder();
      case CustomPlaybackActions.radio:
        return radio_service_helper.toggleRadio();
      case CustomPlaybackActions.toggleFavorite:
        return toggleFavoriteStatusOfCurrentTrack();
      case CustomPlaybackActions.dbusVolume:
        final volume = extras?["value"] as double?;
        if (volume != null) {
          _audioServiceBackgroundTaskLogger.info("Setting volume to $volume from dbus.");
          await _volume.setInternalVolume(volume);
        }
        return;
    }
  }

  Future<void> toggleFavoriteStatusOfCurrentTrack() async {
    final ref = GetIt.instance<ProviderContainer>();
    jellyfin_models.BaseItemDto? currentItem;

    if (mediaItem.valueOrNull?.extras?["itemJson"] != null) {
      currentItem = jellyfin_models.BaseItemDto.fromJson(
        mediaItem.valueOrNull?.extras!["itemJson"] as Map<String, dynamic>,
      );
    } else {
      return;
    }

    bool isFavorite = currentItem.userData?.isFavorite ?? false;
    // get current favorite status from the provider
    isFavorite = ref.read(isFavoriteProvider(currentItem));
    // update favorite status with the value returned by the provider
    isFavorite = ref.read(isFavoriteProvider(currentItem).notifier).updateFavorite(!isFavorite);
    return refreshPlaybackStateAndMediaNotification();
  }

  Future<void> refreshPlaybackStateAndMediaNotification() async {
    // re-trigger the playbackState update to update the notification
    final event = _transformEvent(_player.playbackEvent);
    return playbackState.add(event);
  }

  // triggers when skipping to specific item in android auto queue
  @override
  Future<void> skipToQueueItem(int index) async {
    return skipToIndex(index);
  }

  MediaItem? _normalizingTrack;
  final _normalizingPlayers = <String, MediaItem>{};
  static const _normalizationChannel = MethodChannel('com.ryanheise.just_audio.methods');
  (bool, int, VolumeNormalizationMode) get _normalizationSettings {
    final settings = FinampSettingsHelper.finampSettings;
    return (settings.volumeNormalizationActive, settings.normalizationLevel, settings.volumeNormalizationMode);
  }

  String get _loudnessNamespace => GetIt.instance<FinampUserHelper>().currentUser?.serverId ?? '';

  Future<void> prepareNormalization(List<MediaItem> tracks) => LoudnessCache.instance.fetchAhead(
    _loudnessNamespace,
    tracks.map(loudnessTrackId).toList(),
    offline: FinampSettingsHelper.finampSettings.isOffline,
  );

  NormalizationSnapshot _normalizationFor(MediaItem track) {
    final settings = FinampSettingsHelper.finampSettings;
    final album = _usesAlbumNormalization(track);
    final karaokeGain = _karaokeGain(track);
    return NormalizationSession.playback.resolve(
      server: _loudnessNamespace,
      playbackId: track.id,
      context: (
        _normalizationSettings,
        album,
        HeadphoneEqService.headroomDb,
        _karaokeFile?.path,
        track.extras?['karaokeLoudness'],
      ),
      create: () {
        final measurement = LoudnessCache.instance.get(
          _loudnessNamespace,
          loudnessTrackId(track),
          downloaded: track.extras?['downloadedTrackPath'] != null,
        );
        final enabled = _normalizationEnabledFor(track, album: album);
        final snapshot = karaokeGain != null
            ? NormalizationSnapshot(
                source: enabled ? NormalizationSource.track : NormalizationSource.off,
                gainDb: enabled ? karaokeGain : 0,
                headroomDb: HeadphoneEqService.headroomDb,
              )
            : NormalizationSnapshot.calculate(
                enabled: enabled,
                album: album,
                level: LoudnessLevel.fromSetting(settings.normalizationLevel),
                headroomDb: HeadphoneEqService.headroomDb,
                measurement: measurement,
                legacyGain:
                    measurement == null ||
                        (album && (measurement.albumLufs == null || measurement.albumTruePeak == null))
                    ? _legacyGainForCurrentPlayback(track, null, album: album)
                    : null,
                attenuationOnly: !Platform.isAndroid,
              );
        _volumeNormalizationLogger.info(
          'Playback normalization: ${snapshot.source.name}, gain ${snapshot.gainDb.toStringAsFixed(2)} dB, '
          'EQ reserve ${snapshot.headroomDb.toStringAsFixed(2)} dB; fixed for this playback',
        );
        return snapshot;
      },
    );
  }

  /// Each Android player gets its own gain before the crossfade mixer.
  Future<void> configureNormalization(String id, MediaItem track) async {
    if (!Platform.isAndroid) return;
    _normalizingPlayers[id] = track;
    try {
      final snapshot = _normalizationFor(track);
      await _normalizationChannel.invokeMethod<void>('setNormalization', {
        'id': id,
        'enabled': snapshot.enabled,
        'gainDb': snapshot.gainDb,
        'headroomDb': snapshot.headroomDb,
      });
    } catch (error) {
      _volumeNormalizationLogger.warning('Could not configure PCM normalization', error);
    }
  }

  void forgetNormalization(String? id) {
    _normalizingPlayers.remove(id);
    _retainNormalization();
  }

  void _retainNormalization() => NormalizationSession.playback.retain(_loudnessNamespace, {
    if (_normalizingTrack != null) _normalizingTrack!.id,
    ..._normalizingPlayers.values.map((track) => track.id),
  });

  Future<void> _refreshNormalization() async {
    for (final entry in _normalizingPlayers.entries.toList()) {
      await configureNormalization(entry.key, entry.value);
    }
    _applyVolumeNormalization(_normalizingTrack);
  }

  void _applyVolumeNormalization(MediaItem? currentTrack) {
    _normalizingTrack = currentTrack;
    if (currentTrack == null) {
      _retainNormalization();
      unawaited(_volume.setReplayGainVolume(1));
      return;
    }
    if (Platform.isAndroid) {
      unawaited(_volume.setReplayGainVolume(1));
      final id = _player.platformId;
      if (id != null) unawaited(configureNormalization(id, currentTrack));
    } else {
      unawaited(_volume.setReplayGainVolume(normalizationFactorFor(currentTrack)));
    }
    _retainNormalization();
    unawaited(prepareNormalization([currentTrack]));
    if (GetIt.instance.isRegistered<QueueService>()) {
      final queue = GetIt.instance<QueueService>().getQueue();
      unawaited(prepareNormalization(queue.nextUp.followedBy(queue.queue).take(6).map((e) => e.item).toList()));
    }
  }

  /// Handles a sleep timer triggering, pausing play and clearing the timer
  void completeSleepTimer() async {
    _audioServiceBackgroundTaskLogger.info("Sleep timer completed, pausing playback");
    _stopSleepFade(resetVolume: false);
    _timer.value?.cancel();
    _timer.value = null;
    await pause(cause: 'the sleep timer');
    // The sleep fade has brought the volume down to zero, restore it for the next time playback starts.
    await _volume.setSleepFadeVolume(1.0);
    // stop playback reporting, since the playback is not expected to resume in the near future
    await GetIt.instance<PlaybackHistoryService>().reportPlaybackStopped();
  }

  /// How long before a duration based sleep timer ends playback starts fading out.
  static const _sleepFadeDuration = Duration(seconds: 30);
  Timer? _sleepFadeTimer;

  /// Gradually lowers the volume during the last [_sleepFadeDuration] of a duration based sleep timer.
  void _startSleepFade(SleepTimer timer) {
    _stopSleepFade();
    // Track count timers end at a track boundary, so there is nothing to fade towards.
    if (timer.secondsLength <= 0 || timer.tracksLength > 0) return;
    _sleepFadeTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      // The timer was replaced or cancelled elsewhere, don't leave the volume lowered.
      if (sleepTimer != timer) {
        _stopSleepFade();
        return;
      }
      final remaining = timer.remainingDuration;
      final factor = (remaining.inMilliseconds / _sleepFadeDuration.inMilliseconds).clamp(0.0, 1.0);
      _volume.setSleepFadeVolume(factor);
    });
  }

  void _stopSleepFade({bool resetVolume = true}) {
    _sleepFadeTimer?.cancel();
    _sleepFadeTimer = null;
    if (resetVolume) {
      _volume.setSleepFadeVolume(1.0);
    }
  }

  /// Starts the new sleep timer
  void startSleepTimer(SleepTimer newSleepTimer) {
    if (sleepTimer != null) {
      _audioServiceBackgroundTaskLogger.info(
        "Sleep timer restarted before previous one finished (${sleepTimer!.remainingDuration} left, "
        "${sleepTimer!.remainingTracks} tracks remaining)",
      );
      clearSleepTimer();
    }
    _audioServiceBackgroundTaskLogger.info(
      "Starting sleep timer: ${newSleepTimer.secondsLength}s, ${newSleepTimer.tracksLength} tracks",
    );
    _timer.value = newSleepTimer;
    sleepTimer?.start(completeSleepTimer);
    _startSleepFade(newSleepTimer);
  }

  /// Cancels the sleep timer and clears it.
  void clearSleepTimer() {
    _audioServiceBackgroundTaskLogger.info("Clearing sleep timer");
    _stopSleepFade();
    _timer.value?.cancel();
    _timer.value = null;
  }

  // Duration get sleepTimerRemaining {
  //   return sleepTimer.getRemaining();
  // }

  late final _currentFavorite = CurrentFavorite(
    GetIt.instance<ProviderContainer>(),
    () => unawaited(refreshPlaybackStateAndMediaNotification()),
  );

  /// Transform a just_audio event into an audio_service state.
  ///
  /// This method is used from the constructor. Every event received from the
  /// just_audio player will be transformed into an audio_service state so that
  /// it can be broadcast to audio_service clients.
  PlaybackState _transformEvent(PlaybackEvent event) {
    final itemJson = mediaItem.valueOrNull?.extras?["itemJson"] as Map<String, dynamic>?;
    final isFavorite = itemJson != null && _currentFavorite.read(itemJson);

    final radioEnabled = FinampSettingsHelper.finampSettings.radioEnabled;
    // AudioService.init can deliver native events before QueueService exists.
    // Reading its providers then would cache a failed lookup beyond startup.
    final radioActive =
        radioEnabled &&
        GetIt.instance.isRegistered<QueueService>() &&
        GetIt.instance<ProviderContainer>()
            .read(radio_service_helper.currentRadioAvailabilityStatusProvider)
            .isAvailable;

    return PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        if (_player.playing || _heldForNews) MediaControl.pause else MediaControl.play,
        MediaControl.skipToNext,
        if (FinampSettingsHelper.finampSettings.showFavoriteButtonOnMediaNotification &&
            !FinampSettingsHelper.finampSettings.isOffline)
          MediaControl.custom(
            name: CustomPlaybackActions.toggleFavorite.name,
            androidIcon: isFavorite ? "drawable/baseline_heart_filled_24" : "drawable/baseline_heart_24",
            label: isFavorite ? GlobalSnackbar.requireL10n.removeFavorite : GlobalSnackbar.requireL10n.addFavorite,
          ),
        if (FinampSettingsHelper.finampSettings.showShuffleButtonOnMediaNotification)
          //TODO eventually we probably want separate settings for this, and not store them as individual booleans in Hive
          radioEnabled
              ? MediaControl.custom(
                  name: CustomPlaybackActions.radio.name,
                  androidIcon: radioActive ? "drawable/tabler_icons_radio_24" : "drawable/tabler_icons_radio_off_24",
                  label: radioActive
                      ? GlobalSnackbar.requireL10n.radioModeActiveTitle
                      : GlobalSnackbar.requireL10n.radioModeInactiveTitle,
                )
              : MediaControl.custom(
                  name: CustomPlaybackActions.shuffle.name,
                  androidIcon: _player.shuffleModeEnabled
                      ? "drawable/baseline_shuffle_on_24"
                      : "drawable/baseline_shuffle_24",
                  label: _player.shuffleModeEnabled
                      ? GlobalSnackbar.requireL10n.playbackOrderShuffledButtonLabel
                      : GlobalSnackbar.requireL10n.playbackOrderLinearButtonLabel,
                ),
        if (FinampSettingsHelper.finampSettings.showStopButtonOnMediaNotification)
          MediaControl.stop.copyWith(androidIcon: "drawable/baseline_stop_24"),
      ],
      systemActions: FinampSettingsHelper.finampSettings.showSeekControlsOnMediaNotification
          ? const {MediaAction.seek, MediaAction.seekForward, MediaAction.seekBackward}
          : {},
      androidCompactActionIndices: const [0, 1, 2],
      processingState: const {
        ProcessingState.idle: AudioProcessingState.idle,
        ProcessingState.loading: AudioProcessingState.loading,
        ProcessingState.buffering: AudioProcessingState.buffering,
        ProcessingState.ready: AudioProcessingState.ready,
        ProcessingState.completed: AudioProcessingState.completed,
      }[_player.processingState]!,
      playing: _player.playing || _heldForNews,
      //!!! use the current player position, since there might be a delay before this event is processed.
      // Do **not** use [event.updatePosition] or [event.bufferedPosition], since that could lead to a discontinuity in the playback position (resetting to 0) and cause incorrect history entries
      updatePosition: _player.position,
      bufferedPosition: _player.bufferedPosition,
      // Held for the news, the song stands still.
      speed: _heldForNews && !_player.playing ? 0.0 : _player.speed,
      queueIndex: _player.shuffleModeEnabled && shuffleIndices.isNotEmpty && event.currentIndex != null
          ? shuffleIndices.indexOf(event.currentIndex!)
          : event.currentIndex,
      shuffleMode: _player.shuffleModeEnabled ? AudioServiceShuffleMode.all : AudioServiceShuffleMode.none,
      repeatMode: _audioServiceRepeatMode(_player.loopMode),
    );
  }

  int? get queueIndex => _player.shuffleModeEnabled && shuffleIndices.isNotEmpty && _player.currentIndex != null
      ? shuffleIndices.indexOf(_player.currentIndex!)
      : _player.currentIndex;
  SequenceState get sequenceState => _player.sequenceState;
  double get volume => (_volume._internalVolume * 100).roundToDouble() / 100;
  bool get paused => !_player.playing;
  Duration get playbackPosition => _player.position;

  /// Sets the DJ transition volume factor (see [DjTransitionService]).
  Future<void> setTransitionVolume(double volume) => _volume.setTransitionVolume(volume);
  Future<void> setAlarmVolume(double volume) => _volume.setAlarmVolume(volume);
  Future<void> setVoiceVolume(double volume) async {
    var changed = false;
    if (_volume.nativeVoiceDucking && playerPlatformId != null) {
      final lead = await const MethodChannel(
        'com.ryanheise.just_audio.methods',
      ).invokeMethod<int>('setVoiceEnvelope', {'id': playerPlatformId, 'gain': volume, 'durationMs': 0});
      if (lead == null) {
        _volume.nativeVoiceDucking = false;
        changed = true;
      }
    }
    await _volume.setVoiceVolume(volume, force: changed);
  }

  /// Schedule one sample-continuous envelope, returning the already-queued output lead.
  Future<Duration?> rampVoiceVolume(double volume, Duration duration) async {
    if (!Platform.isAndroid || playerPlatformId == null) return null;
    final lead = await const MethodChannel('com.ryanheise.just_audio.methods').invokeMethod<int>('setVoiceEnvelope', {
      'id': playerPlatformId,
      'gain': volume,
      'durationMs': duration.inMilliseconds,
    });
    if (lead == null) {
      _volume.nativeVoiceDucking = false;
      await _volume.setVoiceVolume(_volume._voiceVolume, force: true);
      return null;
    }
    _volume.nativeVoiceDucking = true;
    await _volume.setVoiceVolume(volume, force: true);
    return Duration(milliseconds: lead);
  }

  /// How long until a voice envelope set now is heard, as the music is processed ahead of the speaker; null when
  /// native ducking isn't available.
  Future<Duration?> voiceOutputLead() async {
    if (!Platform.isAndroid || playerPlatformId == null) return null;
    final lead = await const MethodChannel(
      'com.ryanheise.just_audio.methods',
    ).invokeMethod<int>('outputLead', {'id': playerPlatformId});
    return lead == null ? null : Duration(milliseconds: lead);
  }

  /// The native id of the main player, for reading its exact position (crossfades).
  String? get playerPlatformId => _player.platformId;

  /// Finamp+: how long the current song really is, as the player found out from the file itself. The server's figure
  /// can be off by quite a bit (a re-encoded file, wrong tags), which matters for timing a crossfade.
  Duration? get playerDuration => _player.duration;

  /// Volume for a second player playing alongside this one (crossfades).
  double get crossfadeBaseVolume => _volume.baseVolume;

  /// The volume the DJ's voice follows; unlike [crossfadeBaseVolume], not lowered by the dip for the voice itself.
  double get djVoiceBaseVolume => _volume.voiceBaseVolume;

  /// The audio source the player would use for [queueItem]. [playSessionId] replaces the item's own transcode session,
  /// so a second player streaming the same song gets its own server transcode instead of fighting over one.
  Future<AudioSource> audioSourceFor(FinampQueueItem queueItem, {String? playSessionId}) =>
      _queueItemToAudioSource(queueItem, playSessionId: playSessionId);

  /// Android gains are applied to each PCM stream, including the second player.
  /// Other platforms retain attenuation-only playback until they have a DSP limiter.
  double normalizationFactorFor(MediaItem track) {
    if (Platform.isAndroid || !FinampSettingsHelper.finampSettings.volumeNormalizationActive) return 1;
    final gain = _normalizationFor(track).gainDb;
    final linear = pow(10.0, min(0, gain) / 20).toDouble();
    return Platform.isLinux || Platform.isWindows ? pow(linear, 1 / 3).toDouble() : linear;
  }

  void onQueueServiceAvailable() {
    // Replace the neutral startup controls now that queue providers are safe.
    playbackState.add(_transformEvent(_player.playbackEvent));
    // Moved here because currentTrackMetadataProvider depends on queueService
    // If metadataProvider is sloooooow, this allows it to catch up
    GetIt.instance<ProviderContainer>().listen(currentTrackMetadataProvider, (previous, next) {
      // update media notification to reflect favorite state
      refreshPlaybackStateAndMediaNotification();

      if (FinampSettingsHelper.finampSettings.volumeNormalizationMode != VolumeNormalizationMode.albumBased &&
          FinampSettingsHelper.finampSettings.volumeNormalizationMode != VolumeNormalizationMode.hybrid) {
        return;
      }
      if (previous?.valueOrNull?.albumNormalizationGain != next.valueOrNull?.albumNormalizationGain) {
        _applyVolumeNormalization(mediaItem.valueOrNull);
      }
    });
  }

  /// Syncs the list of MediaItems (_queue) with the internal queue of the player.
  /// Called by onAddQueueItem and onUpdateQueue.
  Future<AudioSource> _queueItemToAudioSource(FinampQueueItem queueItem, {String? playSessionId}) async {
    if (queueItem.id == _karaokeQueueId && _karaokeFile != null) {
      return AudioSource.uri(Uri.file(_karaokeFile!.path), tag: queueItem);
    }
    if (queueItem.item.extras?['downloadedTrackPath'] == null && queueItem.item.extras?['isOffline'] == true) {
      final reserved = await RollingReserveService.offlineSource(queueItem.baseItemId.raw, queueItem.id);
      if (reserved != null) return AudioSource.uri(reserved, tag: queueItem);
    }
    if (queueItem.item.extras!["downloadedTrackPath"] == null) {
      // If downloadedTrack wasn't passed, we assume that the item is not
      // downloaded.

      // If offline, we throw an error so that we don't accidentally stream from
      // the internet. See the big comment in _trackUri() to see why this was
      // passed in extras.
      if (queueItem.item.extras!["isOffline"] as bool) {
        return Future.error("Offline mode enabled but downloaded track not found.");
      } else {
        final trackUri = await _trackUri(queueItem.item, playSessionId: playSessionId);
        final uri = await RollingReserveService.source(queueItem.baseItemId.raw, queueItem.id, trackUri);
        return AudioSource.uri(uri, tag: queueItem);
        // if (queueItem.item.extras!["shouldTranscode"] == true) {
        //   return HlsAudioSource(trackUri, tag: queueItem);
        // } else {
        //   return AudioSource.uri(trackUri, tag: queueItem);
        // }
      }
    } else {
      // We have to deserialise this because Dart is stupid and can't handle
      // sending classes through isolates.
      final downloadedTrackPath = queueItem.item.extras!["downloadedTrackPath"] as String;

      // Path verification and stuff is done in AudioServiceHelper, so this path
      // should be valid.
      final downloadUri = Uri.file(downloadedTrackPath);
      return AudioSource.uri(downloadUri, tag: queueItem);
    }
  }

  Future<Uri> _trackUri(MediaItem mediaItem, {String? playSessionId}) async {
    final finampUserHelper = GetIt.instance<FinampUserHelper>();
    // When creating the MediaItem (usually in AudioServiceHelper), we specify
    // whether or not to transcode. We used to pull from FinampSettings here,
    // but since audio_service runs in an isolate (or at least, it does until
    // 0.18), the value would be wrong if changed while a track was playing since
    // Hive is bad at multi-isolate stuff.

    final parsedBaseUrl = Uri.parse(finampUserHelper.currentUser!.baseURL);

    List<String> builtPath = List.from(parsedBaseUrl.pathSegments);

    Map<String, String> queryParameters = Map.from(parsedBaseUrl.queryParameters);

    // We include the user token as a query parameter because just_audio used to
    // have issues with headers in HLS, and this solution still works fine
    queryParameters["ApiKey"] = finampUserHelper.currentUser!.accessToken;
    // // indicate which play session this stream belongs to, this will be referenced when reporting playback progress
    // queryParameters["PlaySessionId"] = _order.id; //!!! this currently breaks transcoding for some reason

    if (mediaItem.extras!["shouldTranscode"] as bool) {
      builtPath.addAll(["Audio", mediaItem.extras!["itemJson"]["Id"] as String, "main.m3u8"]);

      queryParameters.addAll({
        "audioCodec": FinampSettingsHelper.finampSettings.transcodingStreamingFormat.codec,
        "playSessionId": playSessionId ?? mediaItem.extras!["playSessionId"] as String? ?? "",
        // Ideally we'd switch between 44.1/48kHz depending on the source is,
        // realistically it doesn't matter too much
        // default to 44100, only use 48000 for opus because opus doesn't support 44100
        "audioSampleRate": FinampSettingsHelper.finampSettings.transcodingStreamingFormat.sampleRate.toString(),
        "segmentContainer": FinampSettingsHelper.finampSettings.transcodingStreamingFormat.container,
      });

      if (!FinampSettingsHelper.finampSettings.transcodingStreamingFormat.lossless) {
        queryParameters.addAll({"audioBitRate": FinampSettingsHelper.finampSettings.transcodeBitrate.toString()});
      }

      if (FinampSettingsHelper.finampSettings.multichannelHandlingSetting ==
              MultichannelHandlingSetting.stereoDownmixAll ||
          (FinampSettingsHelper.finampSettings.multichannelHandlingSetting ==
                  MultichannelHandlingSetting.stereoDownmixLossy &&
              FinampSettingsHelper.finampSettings.transcodingStreamingFormat.codec != "flac")) {
        queryParameters.addAll({"maxAudioChannels": "2"});
      }
    } else {
      builtPath.addAll(["Items", mediaItem.extras!["itemJson"]["Id"] as String, "File"]);
    }

    return Uri(
      host: parsedBaseUrl.host,
      port: parsedBaseUrl.port,
      scheme: parsedBaseUrl.scheme,
      userInfo: parsedBaseUrl.userInfo,
      pathSegments: builtPath,
      queryParameters: queryParameters,
    );
  }

  Future<Uri> streamUriFor(FinampQueueItem item, {String? playSessionId}) =>
      _trackUri(item.item, playSessionId: playSessionId);

  @override
  @Deprecated("Don't use this method, we're using methods based on FinampQueueItem")
  Future<void> addQueueItem(MediaItem mediaItem) async {}
  @override
  @Deprecated("Don't use this method, we're using methods based on FinampQueueItem")
  Future<void> addQueueItems(List<MediaItem> mediaItems) async {}
  @override
  @Deprecated("Don't use this method, we're using methods based on FinampQueueItem")
  Future<void> insertQueueItem(int index, MediaItem mediaItem) async {}
  @override
  @Deprecated("Don't use this method, we're using methods based on FinampQueueItem")
  Future<void> updateQueue(List<MediaItem> queue) async {}
  @override
  @Deprecated("Don't use this method, we're using methods based on FinampQueueItem")
  Future<void> updateMediaItem(MediaItem mediaItem) async {}
  @override
  @Deprecated(
    "Don't use this method, we're using methods based on FinampQueueItem. This implementation is just for best-effort platform compatibility.",
  )
  Future<void> removeQueueItem(MediaItem mediaItem) async {
    final index = queue.valueOrNull?.indexOf(mediaItem);
    if (index != null) {
      return removeFinampQueueItemAt(index);
    }
  }

  @override
  @Deprecated(
    "Don't use this method, we're using methods based on FinampQueueItem. This implementation is just for best-effort platform compatibility.",
  )
  Future<void> removeQueueItemAt(int index) async {
    return removeFinampQueueItemAt(index);
  }

  @override
  @Deprecated(
    "Don't use this method, we're using methods based on FinampQueueItem. This implementation is just for best-effort platform compatibility.",
  )
  Future<void> setRating(Rating rating, [Map<String, dynamic>? extras]) async {
    jellyfin_models.BaseItemDto? currentItem;

    if (mediaItem.valueOrNull?.extras?["itemJson"] != null) {
      currentItem = jellyfin_models.BaseItemDto.fromJson(
        mediaItem.valueOrNull?.extras!["itemJson"] as Map<String, dynamic>,
      );
    } else {
      return;
    }
    bool isFavorite = currentItem.userData?.isFavorite ?? false;
    switch (rating.getRatingStyle()) {
      case RatingStyle.heart:
        if (rating.hasHeart() && !isFavorite) {
          // add favorite
          await toggleFavoriteStatusOfCurrentTrack();
        } else if (!rating.hasHeart() && isFavorite) {
          // remove favorite
          await toggleFavoriteStatusOfCurrentTrack();
        }
        break;
      case RatingStyle.thumbUpDown:
        if (rating.isThumbUp() && !isFavorite) {
          // add favorite
          await toggleFavoriteStatusOfCurrentTrack();
        } else if (!rating.isThumbUp() && isFavorite) {
          // remove favorite
          await toggleFavoriteStatusOfCurrentTrack();
        }
        break;
      case RatingStyle.percentage:
        final percentage = rating.getPercentRating();
        if (percentage > 0.5 && !isFavorite) {
          // add favorite
          await toggleFavoriteStatusOfCurrentTrack();
        } else if (percentage < 0.5 && isFavorite) {
          // remove favorite
          await toggleFavoriteStatusOfCurrentTrack();
        }
        break;
      case RatingStyle.range3stars:
        final stars = rating.getStarRating();
        if (stars >= 1.5 && !isFavorite) {
          // add favorite
          await toggleFavoriteStatusOfCurrentTrack();
        } else if (stars <= 0.5 && isFavorite) {
          // remove favorite
          await toggleFavoriteStatusOfCurrentTrack();
        }
        break;
      case RatingStyle.range4stars:
        final stars = rating.getStarRating();
        if (stars >= 2.0 && !isFavorite) {
          // add favorite
          await toggleFavoriteStatusOfCurrentTrack();
        } else if (stars <= 1.0 && isFavorite) {
          // remove favorite
          await toggleFavoriteStatusOfCurrentTrack();
        }
        break;
      case RatingStyle.range5stars:
        final stars = rating.getStarRating();
        if (stars >= 3 && !isFavorite) {
          // add favorite
          await toggleFavoriteStatusOfCurrentTrack();
        } else if (stars <= 2.0 && isFavorite) {
          // remove favorite
          await toggleFavoriteStatusOfCurrentTrack();
        }
        break;
      default:
      // do nothing
    }
  }

  @override
  @Deprecated("Don't use this method yet, it has no implementation")
  Future<void> setCaptioningEnabled(bool enabled) async {}
}

bool _usesAlbumNormalization(MediaItem track) {
  final mode = FinampSettingsHelper.finampSettings.volumeNormalizationMode;
  if (mode == VolumeNormalizationMode.albumBased) return true;
  if (mode == VolumeNormalizationMode.trackBased) return false;
  final queue = GetIt.instance<QueueService>();
  if (queue.playbackOrder != FinampPlaybackOrder.linear) return false;
  // Searched in place: fullQueue copies the whole queue, up to 5,000 songs, on every gain worked out.
  final info = queue.getQueue();
  final source = [
    info.previousTracks,
    [?info.currentTrack],
    info.nextUp,
    info.queue,
  ].expand((part) => part).where((item) => item.item.id == track.id).firstOrNull?.source;
  return source?.type == QueueItemSourceType.album || source?.type == QueueItemSourceType.nextUpAlbum;
}

/// AudioService uses a queue UUID or a browsing id; the analyzer uses Jellyfin's id.
String loudnessTrackId(MediaItem track) =>
    jellyfin_models.BaseItemDto.fromJson(track.extras!['itemJson'] as Map<String, dynamic>).id.raw;

double? getGainForCurrentPlayback(MediaItem track, jellyfin_models.BaseItemDto? item) {
  final settings = FinampSettingsHelper.finampSettings;
  final album = _usesAlbumNormalization(track);
  if (!_normalizationEnabledFor(track, album: album)) return 0;
  final server = GetIt.instance<FinampUserHelper>().currentUser?.serverId ?? '';
  final frozen = NormalizationSession.playback.get(server, track.id);
  if (frozen != null) return frozen.gainDb;
  final measurement = LoudnessCache.instance.get(
    server,
    loudnessTrackId(track),
    downloaded: track.extras?['downloadedTrackPath'] != null,
  );
  final needsLegacy =
      measurement == null || (album && (measurement.albumLufs == null || measurement.albumTruePeak == null));
  return normalizationGain(
    level: LoudnessLevel.fromSetting(settings.normalizationLevel),
    measurement: measurement,
    album: album,
    legacyGain: needsLegacy ? _legacyGainForCurrentPlayback(track, item, album: album) : null,
    headroomDb: HeadphoneEqService.headroomDb,
  );
}

/// [album] is [_usesAlbumNormalization] for [track], when already worked out.
bool _normalizationEnabledFor(MediaItem track, {bool? album}) {
  final settings = FinampSettingsHelper.finampSettings;
  return settings.volumeNormalizationActive &&
      (settings.volumeNormalizationMode != VolumeNormalizationMode.albumOnly ||
          (album ?? _usesAlbumNormalization(track)));
}

double? _legacyGainForCurrentPlayback(MediaItem currentTrack, jellyfin_models.BaseItemDto? item, {bool? album}) {
  final baseItem =
      item ?? jellyfin_models.BaseItemDto.fromJson(currentTrack.extras?["itemJson"] as Map<String, dynamic>);

  double? effectiveGainChange;
  final providerContainer = GetIt.instance<ProviderContainer>();
  providerContainer.read(
    currentTrackMetadataProvider,
  ); // forces it even in background https://github.com/rrousselGit/riverpod/issues/2671

  switch (FinampSettingsHelper.finampSettings.volumeNormalizationMode) {
    case VolumeNormalizationMode.hybrid when album ?? _usesAlbumNormalization(currentTrack):
    case VolumeNormalizationMode.albumBased:
      // metadataProvider is still used for Jellyfin <12.0
      final albumNormalizationGain =
          baseItem.albumNormalizationGain ??
          providerContainer.read(metadataProvider(baseItem)).valueOrNull?.albumNormalizationGain;

      effectiveGainChange = albumNormalizationGain ?? (currentTrack.extras?["contextNormalizationGain"] as double?);
      break;
    case VolumeNormalizationMode.hybrid:
    case VolumeNormalizationMode.trackBased:
      effectiveGainChange = baseItem.normalizationGain;
      break;
    case VolumeNormalizationMode.albumOnly:
      // only ever use context normalization gain, don't normalize tracks out of special contexts
      effectiveGainChange = currentTrack.extras?["contextNormalizationGain"] as double?;
      break;
  }
  return effectiveGainChange;
}

AudioServiceRepeatMode _audioServiceRepeatMode(LoopMode loopMode) {
  switch (loopMode) {
    case LoopMode.off:
      return AudioServiceRepeatMode.none;
    case LoopMode.one:
      return AudioServiceRepeatMode.one;
    case LoopMode.all:
      return AudioServiceRepeatMode.all;
  }
}

/// Who a pause is for: the listener (or anything acting for them, like a sleep timer), or the app's own pause, which
/// doesn't mean the music should stay paused.
enum PauseBy {
  listener,

  /// The DJ holding the music to read the news.
  news,

  /// The queue being replaced, before what replaces it plays.
  queueChange,
}
