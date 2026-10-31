import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:finamp/services/artist_spacing.dart';
import 'package:finamp/services/shuffle_randomness.dart';
import 'package:finamp/services/finamp_settings_helper.dart';

import 'package:collection/collection.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/models/music_slices.dart';
import 'package:finamp/services/ai_service.dart';
import 'package:finamp/services/analyzer_service.dart';
import 'package:finamp/services/finamp_user_helper.dart';
import 'package:finamp/services/jellyfin_api_helper.dart';
import 'package:finamp/services/music_player_background_task.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:finamp/services/song_duplicates.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:rxdart/rxdart.dart';

enum RunningProblem { noTempos, noSongs }

class RunningException implements Exception {
  const RunningException(this.problem);
  final RunningProblem problem;
}

/// Running mode: counts your steps and plays songs whose tempo matches your pace (or half/double of it), switching
/// as you speed up or slow down. Tempos come from the Finamp+ analyzer, or are estimated by the AI.
class RunningService {
  RunningService._();

  static final _logger = Logger("RunningService");
  static const _methods = MethodChannel("com.unicornsonlsd.finamp/steps");
  static const _steps = EventChannel("com.unicornsonlsd.finamp/steps/events");
  static const sourceId = "running";
  static const defaultPace = 160.0;

  /// Steps per minute measured from the step sensor, null until enough steps were counted.
  static final cadence = BehaviorSubject<double?>.seeded(null);

  /// The pace the music is matched to.
  static final pace = BehaviorSubject<double>.seeded(defaultPace);
  static final active = BehaviorSubject<bool>.seeded(false);

  /// Tempo (BPM) of the playing song, if known.
  static final currentTempo = BehaviorSubject<double?>.seeded(null);

  static double? _manualPace;
  static StreamSubscription<dynamic>? _stepSubscription;
  static StreamSubscription<String?>? _trackSubscription;
  static Timer? _timer;
  static final List<int> _stepTimes = [];
  static List<BaseItemDto> _pool = [];
  static Map<String, double> _tempos = {};
  static double _queuedFor = 0;
  static final Set<String> _used = {};

  static Future<bool> sensorAvailable() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _methods.invokeMethod<bool>("isAvailable") ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Steps per minute from step times (milliseconds), over the last [window]. Null with too few steps.
  static double? cadenceFrom(List<int> times, {int window = 12000}) {
    if (times.length < 6) return null;
    final recent = times.where((time) => time >= times.last - window).toList();
    if (recent.length < 6) return null;
    final span = recent.last - recent.first;
    if (span <= 0) return null;
    return (recent.length - 1) / span * 60000;
  }

  /// How far [bpm] is from [pace], as a fraction, counting half and double time as a match (a 85 BPM song works
  /// for 170 steps a minute).
  static double mismatch(double bpm, double pace) =>
      [bpm, bpm * 2, bpm / 2].map((tempo) => (tempo - pace).abs() / pace).min;

  /// Up to [count] songs close to [pace], closest more likely, leaving out [exclude].
  static List<BaseItemDto> pick(
    List<BaseItemDto> pool,
    Map<String, double> tempos,
    double pace, {
    required Set<String> exclude,
    int count = 4,
    Random? random,
    int randomness = DefaultSettings.shuffleRandomness,
    BaseItemDto? previous,
  }) {
    for (final tolerance in [0.06, 0.1, 0.16, 1.0]) {
      final close = [
        for (final track in pool)
          if (!exclude.contains(track.id.raw) && tempos[track.id.raw] != null)
            if (mismatch(tempos[track.id.raw]!, pace) case final miss when miss <= tolerance)
              (track: track, miss: miss),
      ];
      if (close.length >= count || tolerance == 1.0) {
        close.sort((a, b) {
          final mismatch = a.miss.compareTo(b.miss);
          return mismatch == 0 ? a.track.id.raw.compareTo(b.track.id.raw) : mismatch;
        });
        final ranked = ShuffleRandomness.order(
          withoutDuplicateSongs(close.map((c) => c.track)),
          randomness,
          random: random,
        );
        final spaced = ArtistSpacing.order(
          ranked,
          ArtistSpacing.artistKey,
          previousKey: previous == null ? null : ArtistSpacing.artistKey(previous),
          keepFirst: false,
          dropUnavoidable: true,
        ).take(count).toList();
        if (spaced.length >= count || tolerance == 1.0) return spaced;
      }
    }
    return [];
  }

