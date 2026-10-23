import 'dart:async';
import 'package:finamp/services/listening_preferences.dart';
import 'dart:io';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/services/analyzer_service.dart';
import 'package:finamp/services/music_player_background_task.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:finamp/services/radio_tuning.dart';
import 'package:finamp/services/playback_buffer_policy.dart';
import 'package:finamp/services/playback_preparation_coordinator.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:hive_ce/hive.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:just_audio/just_audio.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

typedef CrossfadeSettings = ({int seconds, bool keepAlbumsGapless});

/// Overlaps the end of each song with the start of the next. The next song starts early on a second player.
///
/// On Android the second player's sound is mixed into the main player's own output (see CrossfadeBridge in the
/// vendored just_audio), so everything comes out of one output; when the main player reaches the next song it continues
/// at exactly the next sample. If that mix cannot be scheduled safely, Android plays the transition normally.
/// Other platforms use two outputs and line them up at the hand-over.
class CrossfadeService {
  CrossfadeService._();

  static final _logger = Logger("CrossfadeService");
  static const _secondsKey = "crossfadeSeconds";
  static const _albumsKey = "crossfadeKeepAlbumsGapless";
  static const maxSeconds = 12;

  static CrossfadeSettings _settings = (seconds: 0, keepAlbumsGapless: true);
  static bool get active => _settings.seconds > 0;

  @visibleForTesting
  static set settingsForTesting(CrossfadeSettings settings) => _settings = settings;
  static Future<void> cancelForKaraoke() => _cancel();
  static int get seconds => _settings.seconds;

  static Timer? _timer;
  static StreamSubscription<bool>? _playingSubscription;
  static String? _currentId;
  // The next song couldn't be loaded for crossfading.
  static String? _unplayableId;

  // The upcoming song on the second player.
  static AudioPlayer? _nextPlayer;
  static String? _nextId;
  static bool _preparing = false;
  static bool _fading = false;
  static bool _priming = false;
  static bool _nativeTried = false;
  static DateTime? _primeStarted;
  static ({Duration start, Duration end, bool timed})? _scheduledWindow;
  static double _nextGain = 1.0;
  static bool _busy = false;
  // Do not keep preparing a transition which cannot be mixed safely. A new
  // current song gets a fresh attempt, including after a skipped transition.
  static String? _skipForCurrentId;

  /// Whether this crossfade is mixed into the main player's output: null while that's still being found out.
  static bool? _mixed;
  static double _gainRatio = 1.0;
  static DateTime? _lastDiagnostics;
  static final _preparationLead = PreparationLead(
    minimum: const Duration(seconds: 20),
    maximum: const Duration(seconds: 45),
  );

  static Future<void> _logDiagnostics({bool force = false}) async {
    final now = DateTime.now();
    if (!force && _lastDiagnostics != null && now.difference(_lastDiagnostics!) < const Duration(seconds: 1)) return;
    _lastDiagnostics = now;
    try {
      final stats = await _positionsChannel.invokeMapMethod<String, dynamic>('diagnostics');
      for (final event in (stats?['events'] as List<dynamic>?) ?? const []) {
        _logger.info(
          'Native transition ${stats?['transition']}: $event '
          '[buffered ${stats?['bufferedFrames']} frames; own ${stats?['ownFrames']}; '
          'ring ${stats?['ringFrames']}; input stall ${stats?['maxInputStallMs']} ms; '
          'bypassed ${stats?['bypassedOwnFrames']} frames; '
          'underruns ${stats?['underruns']}; limiter gain ${stats?['limiterGain']}]',
        );
      }
    } catch (error) {
      _logger.fine('Native crossfade diagnostics unavailable: $error');
    }
  }

  static Future<CrossfadeSettings> loadSettings() async {
    final prefs = SharedPreferencesAsync();
    return (
      seconds: (await prefs.getInt(_secondsKey) ?? 0).clamp(0, maxSeconds),
      keepAlbumsGapless: await prefs.getBool(_albumsKey) ?? true,
    );
  }

