import 'dart:async';
import 'package:finamp/services/listening_preferences.dart';
import 'package:finamp/services/tempo_matching.dart';
import 'dart:io';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/services/analyzer_service.dart';
import 'package:finamp/services/dj_voice_service.dart';
import 'package:finamp/services/music_player_background_task.dart';
import 'package:finamp/services/night_mode_service.dart';
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
/// On Android ordinary fades mix the second player's sound into the main player's own output (see CrossfadeBridge in the
/// vendored just_audio), so everything comes out of one output; when the main player reaches the next song it continues
/// at exactly the next sample. If that mix cannot be scheduled safely, Android plays the transition normally.
/// Tempo matching and other platforms use two outputs and line them up at the hand-over.
class CrossfadeService {
  CrossfadeService._();

  static final _logger = Logger("CrossfadeService");
  static const _secondsKey = "crossfadeSeconds";
  static const _albumsKey = "crossfadeKeepAlbumsGapless";
  static const _tempoKey = 'crossfadeTempoMatching';
  static const maxSeconds = 12;

  static CrossfadeSettings _settings = (seconds: 0, keepAlbumsGapless: true);
  static bool _tempoEnabled = false;
  static TempoMatch? _tempoMatch;
  static bool _tempoHandover = false;
  static double? _catchUpBaseSpeed;
  static int _generation = 0;
  static final _handoverSeekKey = Object();

  /// Only the crossfade's own seek may keep the covering player running.
  static bool get isHandoverSeek => Zone.current[_handoverSeekKey] == true;

  static Future<void> _seekForHandover(MusicPlayerBackgroundTask player, Duration position) =>
      runZoned(() => player.seek(position, userInitiated: false), zoneValues: {_handoverSeekKey: true});

  // The Android PCM mixer runs before Media3's speed processor. Independent
  // speeds therefore need two outputs. Darwin explicitly uses AVAudioTimePitchAlgorithmTimeDomain.
  static bool get tempoMatchingSupported => Platform.isAndroid || Platform.isIOS || Platform.isMacOS;

  static Future<bool> loadTempoMatching() async => await SharedPreferencesAsync().getBool(_tempoKey) ?? false;

  /// From the next transition on: one already playing keeps its plan, as stopping it would restart the next song.
  static Future<void> saveTempoMatching(bool enabled) async {
    _tempoEnabled = enabled;
    await SharedPreferencesAsync().setBool(_tempoKey, enabled);
  }

  /// Navigation, pausing or a new playback speed must stop a tempo ramp before moving either player. Only while a
  /// ramp is planned or handing over: an ordinary crossfade, or one still being prepared, carries on.
  static Future<void> interruptTempoMatching() async {
    // A second command during the cancellation waits for it too, so it can't run first and be undone by the older one.
    if (_tempoCancelling case final pending?) return pending;
    if (_tempoMatch != null || _tempoHandover) {
      _skipForCurrentId = _currentId;
      final pending = _tempoCancelling = _cancel();
      try {
        await pending;
      } finally {
        if (identical(_tempoCancelling, pending)) _tempoCancelling = null;
      }
    }
  }

  /// The cancellation of a tempo-matched fade that a transport command started, while it runs.
  static Future<void>? _tempoCancelling;

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

  /// A change of songs kept clear of any crossfade, for the DJ to pause for the news there: the queue entry playing,
  /// and the songs on either side.
  static ({String entry, String from, String into})? _heldChange;

  /// Keeps the change from [current] into [next] clear of a crossfade (and a DJ transition), so [current] plays to its
  /// end and [next] starts from the top: for a news break between them. False when that crossfade is already under
  /// way, so it stays as it is.
  static bool holdChange(FinampQueueItem current, FinampQueueItem next) {
    final held = _heldChange;
    if (held != null && held.entry == current.id && held.into == next.baseItemId.raw) return true;
    if (_currentId == current.id && _nextId == next.id && (_scheduledWindow != null || _fading || _priming)) {
      return false;
    }
    _heldChange = (entry: current.id, from: current.baseItemId.raw, into: next.baseItemId.raw);
    _logger.info("No crossfade into the next song: the DJ pauses for the news there");
    return true;
  }