  static Future<File> get _cacheFile async =>
      File("${(await getApplicationSupportDirectory()).path}/tempo_estimates.json");

  /// Tempos for [tracks]: from the analyzer when it's set up, otherwise estimated by the AI (and remembered).
  static Future<Map<String, double>> _loadTempos(List<BaseItemDto> tracks) async {
    final tempos = <String, double>{};
    if (await AnalyzerService.isConfigured()) {
      try {
        final analysis = await AnalyzerService.analysis([for (final track in tracks) track.id.raw]);
        for (final MapEntry(:key, :value) in analysis.entries) {
          if (value.bpm != null && value.bpm! > 0) tempos[key] = value.bpm!;
        }
      } catch (e) {
        _logger.info("Analyzer tempos unavailable: $e");
      }
    }
    final cache = <String, double>{};
    try {
      final file = await _cacheFile;
      if (await file.exists()) {
        for (final MapEntry(:key, :value) in (jsonDecode(await file.readAsString()) as Map<String, dynamic>).entries) {
          cache[key] = (value as num).toDouble();
        }
      }
    } catch (_) {}
    for (final track in tracks) {
      final bpm = cache[track.id.raw];
      if (!tempos.containsKey(track.id.raw) && bpm != null && bpm > 0) tempos[track.id.raw] = bpm;
    }

    final missing = tracks.where((track) => !tempos.containsKey(track.id.raw) && !cache.containsKey(track.id.raw));
    if (missing.isNotEmpty && await AiService.isConfigured()) {
      for (final batch in missing.take(300).slices(100)) {
        try {
          final result = await AiService.generateJson(
            prompt:
                "Estimate the tempo in beats per minute of each song. Give your best estimate from what you know "
                "about the song; use 0 only if you have no idea at all.\n\n"
                "${[for (final (index, track) in batch.indexed) "$index. ${track.albumArtist ?? track.artists?.firstOrNull ?? ""} - ${track.name}"].join("\n")}",
            schemaName: "tempos",
            schema: {
              "type": "object",
              "properties": {
                "tempos": {
                  "type": "array",
                  "items": {
                    "type": "object",
                    "properties": {
                      "index": {"type": "integer"},
                      "bpm": {"type": "number"},
                    },
                    "required": ["index", "bpm"],
                  },
                },
              },
              "required": ["tempos"],
            },
          );
          for (final entry in (result["tempos"] as List<dynamic>).cast<Map<String, dynamic>>()) {
            final index = (entry["index"] as num).toInt();
            if (index < 0 || index >= batch.length) continue;
            final bpm = (entry["bpm"] as num).toDouble();
            cache[batch[index].id.raw] = bpm;
            if (bpm > 0) tempos[batch[index].id.raw] = bpm;
          }
        } catch (e) {
          _logger.warning("Couldn't estimate tempos", e);
          break;
        }
      }
      try {
        await (await _cacheFile).writeAsString(jsonEncode(cache));
      } catch (_) {}
    }
    return tempos;
  }