  static Future<void> saveSettings(CrossfadeSettings settings) async {
    final prefs = SharedPreferencesAsync();
    await prefs.setInt(_secondsKey, settings.seconds);
    await prefs.setBool(_albumsKey, settings.keepAlbumsGapless);
    _settings = settings;
    if (active) {
      _start();
    } else {
      _stop();
      await _cancel();
    }
  }

  /// Jumps to just before the crossfade into the next song, to hear the hand-over right away. False when that isn't
  /// possible (nothing playing, crossfade off, or a song too short).
  static Future<bool> tryNow() async {
    final player = GetIt.instance<MusicPlayerBackgroundTask>();
    final duration = _songDuration(player);
    final queue = GetIt.instance<QueueService>();
    final current = queue.getCurrentTrack(), upcoming = queue.getQueue();
    final next = upcoming.nextUp.firstOrNull ?? upcoming.queue.firstOrNull;
    final seconds = ListeningPreferences.fadeSeconds(current?.baseItemId.raw, next?.baseItemId.raw, _settings.seconds);
    if (!active ||
        duration == null ||
        current == null ||
        next == null ||
        seconds == 0 ||
        keepsGapless(current.item, next.item) ||
        duration < Duration(seconds: seconds * 3)) {
      return false;
    }
    final window = _window(duration, outgoing: current.baseItemId.raw, incoming: next.baseItemId.raw);
    await player.seek(window.start - const Duration(seconds: 4), userInitiated: false);
    if (!player.playbackState.value.playing) await player.play();
    return true;
  }

  static String? _durationWarnedFor;

  /// The current song's length: the player's own figure once it has one, as the server's can be well off.
  static Duration? _songDuration(MusicPlayerBackgroundTask player) {
    final item = player.mediaItem.valueOrNull;
    final fromPlayer = player.playerDuration;
    if (fromPlayer == null || fromPlayer <= Duration.zero) return item?.duration;
    final fromServer = item?.duration;
    if (fromServer != null &&
        (fromPlayer - fromServer).abs() > const Duration(seconds: 2) &&
        _durationWarnedFor != item?.id) {
      _durationWarnedFor = item?.id;
      _logger.info("'${item?.title}' is ${fromPlayer.inSeconds} s long, the server says ${fromServer.inSeconds} s");
    }
    return fromPlayer;
  }

  static Future<void> initialize() async {
    _settings = await loadSettings();
    await HarmonicMixing.load();
    // Retire the old manual offset once; both paths now handle their own timing.
    final prefs = SharedPreferencesAsync();
    if (await prefs.containsKey("crossfadeSyncOffsetMs")) {
      await prefs.remove("crossfadeSyncOffsetMs");
    }
    if (active) _start();
  }

  static void _start() {
    if (_playingSubscription != null) return;
    final player = GetIt.instance<MusicPlayerBackgroundTask>();
    _playingSubscription = player.playbackState.map((state) => state.playing).distinct().listen((playing) {
      _timer?.cancel();
      _timer = playing ? Timer.periodic(const Duration(milliseconds: 100), (_) => unawaited(_tick())) : null;
      // Pausing mid-fade pauses both songs.
      if (_fading || _priming) unawaited(playing ? _nextPlayer?.play() : _nextPlayer?.pause());
    });
  }

  static void _stop() {
    unawaited(_playingSubscription?.cancel());
    _playingSubscription = null;
    _timer?.cancel();
    _timer = null;
  }

  /// Whether going from [current] to [next] should stay gapless: consecutive tracks of one album.
  static bool keepsGapless(MediaItem current, MediaItem next) {
    if (!_settings.keepAlbumsGapless) return false;
    final album = current.extras?["itemJson"]?["AlbumId"];
    final nextAlbum = next.extras?["itemJson"]?["AlbumId"];
    final index = current.extras?["itemJson"]?["IndexNumber"];
    final nextIndex = next.extras?["itemJson"]?["IndexNumber"];
    return album != null && album == nextAlbum && index is int && nextIndex == index + 1;
  }