  /// Lets the change held by [holdChange] crossfade again; not while [unlessEntry], the song before it, still plays.
  static void releaseChange({String? unlessEntry}) {
    if (unlessEntry == null || _heldChange?.entry != unlessEntry) _heldChange = null;
  }

  /// How many seconds the change from [outgoing] into [incoming] fades over ([ListeningPreferences.fadeSeconds]), or
  /// none for a change held for the news.
  static int fadeSeconds(String? outgoing, String? incoming, int seconds) {
    final held = _heldChange;
    if (held != null && held.from == outgoing && held.into == incoming) return 0;
    return ListeningPreferences.fadeSeconds(outgoing, incoming, seconds);
  }

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
    final seconds = fadeSeconds(current?.baseItemId.raw, next?.baseItemId.raw, _settings.seconds);
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
    _tempoEnabled = await loadTempoMatching();
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
    // The player itself: held for the news, the playback state shows it playing while it stands still.
    _playingSubscription = player.playerPlaying.distinct().listen((playing) {
      _timer?.cancel();
      _timer = playing ? Timer.periodic(const Duration(milliseconds: 100), (_) => unawaited(_tick())) : null;
      if (!playing && (_tempoMatch != null || _tempoHandover)) {
        unawaited(interruptTempoMatching());
        return;
      }
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
      // Past the change held for the news.
      releaseChange(unlessEntry: current.id);
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
    if (duration == null || player.paused) return;
    final upcomingTrack = queue.getQueue();
    final incoming = upcomingTrack.nextUp.firstOrNull ?? upcomingTrack.queue.firstOrNull;
    // Once scheduled, keep the native window immutable through hand-over.
    if (_scheduledWindow == null &&
        fadeSeconds(current.baseItemId.raw, incoming?.baseItemId.raw, _settings.seconds) == 0) {
      if (_nextId != null) await _cancel();
      return;
    }
    final length = Duration(seconds: fadeSeconds(current.baseItemId.raw, incoming?.baseItemId.raw, _settings.seconds));
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
      _tempoMatch = _tempoFor(duration, current.baseItemId.raw, incoming?.baseItemId.raw);
      if (_tempoMatch case final match?) {
        // Update more often while the independent players meet and change tempo.
        _timer?.cancel();
        _timer = Timer.periodic(const Duration(milliseconds: 20), (_) => unawaited(_tick()));
        // The opening was buffered at normal speed when the song was loaded, and a new speed only reaches audio decoded
        // after it. Seeking the still paused player to where it is flushes that, so the song starts at the matched
        // tempo from its first sample, as the beat timing assumes.
        await nextPlayer.setSpeed(match.initialSpeed);
        if (_nextPlayer != nextPlayer) return;
        await nextPlayer.seek(nextPlayer.position);
        if (_nextPlayer != nextPlayer) return;
      }
      final currentGain = player.normalizationFactorFor(current.item);
      _gainRatio = currentGain > 0 ? _nextGain / currentGain : 1.0;
      _mixed =
          _tempoMatch == null &&
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
        if (Platform.isAndroid && _tempoMatch == null) {
          return _skipCrossfade('native mixing is unavailable for this transition');
        }
        await _bridge<void>('disarm');
        _logger.info('Crossfade with two outputs${_tempoMatch == null ? '' : ' (tempo matched)'}');
      }
    }
    if (_nextPlayer != nextPlayer) return;
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
      if (_nextPlayer != nextPlayer) return;
      if (_tempoMatch case final match?) await nextPlayer.setSpeed(match.initialSpeed);
      if (_nextPlayer != nextPlayer) return;
      unawaited(nextPlayer.play());
      _logger.info(
        "Crossfading into $_nextId from ${window.start.inMilliseconds} to ${window.end.inMilliseconds} ms "
        "(song ${duration.inMilliseconds} ms${window.timed ? ", timed by its analysis" : ""})",
      );
    }
    if (_fading) {
      if (_nextPlayer != nextPlayer) return;
      if (_tempoMatch case final match?) {
        final speed = match.speedAt(nextPlayer.position.inMicroseconds / 1000000);
        if ((nextPlayer.speed - speed).abs() > 1e-5) await nextPlayer.setSpeed(speed);
        if (_nextPlayer != nextPlayer) return;
      }
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
        if (_nextPlayer != nextPlayer) return;
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
        // Cancelled meanwhile (a pause, seek or skip): the main player is the listener's again, so it's left alone.
        if (_nextPlayer != nextPlayer) return;
        await player.setTransitionVolume(0);
        if (_nextPlayer != nextPlayer) {
          // The cancellation's own clean-up has run, so the mute is undone here.
          await player.setTransitionVolume(1.0);
          return;
        }
        // To the very end, as if it had played out: it counts as played, not skipped.
        await _seekForHandover(player, duration);
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
    final seconds = fadeSeconds(current.baseItemId.raw, next.baseItemId.raw, _settings.seconds);
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

  /// On Android the second output skips everything done to the main player's own sound: the equaliser (headphone
  /// correction, tone controls), night mode's compressor, and the DJ's ducking envelope. So tempo matching, which
  /// needs that output, is only used while none of them is in play; otherwise the song would change tone or level at
  /// the hand-over, or jump in level under the DJ, and an ordinary transition sounds better.
  static bool _secondOutputSoundsTheSame(MusicPlayerBackgroundTask player) {
    if (player.equalizer?.enabled ?? false) return false;
    if (NightModeService.isActive) return false;
    final (speaking, preparing, _) = DjVoiceService.status.value;
    return !speaking && !preparing && DjVoiceService.effectiveProfile.settings.mode == DjVoiceMode.off;
  }

  static TempoMatch? _tempoFor(Duration duration, String? currentId, String? nextId) {
    if (!_tempoEnabled || !tempoMatchingSupported || currentId == null || nextId == null) return null;
    if (_nextPlayer == null || currentId != _currentTrack || nextId != _nextTrack) return null;
    if (GetIt.instance.isRegistered<MusicPlayerBackgroundTask>()) {
      final player = GetIt.instance<MusicPlayerBackgroundTask>();
      if (player.speed != 1.0) return null;
      // The covering player plays at its own, normal pitch, so a shifted pitch would jump at the hand-over.
      final pitch = GetIt.instance.isRegistered<QueueService>() ? GetIt.instance<QueueService>().playbackPitch : 1.0;
      if (pitch != 1.0) return null;
      if (Platform.isAndroid && !_secondOutputSoundsTheSame(player)) return null;
    }
    final current = AnalyzerService.cached(currentId), next = AnalyzerService.cached(nextId);
    if (current == null ||
        next == null ||
        next.firstBeat == null ||
        !next.firstBeat!.isFinite ||
        next.firstBeat! < 0 ||
        next.firstBeat! > 8) {
      return null;
    }
    final length = fadeSeconds(currentId, nextId, _settings.seconds).toDouble();
    final normal = crossfadeWindow(
      duration: duration.inMilliseconds / 1000,
      length: length,
      current: current,
      next: next,
      bars: HarmonicMixing.enabled,
    );
    if (normal == null || current.lastBeat == null || current.lastBeat! < normal.end - length - 4) return null;
    if (!canCoverNativeTail(
      untilBoundary: duration - Duration(microseconds: (normal.start * 1000000).round()) + const Duration(seconds: 1),
      incomingDuration: _nextPlayer?.duration,
    )) {
      return null;
    }
    // The small margin covers a beat-alignment adjustment and player command latency.
    final bpm = current.beatBpm ?? current.bpm;
    if (bpm == null || bpm < 50 || bpm > 220) return null;
    final margin = (HarmonicMixing.enabled ? 120 : 60) / bpm;
    return TempoMatch.plan(
      outgoingBpm: bpm,
      incomingBpm: next.beatBpm ?? next.bpm,
      availableSeconds: normal.end - normal.start - margin,
      firstBeat: next.firstBeat!,
    );
  }

  /// Where in the current song (of [duration]) the crossfade starts and ends. Without analysis that's the song's last
  /// [seconds]. With it, the fade ends where the song's sound ends (before trailing silence or a hidden track), the
  /// next song's leading silence is played under the fade rather than after it, and the next song's first beat lands
  /// on one of this song's beats.
  static ({Duration start, Duration end, bool timed}) _window(Duration duration, {String? outgoing, String? incoming}) {
    final currentId = outgoing ?? _currentTrack, nextId = incoming ?? _nextTrack;
    final seconds = fadeSeconds(currentId, nextId, _settings.seconds);
    final length = Duration(seconds: seconds);
    final fallback = (start: duration - length, end: duration, timed: false);
    final current = currentId == null ? null : AnalyzerService.cached(currentId);
    if (current == null) return fallback;
    final next = nextId == null ? null : AnalyzerService.cached(nextId);
    final tempo = currentId == _currentTrack && nextId == _nextTrack
        ? _tempoMatch ?? _tempoFor(duration, currentId, nextId)
        : null;
    final window = crossfadeWindow(
      duration: duration.inMilliseconds / 1000,
      length: seconds.toDouble(),
      current: current,
      next: next,
      bars: HarmonicMixing.enabled,
      nextBeatElapsed: tempo != null && next?.firstBeat != null ? tempo.elapsedAt(next!.firstBeat!) : null,
      nextStartElapsed: tempo != null && next?.start != null ? tempo.elapsedAt(next!.start!) : null,
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
    double? nextBeatElapsed,
    double? nextStartElapsed,
  }) {
    final end = current.end;
    if (end == null || current.duration == null || (current.duration! - duration).abs() > 3) return null;
    // Not into the song's body: a fade can only end so far before the file's end.
    if (end > duration || end < duration * 0.5 || end < length * 3) return null;
    // The next song's silence before its sound starts runs under the fade, so its sound starts on time.
    final lead = min(3.0, nextStartElapsed ?? next?.start ?? 0.0);
    final target = end - length - lead;
    var start = target;
    final bpm = current.beatBpm ?? current.bpm,
        lastBeat = current.lastBeat,
        firstBeat = nextBeatElapsed ?? next?.firstBeat;
    // Only where this song still has a beat near the fade: counted back from far off, any tempo drift adds up.
    if (bpm != null &&
        bpm >= 50 &&
        bpm <= 220 &&
        lastBeat != null &&
        lastBeat >= end - length - 4 &&
        firstBeat != null &&
        firstBeat >= 0 &&
        (next?.firstBeat ?? firstBeat) <= 8) {
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
    if (Platform.isAndroid && _tempoMatch == null) {
      return _skipCrossfade('native hand-over unavailable', skipCurrent: false);
    }
    if (_tempoMatch != null) {
      // The planned ramp has finished before this boundary; never transfer its speed to the main player.
      _tempoHandover = true;
      await nextPlayer.setSpeed(1.0);
      if (_nextPlayer != nextPlayer) return;
    }
    await _catchUp();
  }

  /// Two outputs: the main player jumps to where the second player is, lines up with it, and takes over.
  static Future<void> _catchUp() async {
    final nextPlayer = _nextPlayer!;
    final id = _nextId;
    final player = GetIt.instance<MusicPlayerBackgroundTask>();
    final generation = _generation;
    bool live() => generation == _generation && _nextPlayer == nextPlayer && _stillOn(id);
    if (!_stillOn(id)) return _giveUp("the main player moved on to another song");
    final baseSpeed = _tempoHandover ? 1.0 : player.speed;
    _catchUpBaseSpeed = baseSpeed;
    // Silent while catching up: the main player starts the new song from the top, which mustn't be heard twice.
    await player.setTransitionVolume(0);
    var gaveUp = false;
    try {
      // How long a seek takes varies a lot (over half a second on a slow stream), so it can't land exactly. Seek
      // close, then close the gap by playing a little faster or slower: no new seek, and inaudible while muted.
      Future<void> seekNear() async {
        final (_, nextPosition) = await _positions(player, nextPlayer);
        final target = nextPosition + const Duration(milliseconds: 250);
        final duration = player.playerDuration;
        // Never past the song's end: that ends it at once and starts the next one.
        if (!live() || (duration != null && target > duration - const Duration(seconds: 2))) {
          gaveUp = true;
          throw StateError("the main player isn't on the crossfaded song any more");
        }
        // Waited for however long it takes: the second player keeps covering until the main one is really there, and a
        // seek given up on would still land later, from a stale spot.
        await _seekForHandover(player, target);
        if (!live()) {
          gaveUp = true;
          throw StateError("the crossfade was cancelled during the seek");
        }
        // Streams may need a moment to buffer at the new spot; the second player covers for it.
        await player.playbackState
            .firstWhere((state) => state.processingState == AudioProcessingState.ready)
            .timeout(const Duration(seconds: 5));
      }

      await seekNear();
      for (var attempt = 0; attempt < 8; attempt++) {
        // Positions only settle once audio is flowing.
        await Future<void>.delayed(const Duration(milliseconds: 300));
        if (!live()) return;
        // The covering player is what's heard meanwhile, so it follows the music's level, such as the dip while the
        // DJ talks, which only reaches the main player on its own.
        await nextPlayer.setVolume(player.crossfadeBaseVolume * _nextGain);
        if (!live()) return;
        final (mainPosition, secondPosition) = await _positions(player, nextPlayer);
        if (!live()) return;
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
        if (!live()) return;
        await player.setSpeed(baseSpeed);
      }
    } catch (e) {
      _logger.info("Crossfade hand-over was rough: $e");
    } finally {
      if (generation == _generation && player.speed != baseSpeed) await player.setSpeed(baseSpeed);
    }
    if (!live()) return;
    if (gaveUp || !_stillOn(id)) return _giveUp("the main player moved on to another song");
    // Blend instead of switching: whatever drift is left is smeared over the ramp instead of heard as a jump.
    const steps = 12;
    for (var step = 1; step <= steps; step++) {
      if (!live()) return;
      await player.setTransitionVolume(step / steps);
      if (!live()) return;
      // At the music's level now, which a DJ line may be lowering.
      await nextPlayer.setVolume(player.crossfadeBaseVolume * _nextGain * (1 - step / steps));
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
    _generation++;
    PlaybackPreparationCoordinator.shared.cancel('crossfade');
    _preparing = false;
    final nextPlayer = _nextPlayer;
    _nextPlayer = null;
    _nextId = null;
    final wasFading = _fading;
    final wasTempo = _tempoMatch != null || _tempoHandover;
    if (wasTempo && _timer != null) {
      _timer!.cancel();
      _timer = Timer.periodic(const Duration(milliseconds: 100), (_) => unawaited(_tick()));
    }
    // The main player was at 1x when the ramp was planned; the listener may have chosen a speed since.
    final restoreSpeed = wasTempo ? FinampSettingsHelper.finampSettings.playbackSpeed : _catchUpBaseSpeed;
    _catchUpBaseSpeed = null;
    _tempoMatch = null;
    _tempoHandover = false;
    _fading = false;
    _priming = false;
    _nativeTried = false;
    _primeStarted = null;
    _scheduledWindow = null;
    _mixed = null;
    if (restoreSpeed != null) {
      // Restore the main player even if the incoming player's platform call fails.
      await Future.wait<void>(
        [
          if (nextPlayer != null) nextPlayer.setSpeed(1.0),
          GetIt.instance<MusicPlayerBackgroundTask>().setSpeed(restoreSpeed),
        ].map(
          (operation) => operation.catchError((Object error) {
            _logger.warning('Could not restore crossfade speed', error);
          }),
        ),
      );
    }
    await _bridge<void>("disarm");
    if (restoreVolume && wasFading) await GetIt.instance<MusicPlayerBackgroundTask>().setTransitionVolume(1.0);
    if (nextPlayer != null) {
      GetIt.instance<MusicPlayerBackgroundTask>().forgetNormalization(nextPlayer.platformId);
      await nextPlayer.stop();
      await nextPlayer.dispose();
    }
  }
}