  /// Starts running mode. With [manualPace], the music follows that pace instead of the step sensor.
  static Future<void> start({double? manualPace}) async {
    await stop();
    _manualPace = manualPace;
    pace.add(manualPace ?? cadence.value ?? defaultPace);

    final api = GetIt.instance<JellyfinApiHelper>();
    final pool =
        await api.getItems(
          parentItem: GetIt.instance<FinampUserHelper>().currentUser?.currentView,
          includeItemTypes: BaseItemDtoType.track.jellyfinName,
          recursive: true,
          sortBy: "Random",
          limit: 400,
        ) ??
        [];
    if (pool.isEmpty) throw const RunningException(RunningProblem.noSongs);
    _tempos = await _loadTempos(pool);
    _pool = pool.where((track) => _tempos.containsKey(track.id.raw)).toList();
    if (_pool.length < 12) throw const RunningException(RunningProblem.noTempos);
    _used.clear();

    if (manualPace == null && await sensorAvailable() && (await Permission.activityRecognition.request()).isGranted) {
      _stepTimes.clear();
      _stepsAtLastTick = 0;
      _stepSubscription = _steps.receiveBroadcastStream().listen((time) {
        _stepTimes.add((time as num).toInt());
        if (_stepTimes.length > 200) {
          _stepTimes.removeRange(0, 100);
          _stepsAtLastTick = max(0, _stepsAtLastTick - 100);
        }
      });
    }

    final first = pick(
      _pool,
      _tempos,
      pace.value,
      exclude: _used,
      count: 5,
      randomness: FinampSettingsHelper.finampSettings.shuffleRandomness,
    );
    _used.addAll(first.map((track) => track.id.raw));
    _queuedFor = pace.value;
    await GetIt.instance<QueueService>().startPlayback(
      items: first,
      randomizeGenerated: false,
      source: _source(),
      order: FinampPlaybackOrder.linear,
    );
    active.add(true);

    final player = GetIt.instance<MusicPlayerBackgroundTask>();
    _trackSubscription = player.mediaItem.map((item) => item?.id).distinct().listen((_) {
      final id = GetIt.instance<QueueService>().getCurrentTrack()?.baseItem.id.raw;
      currentTempo.add(id == null ? null : _tempos[id]);
      unawaited(_topUp(force: false));
    });
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _tick());
  }

  static QueueItemSource _source() => QueueItemSource.rawId(
    type: QueueItemSourceType.unknown,
    name: QueueItemSourceName(type: QueueItemSourceNameType.preTranslated, pretranslatedName: "Running"),
    id: sourceId,
  );

  static int _stepsAtLastTick = 0;

  static void _tick() {
    if (_manualPace != null) return;
    // Standing still at a crossing: keep the last pace rather than slowing the music down.
    final moving = _stepTimes.length != _stepsAtLastTick;
    _stepsAtLastTick = _stepTimes.length;
    final measured = cadenceFrom(_stepTimes);
    if (!moving || measured == null) return;
    if (measured < 90 || measured > 230) return;
    cadence.add(measured);
    // Follow the runner smoothly.
    pace.add(pace.value * 0.6 + measured * 0.4);
    if ((pace.value - _queuedFor).abs() / _queuedFor > 0.05) unawaited(_topUp(force: true));
  }

  /// Sets the pace by hand (also while running).
  static Future<void> setManualPace(double value) async {
    _manualPace = value;
    pace.add(value);
    if (active.value && (value - _queuedFor).abs() / _queuedFor > 0.03) await _topUp(force: true);
  }

  /// Makes sure the next songs suit the pace: replaces them when the pace changed ([force]), or adds some when few
  /// are left.
  static Future<void> _topUp({required bool force}) async {
    if (!active.value) return;
    final queue = GetIt.instance<QueueService>();
    final info = queue.getQueue();
    final upcoming = info.nextUp.length + info.queue.length;
    if (!force && upcoming >= 2) return;
    final next = pick(
      _pool,
      _tempos,
      pace.value,
      exclude: _used,
      count: 4,
      previous: info.currentTrack?.baseItem,
      randomness: FinampSettingsHelper.finampSettings.shuffleRandomness,
    );
    if (next.isEmpty) {
      // Played through everything that fits: allow repeats again.
      _used.clear();
      return;
    }
    _used.addAll(next.map((track) => track.id.raw));
    _queuedFor = pace.value;
    await queue.replaceUpcoming(PlayableSlice.simple(next, _source()).markPreshuffled());
  }

  static Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    await _stepSubscription?.cancel();
    _stepSubscription = null;
    await _trackSubscription?.cancel();
    _trackSubscription = null;
    if (active.value) active.add(false);
  }
}