  /// Equal-power curve, so the overlap doesn't dip or bulge in loudness. [t] runs from 0 to 1.
  static ({double out, double into}) curve(double t) {
    final clamped = t.clamp(0.0, 1.0);
    return (out: cos(clamped * pi / 2), into: sin(clamped * pi / 2));
  }

  /// The incoming song must last through the overlap and the outgoing file's
  /// silent tail. Otherwise retain the early-advance path for long hidden gaps.
  static bool canCoverNativeTail({required Duration untilBoundary, required Duration? incomingDuration}) =>
      incomingDuration != null && untilBoundary + const Duration(seconds: 2) < incomingDuration;

  /// Ticks don't overlap, so a slow hand-over can't be undone by the next tick halfway through.
  static Future<void> _tick() async {
    if (!active || _busy) return;
    _busy = true;
    try {
      await _step();
    } finally {
      _busy = false;
    }
  }

  static Future<void> _step() async {
    final player = GetIt.instance<MusicPlayerBackgroundTask>();
    if (player.karaokeActive) {
      await _cancel();
      return;
    }
    final queue = GetIt.instance<QueueService>();
    final current = queue.getCurrentTrack();
    if (current == null) return;

    if (current.id != _currentId) {
      _currentId = current.id;
      _skipForCurrentId = null;
      _currentTrack = current.baseItemId.raw;
      _skippedSilence = false;
      _nextTrack = null;
      final upcoming = queue.getQueue();
      // Looked up early, so the fade can be timed by the song's real ending and beats once it gets there.
      unawaited(
        AnalyzerService.cachedAnalysis([
          current.baseItemId.raw,
          ?(upcoming.nextUp.firstOrNull ?? upcoming.queue.firstOrNull)?.baseItemId.raw,
        ]),
      );
      if (_fading && current.id == _nextId) {
        await _handOver();
      } else {
        await _cancel();
      }
      return;
    }

    final duration = _songDuration(player);
    if (duration == null || !player.playbackState.value.playing) return;
    final upcomingTrack = queue.getQueue();
    final incoming = upcomingTrack.nextUp.firstOrNull ?? upcomingTrack.queue.firstOrNull;
    // Once scheduled, keep the native window immutable through hand-over.
    if (_scheduledWindow == null &&
        ListeningPreferences.fadeSeconds(current.baseItemId.raw, incoming?.baseItemId.raw, _settings.seconds) == 0) {
      if (_nextId != null) await _cancel();
      return;
    }
    final length = Duration(
      seconds: ListeningPreferences.fadeSeconds(current.baseItemId.raw, incoming?.baseItemId.raw, _settings.seconds),
    );
    if (duration < length * 3) return;
    final position = player.playbackPosition;
    final window =
        _scheduledWindow ?? _window(duration, outgoing: current.baseItemId.raw, incoming: incoming?.baseItemId.raw);

    if (_skipForCurrentId == current.id) {
      if (position >= window.start - const Duration(seconds: 3)) return;
      // An explicit rewind (including Try now) gets a new attempt, rather
      // than repeatedly retrying an unsafe transition near its deadline.
      _skipForCurrentId = null;
    }

    // Seeking back out of the overlap calls it off. Not a small jump back: the reported position can be corrected
    // backwards by a second or two now and then, which mustn't restart the crossfade.
    if ((_fading || _priming) && position < window.start - const Duration(seconds: 3)) {
      await _cancel();
      return;
    }

    if (!_fading && window.start - position <= _preparationLead.value) {
      final upcoming = queue.getQueue();
      final next = queue.loopMode == FinampLoopMode.one
          ? null
          : (upcoming.nextUp.firstOrNull ?? upcoming.queue.firstOrNull);
      if (next == null || keepsGapless(current.item, next.item)) {
        if (_nextId != null) await _cancel();
        return;
      }
      if (_nextId != null && _nextId != next.id) await _cancel();
      _nextTrack = next.baseItemId.raw;
      // Loading runs alongside the ticks, so slow streams don't stall them.
      if (_nextPlayer == null && !_preparing && next.id != _unplayableId) unawaited(_prepare(next));
    }

    final nextPlayer = _nextPlayer;
    if (nextPlayer == null) return;
    if (!_nativeTried && window.start - position <= const Duration(seconds: 2)) {
      _nativeTried = true;
      final currentGain = player.normalizationFactorFor(current.item);
      _gainRatio = currentGain > 0 ? _nextGain / currentGain : 1.0;
      _mixed =
          Platform.isAndroid &&
              player.speed == 1.0 &&
              canCoverNativeTail(untilBoundary: duration - window.start, incomingDuration: nextPlayer.duration)
          ? null
          : false;
      if (_mixed == null) {
        _priming = true;
        _primeStarted = DateTime.now();
        await nextPlayer.setVolume(0);
        unawaited(nextPlayer.play());
      } else {
        if (Platform.isAndroid) return _skipCrossfade('native mixing is unavailable for this transition');
        await _bridge<void>('disarm');
        _logger.info('Crossfade with two outputs (native mixing unavailable on this platform)');
      }
    }
    if (_priming && _mixed == null) {
      final result = await _bridge<int>('scheduleMix', {
        'startUs': window.start.inMicroseconds,
        'endUs': window.end.inMicroseconds,
        'in': _gainRatio,
      });
      if (result == 1) {
        _mixed = true;
        _scheduledWindow = window;
        _logger.info('Crossfade mixed into the main output (scheduled by PCM timestamps)');
      } else if (result == null ||
          result == -1 ||
          position >= window.start ||
          DateTime.now().difference(_primeStarted!) > const Duration(milliseconds: 1500)) {
        return _skipCrossfade('native schedule unavailable: $result');
      }
    }
    if (_priming && (_mixed ?? false) && !_fading) {
      final status = await _bridge<int>('status');
      if (status != _mixing) return _skipCrossfade('native pre-roll stopped: $status');
    }
    if (!_fading && position >= window.start) {
      _scheduledWindow ??= window;
      _fading = true;
      // Silent on its own in either case until the mode is known; mixed, it stays silent and is heard via the main one.
      await nextPlayer.setVolume(0);
      unawaited(nextPlayer.play());
      _logger.info(
        "Crossfading into $_nextId from ${window.start.inMilliseconds} to ${window.end.inMilliseconds} ms "
        "(song ${duration.inMilliseconds} ms${window.timed ? ", timed by its analysis" : ""})",
      );
    }
    if (_fading) {
      final progress = (position - window.start).inMilliseconds / max(1, (window.end - window.start).inMilliseconds);
      final volumes = curve(progress);
      final mixed = _mixed ?? false;
      final status = mixed ? await _bridge<int>("status") : null;
      // Catching up or done is fine: the main player may reach the next song a moment before this notices.
      if (mixed && status != _mixing && status != _catchingUp && status != _done) {
        return _skipCrossfade('native mix stopped: $status');
      }
      if (_mixed == false) {
        await player.setTransitionVolume(volumes.out);
        await nextPlayer.setVolume(volumes.into * player.crossfadeBaseVolume * _nextGain);
      }
      // Keep the native mix running across a silent tail. Seeking here flushes its
      // sample history and forces a second-clock hand-over, which can repeat or
      // drop seconds of the incoming song. Its samples already replace the tail.
      if (progress >= 1 && !_skippedSilence && _mixed == false && duration - position > _longSilence) {
        _skippedSilence = true;
        _logger.info("Skipping ${(duration - position).inSeconds} s of silence at the end of the song");
        // Make the covering player audible before muting or seeking the main one.
        await nextPlayer.setVolume(player.crossfadeBaseVolume * _nextGain);
        await player.setTransitionVolume(0);
        // To the very end, as if it had played out: it counts as played, not skipped.
        await player.seek(duration, userInitiated: false);
      }
    }
  }

  /// How long before the end of [current] (of [duration]) [next] starts to be heard, under the crossfade that will
  /// join them; zero when they won't be crossfaded. Only reads the timing, for the DJ to plan its line against.
  static Duration overlapBefore(FinampQueueItem current, FinampQueueItem next, Duration duration) {
    if (!active || _skipForCurrentId == current.id || keepsGapless(current.item, next.item)) return Duration.zero;
    if (GetIt.instance.isRegistered<QueueService>() && GetIt.instance<QueueService>().loopMode == FinampLoopMode.one) {
      return Duration.zero;
    }
    final seconds = ListeningPreferences.fadeSeconds(current.baseItemId.raw, next.baseItemId.raw, _settings.seconds);
    if (seconds == 0 || duration < Duration(seconds: seconds) * 3) return Duration.zero;
    final window =
        (_currentId == current.id && _nextId == next.id ? _scheduledWindow : null) ??
        _window(duration, outgoing: current.baseItemId.raw, incoming: next.baseItemId.raw);
    final overlap = duration - window.start;
    return overlap.isNegative ? Duration.zero : overlap;
  }

  static const _longSilence = Duration(seconds: 2);
  static bool _skippedSilence = false;
  // The current and next track's ids, for their analysis.
  static String? _currentTrack;
  static String? _nextTrack;

  /// Where in the current song (of [duration]) the crossfade starts and ends. Without analysis that's the song's last
  /// [seconds]. With it, the fade ends where the song's sound ends (before trailing silence or a hidden track), the
  /// next song's leading silence is played under the fade rather than after it, and the next song's first beat lands
  /// on one of this song's beats.
  static ({Duration start, Duration end, bool timed}) _window(Duration duration, {String? outgoing, String? incoming}) {
    final currentId = outgoing ?? _currentTrack, nextId = incoming ?? _nextTrack;
    final seconds = ListeningPreferences.fadeSeconds(currentId, nextId, _settings.seconds);
    final length = Duration(seconds: seconds);
    final fallback = (start: duration - length, end: duration, timed: false);
    final current = currentId == null ? null : AnalyzerService.cached(currentId);
    if (current == null) return fallback;
    final next = nextId == null ? null : AnalyzerService.cached(nextId);
    final window = crossfadeWindow(
      duration: duration.inMilliseconds / 1000,
      length: seconds.toDouble(),
      current: current,
      next: next,
      bars: HarmonicMixing.enabled,
    );
    if (window == null) return fallback;
    return (
      start: Duration(milliseconds: (window.start * 1000).round()),
      end: Duration(milliseconds: (window.end * 1000).round()),
      timed: true,
    );
  }

  /// The crossfade's start and end in seconds, for a song of [duration] seconds with a crossfade of [length], or null
  /// when the analysis doesn't fit the song as it plays (a different file, or no cues).
  static ({double start, double end})? crossfadeWindow({
    required double duration,
    required double length,
    required TrackAnalysis current,
    TrackAnalysis? next,
    bool bars = false,
  }) {
    final end = current.end;
    if (end == null || current.duration == null || (current.duration! - duration).abs() > 3) return null;
    // Not into the song's body: a fade can only end so far before the file's end.
    if (end > duration || end < duration * 0.5 || end < length * 3) return null;
    // The next song's silence before its sound starts runs under the fade, so its sound starts on time.
    final lead = min(3.0, next?.start ?? 0.0);
    final target = end - length - lead;
    var start = target;
    final bpm = current.beatBpm ?? current.bpm, lastBeat = current.lastBeat, firstBeat = next?.firstBeat;
    // Only where this song still has a beat near the fade: counted back from far off, any tempo drift adds up.
    if (bpm != null &&
        bpm >= 50 &&
        bpm <= 220 &&
        lastBeat != null &&
        lastBeat >= end - length - 4 &&
        firstBeat != null &&
        firstBeat <= 8) {
      // This song's beats counted back from its last one; the next song starts so its first beat falls on one.
      final beat = 60 / bpm;
      final steps = ((lastBeat - firstBeat - target) / beat).round();
      start = lastBeat - firstBeat - steps * beat;
      if ((start - target).abs() > beat) start = target;
      if (bars) {
        // Songs mostly end on the last beat of a bar: counting back from it in fours, the next song comes in on a
        // downbeat. That may move the fade by up to two beats.
        final barSteps = (steps / 4).round() * 4;
        final onBar = lastBeat - firstBeat - barSteps * beat;
        if ((onBar - target).abs() <= 2 * beat) start = onBar;
      }
    }
    return (start: max(0, start), end: end);
  }

  // CrossfadeBridge's statuses.
  static const _mixing = 2, _catchingUp = 3, _done = 4, _aborted = 6;

  /// Keep the ordinary main-player transition when native mixing is unsafe.
  /// Two-output catch-up mutes the main player while seeking and changing speed;
  /// a stalled seek can leave it "playing" silently, or chase a different song.
  static Future<void> _skipCrossfade(String reason, {bool skipCurrent = true}) async {
    if (skipCurrent) _skipForCurrentId = _currentId;
    _logger.info('Crossfade skipped ($reason); continuing normal playback');
    await _cancel();
  }

  static Future<T?> _bridge<T>(String method, [Map<String, Object?>? arguments]) async {
    if (!Platform.isAndroid) return null;
    try {
      if (method == 'disarm') await _logDiagnostics(force: true);
      final result = await _positionsChannel.invokeMethod<T>(method, arguments);
      if (method == 'status') await _logDiagnostics(force: result == _done);
      return result;
    } catch (e) {
      _logger.warning("Crossfade bridge call $method failed", e);
      return null;
    }
  }

  static Future<void> _prepare(FinampQueueItem next) async {
    final ticket = PlaybackPreparationCoordinator.shared.start('crossfade');
    final loading = Stopwatch()..start();
    _preparing = true;
    _nextId = next.id;
    try {
      await GetIt.instance<MusicPlayerBackgroundTask>()
          .prepareNormalization([next.item])
          .timeout(const Duration(seconds: 10));
    } catch (error) {
      _preparationLead.record(loading.elapsed);
      if (ticket.current) {
        _preparing = false;
        _unplayableId = next.id;
        _nextId = null;
      }
      _logger.info('Crossfade preparation unavailable: ${error.runtimeType}; continuing normal playback');
      return;
    }
    if (!ticket.current || _nextId != next.id || !active) {
      if (ticket.current) _preparing = false;
      return;
    }
    // Android normalizes each PCM stream before mixing; its volume factor is unity.
    _nextGain = GetIt.instance<MusicPlayerBackgroundTask>().normalizationFactorFor(next.item);
    final player = AudioPlayer(
      handleInterruptions: false,
      handleAudioSessionActivation: false,
      audioLoadConfiguration: PlaybackBufferPolicy.incoming(
        totalBytes: Hive.isBoxOpen('FinampSettings')
            ? FinampSettingsHelper.finampSettings.bufferSizeMegabytes * 1024 * 1024
            : PlaybackBufferPolicy.defaultBudgetBytes,
      ),
    );
    try {
      // Collects the next song's sound from its first sample on, in case it gets mixed into the main output. The
      // native player only gets its id as it starts, and arming has to come before its first sample.
      player.onPlatformId = (id) {
        if (!ticket.current || _nextId != next.id || !active) return;
        unawaited(GetIt.instance<MusicPlayerBackgroundTask>().configureNormalization(id, next.item));
        final mainId = GetIt.instance<MusicPlayerBackgroundTask>().playerPlatformId;
        if (mainId != null) unawaited(_bridge<void>("arm", {"main": mainId, "next": id}));
      };
      await player.setVolume(0);
      // Its own transcode session: sharing the main player's makes the server restart one transcode back and forth
      // between the two players' positions, stalling both and leaving copies that no longer line up.
      await player
          .setAudioSource(
            await GetIt.instance<MusicPlayerBackgroundTask>().audioSourceFor(next, playSessionId: const Uuid().v4()),
          )
          .timeout(const Duration(seconds: 20));
      if (ticket.current && _nextId == next.id && active) {
        _nextPlayer = player;
      } else {
        GetIt.instance<MusicPlayerBackgroundTask>().forgetNormalization(player.platformId);
        await player.dispose();
      }
    } catch (e) {
      _logger.warning("Couldn't load the next song for crossfading", e);
      GetIt.instance<MusicPlayerBackgroundTask>().forgetNormalization(player.platformId);
      await player.dispose();
      // Don't keep trying: it plays without a crossfade (or gets skipped, if it can't be played at all).
      if (ticket.current) {
        _unplayableId = next.id;
        if (_nextId == next.id) _nextId = null;
      }
    } finally {
      _preparationLead.record(loading.elapsed);
      if (ticket.current) _preparing = false;
    }
  }

  /// Whether the main player is still on the song [id] that was crossfaded into. Once it has moved on (that song ended,
  /// or a skip), the second player's position belongs to another song: seeking there skipped song after song.
  static bool _stillOn(String? id) => id != null && GetIt.instance<QueueService>().getCurrentTrack()?.id == id;

  /// The main player has moved on during the hand-over: drop the second player and let the main one play on.
  static Future<void> _giveUp(String reason) async {
    _logger.warning("Crossfade hand-over given up: $reason");
    await GetIt.instance<MusicPlayerBackgroundTask>().setTransitionVolume(1.0);
    await _cancel();
  }

  /// The main player reached the song that's already playing on the second player.
  static Future<void> _handOver() async {
    final id = _nextId;
    final nextPlayer = _nextPlayer;
    if (nextPlayer == null) return;
    if (_mixed ?? false) {
      // Mixed: the main player continues by itself at the right sample; wait for it to say so.
      int? status;
      // Up to 2 min: the catch-up always gets there, but on a slow stream with a long crossfade it can take a while,
      // and the song keeps playing meanwhile. This only guards against a stuck player.
      for (var attempt = 0; attempt < 2400; attempt++) {
        status = await _bridge<int>("status");
        if (_nextPlayer != nextPlayer || !active) return;
        if (status != _mixing && status != _catchingUp) break;
        if (!_stillOn(id)) return _giveUp("the main player moved on to another song");
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      if (status == _done) {
        _logger.info("Crossfade hand-over done in the main output");
        await _cancel(restoreVolume: false);
        return;
      }
      if (status == _aborted) {
        // The main player was flushed: a seek or skip during the hand-over. That's where the listener wants to be,
        // so don't pull it back to the second player's position.
        _logger.info("Seeked during the mixed hand-over; the main player carries on from there");
        await _cancel();
        return;
      }
      return _skipCrossfade('native hand-over failed: $status', skipCurrent: false);
    }
    if (Platform.isAndroid) return _skipCrossfade('native hand-over unavailable', skipCurrent: false);
    await _catchUp();
  }

  /// Two outputs: the main player jumps to where the second player is, lines up with it, and takes over.
  static Future<void> _catchUp() async {
    final nextPlayer = _nextPlayer!;
    final id = _nextId;
    final player = GetIt.instance<MusicPlayerBackgroundTask>();
    if (!_stillOn(id)) return _giveUp("the main player moved on to another song");
    // Silent while catching up: the main player starts the new song from the top, which mustn't be heard twice.
    await player.setTransitionVolume(0);
    final baseSpeed = player.speed;
    var gaveUp = false;
    try {
      // How long a seek takes varies a lot (over half a second on a slow stream), so it can't land exactly. Seek
      // close, then close the gap by playing a little faster or slower: no new seek, and inaudible while muted.
      Future<void> seekNear() async {
        final (_, nextPosition) = await _positions(player, nextPlayer);
        final target = nextPosition + const Duration(milliseconds: 250);
        final duration = player.playerDuration;
        // Never past the song's end: that ends it at once and starts the next one.
        if (!_stillOn(id) || (duration != null && target > duration - const Duration(seconds: 2))) {
          gaveUp = true;
          throw StateError("the main player isn't on the crossfaded song any more");
        }
        await player.seek(target, userInitiated: false);
        // Streams may need a moment to buffer at the new spot; the second player covers for it.
        await player.playbackState
            .firstWhere((state) => state.processingState == AudioProcessingState.ready)
            .timeout(const Duration(seconds: 5));
      }

      await seekNear();
      for (var attempt = 0; attempt < 8; attempt++) {
        // Positions only settle once audio is flowing.
        await Future<void>.delayed(const Duration(milliseconds: 300));
        final (mainPosition, secondPosition) = await _positions(player, nextPlayer);
        // Positive: the main player is behind the second player.
        final drift = secondPosition - mainPosition;
        _logger.info("Crossfade hand-over drift: ${drift.inMilliseconds} ms");
        if (drift.abs() <= const Duration(milliseconds: 10)) break;
        if (drift.abs() > const Duration(seconds: 2)) {
          await seekNear();
          continue;
        }
        // At most half again as fast or half as slow; small gaps close over a second.
        final span = max(1000, drift.inMilliseconds.abs() * 2);
        await player.setSpeed(baseSpeed * (1 + drift.inMilliseconds / span));
        await Future<void>.delayed(Duration(milliseconds: span));
        await player.setSpeed(baseSpeed);
      }
    } catch (e) {
      _logger.info("Crossfade hand-over was rough: $e");
    } finally {
      if (player.speed != baseSpeed) await player.setSpeed(baseSpeed);
    }
    if (gaveUp || !_stillOn(id)) return _giveUp("the main player moved on to another song");
    // Blend instead of switching: whatever drift is left is smeared over the ramp instead of heard as a jump.
    final nextVolume = nextPlayer.volume;
    const steps = 12;
    for (var step = 1; step <= steps; step++) {
      if (_nextPlayer != nextPlayer) return;
      await player.setTransitionVolume(step / steps);
      await nextPlayer.setVolume(nextVolume * (1 - step / steps));
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    await player.setTransitionVolume(1.0);
    await _cancel(restoreVolume: false);
  }

  static const _positionsChannel = MethodChannel("com.unicornsonlsd.finamp/crossfade");

  /// Where the main and the second player are, read from the native players at the same moment. The positions the
  /// players report themselves are estimated from their last update, which can be tens of milliseconds off just after
  /// a seek: enough to hear as a skip.
  static Future<(Duration, Duration)> _positions(MusicPlayerBackgroundTask player, AudioPlayer nextPlayer) async {
    final ids = [player.playerPlatformId, nextPlayer.platformId];
    if (Platform.isAndroid && !ids.contains(null)) {
      try {
        final positions = await _positionsChannel.invokeListMethod<int?>("positions", {"ids": ids});
        if (positions != null && positions.length == 2 && !positions.contains(null)) {
          return (Duration(milliseconds: positions[0]!), Duration(milliseconds: positions[1]!));
        }
      } catch (e) {
        _logger.fine("Exact positions unavailable: $e");
      }
    }
    return (player.playbackPosition, nextPlayer.position);
  }

  static Future<void> _cancel({bool restoreVolume = true}) async {
    PlaybackPreparationCoordinator.shared.cancel('crossfade');
    _preparing = false;
    final nextPlayer = _nextPlayer;
    _nextPlayer = null;
    _nextId = null;
    final wasFading = _fading;
    _fading = false;
    _priming = false;
    _nativeTried = false;
    _primeStarted = null;
    _scheduledWindow = null;
    _mixed = null;
    await _bridge<void>("disarm");
    if (restoreVolume && wasFading) await GetIt.instance<MusicPlayerBackgroundTask>().setTransitionVolume(1.0);
    if (nextPlayer != null) {
      GetIt.instance<MusicPlayerBackgroundTask>().forgetNormalization(nextPlayer.platformId);
      await nextPlayer.stop();
      await nextPlayer.dispose();
    }
  }
}
