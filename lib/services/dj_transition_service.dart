import 'dart:async';
import 'dart:isolate';
import 'dart:math';

import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/analyzer_service.dart';
import 'package:finamp/services/artist_spacing.dart';
import 'package:finamp/services/crossfade_service.dart';
import 'package:finamp/services/music_player_background_task.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// How a mix's energy runs from start to end.
enum EnergyShape {
  /// Calm to intense: a warm-up, getting ready to go out.
  build,

  /// Up to a peak about two thirds of the way in, then easing off: a party, a workout with a cool-down.
  peak,

  /// About the same all the way: focus, running, background music.
  steady,

  /// Intense to calm: winding down, bedtime.
  windDown,

  /// Rising and falling twice: a long session with breathers. Only chosen by hand, not by the Ai DJ.
  wave,

  /// No particular shape.
  free,
}

/// DJ-style transitions: fades each song out over its last bars and the next one in, timed to their tempo,
/// and orders mixes so neighbouring songs have compatible keys and tempos. Needs the Finamp+ analyzer.
class DjTransitionService {
  DjTransitionService._();

  static final _logger = Logger("DjTransitionService");
  static const _enabledKey = "djTransitions";

  static bool _enabled = false;
  static Timer? _timer;
  static StreamSubscription<bool>? _playingSubscription;
  static final Map<String, TrackAnalysis?> _analysis = {};
  static String? _currentId;
  static DateTime? _trackStarted;

  static Future<bool> isEnabled() async => await SharedPreferencesAsync().getBool(_enabledKey) ?? false;

  static Future<void> setEnabled(bool enabled) async {
    await SharedPreferencesAsync().setBool(_enabledKey, enabled);
    _enabled = enabled;
    if (enabled) {
      _start();
    } else {
      _stop();
      await GetIt.instance<MusicPlayerBackgroundTask>().setTransitionVolume(1.0);
    }
  }

  /// Starts transitions if the user turned them on.
  static Future<void> initialize() async {
    _enabled = await isEnabled();
    if (_enabled) _start();
  }

  /// Ticks only while something is playing, so a paused player costs nothing.
  static void _start() {
    _stop();
    final player = GetIt.instance<MusicPlayerBackgroundTask>();
    // The player itself: held for the news, the playback state shows it playing while it stands still.
    _playingSubscription = player.playerPlaying.distinct().listen((playing) {
      _timer?.cancel();
      _timer = playing ? Timer.periodic(const Duration(milliseconds: 200), (_) => _tick()) : null;
    });
  }

  static void _stop() {
    unawaited(_playingSubscription?.cancel());
    _playingSubscription = null;
    _timer?.cancel();
    _timer = null;
  }

  /// Fade length for a track: 16 beats on the way out, 8 on the way in.
  static Duration _beats(String? id, int beats, {required Duration fallback, required Duration max}) {
    final bpm = _analysis[id]?.bpm;
    if (bpm == null || bpm <= 0) return fallback;
    final length = Duration(milliseconds: (60000 / bpm * beats).round());
    return length > max ? max : length;
  }

  static Future<void> _tick() async {
    // Crossfading handles the song changes itself.
    if (!_enabled || CrossfadeService.active) return;
    final player = GetIt.instance<MusicPlayerBackgroundTask>();
    final queue = GetIt.instance<QueueService>();
    final current = queue.getCurrentTrack();
    final duration = player.mediaItem.valueOrNull?.duration;
    if (current == null || duration == null || player.paused) return;

    final id = current.baseItemId.raw;
    final upcomingTrack = queue.getQueue();
    final incoming = upcomingTrack.nextUp.firstOrNull ?? upcomingTrack.queue.firstOrNull;
    final seconds = CrossfadeService.fadeSeconds(id, incoming?.baseItemId.raw, 12);
    if (seconds == 0) {
      await player.setTransitionVolume(1);
      return;
    }
    if (id != _currentId) {
      _currentId = id;
      _trackStarted = DateTime.now();
      final upcoming = queue.getQueue();
      final next = (upcoming.nextUp.firstOrNull ?? upcoming.queue.firstOrNull)?.baseItemId.raw;
      unawaited(_loadAnalysis([id, ?next]));
    }

    final position = player.playbackPosition;
    // The song's sound may end before the file does: fade out by then, and don't sit through a long silence.
    final cueEnd = songEnd(_analysis[id], duration);
    final remaining = cueEnd - position;
    if (remaining <= Duration.zero && duration - position > const Duration(seconds: 2) && _skippedSilenceOf != id) {
      _skippedSilenceOf = id;
      _logger.info("Skipping ${(duration - position).inSeconds} s of silence at the end of the song");
      await player.seek(duration, userInitiated: false);
      return;
    }
    final fadeOut = _beats(
      id,
      16,
      fallback: Duration(seconds: seconds.clamp(0, 6)),
      max: Duration(seconds: seconds),
    );
    final fadeIn = _beats(
      id,
      8,
      fallback: const Duration(seconds: 2),
      max: Duration(seconds: seconds.clamp(0, 5)),
    );

    double volume = 1.0;
    if (remaining < fadeOut && duration > fadeOut * 3) {
      volume = min(volume, _ease(remaining.inMilliseconds / fadeOut.inMilliseconds));
    }
    // Only fade in when the track started on its own, not after a seek.
    if (position < fadeIn && _trackStarted != null && DateTime.now().difference(_trackStarted!) < fadeIn * 2) {
      volume = min(volume, 0.25 + 0.75 * _ease(position.inMilliseconds / fadeIn.inMilliseconds));
    }
    await player.setTransitionVolume(volume);
  }

  static double _ease(double t) => sin(t.clamp(0.0, 1.0) * pi / 2);

  static String? _skippedSilenceOf;

  /// Where the song (of [duration] as it plays) really ends by its [analysis]: before trailing silence or a hidden
  /// track. The file's end when there's no analysis, or it doesn't fit this file.
  static Duration songEnd(TrackAnalysis? analysis, Duration duration) {
    final end = analysis?.end, measured = analysis?.duration;
    final seconds = duration.inMilliseconds / 1000;
    if (end == null || measured == null || (measured - seconds).abs() > 3 || end > seconds || end < seconds * 0.5) {
      return duration;
    }
    return Duration(milliseconds: (end * 1000).round());
  }

  static Future<void> _loadAnalysis(List<String> ids) async {
    final missing = ids.where((id) => !_analysis.containsKey(id)).toList();
    if (missing.isEmpty) return;
    try {
      final results = await AnalyzerService.analysis(missing);
      for (final id in missing) {
        _analysis[id] = results[id];
      }
    } catch (e) {
      _logger.fine("No analysis for transitions", e);
    }
  }

  /// Distance between two Camelot keys: 0 for the same key, 1 for neighbours (perfect mixes), more otherwise.
  static int camelotDistance(String a, String b) {
    final numberA = int.parse(a.substring(0, a.length - 1));
    final numberB = int.parse(b.substring(0, b.length - 1));
    final steps = min((numberA - numberB).abs(), 12 - (numberA - numberB).abs());
    final modeChange = a[a.length - 1] == b[b.length - 1] ? 0 : 1;
    return steps + modeChange;
  }

  /// How rough a transition from [from] to [to] is.
  static double transitionCost(TrackAnalysis? from, TrackAnalysis? to) {
    if (from == null || to == null) return 3;
    var cost = 0.0;
    if (from.camelot != null && to.camelot != null) cost += camelotDistance(from.camelot!, to.camelot!) * 1.5;
    if (from.bpm != null && to.bpm != null && from.bpm! > 0 && to.bpm! > 0) {
      // Half and double time mix fine too.
      final ratio = to.bpm! / from.bpm!;
      final difference = [ratio, ratio * 2, ratio / 2].map((r) => (log(r) / ln2).abs()).reduce(min);
      cost += difference * 12;
    }
    return cost;
  }

  /// [transitionCost] with each song's key and tempo worked out once, for orderings that compare many pairs (a long
  /// queue means millions). Gives the same answers.
  static double Function(TrackAnalysis? from, TrackAnalysis? to) cachedTransitionCost() {
    final features = Map<TrackAnalysis, ({int? key, String? mode, double? tempo})>.identity();
    ({int? key, String? mode, double? tempo}) of(TrackAnalysis analysis) => features.putIfAbsent(analysis, () {
      final camelot = analysis.camelot;
      final bpm = analysis.bpm;
      return (
        key: camelot == null ? null : int.parse(camelot.substring(0, camelot.length - 1)),
        mode: camelot == null ? null : camelot[camelot.length - 1],
        // In octaves, where half and double time are one apart.
        tempo: bpm != null && bpm > 0 ? log(bpm) / ln2 : null,
      );
    });
    return (from, to) {
      if (from == null || to == null) return 3;
      final a = of(from), b = of(to);
      var cost = 0.0;
      if (a.key != null && b.key != null) {
        final steps = (a.key! - b.key!).abs();
        cost += (min(steps, 12 - steps) + (a.mode == b.mode ? 0 : 1)) * 1.5;
      }
      if (a.tempo != null && b.tempo != null) {
        final octaves = b.tempo! - a.tempo!;
        cost += min(octaves.abs(), min((octaves + 1).abs(), (octaves - 1).abs())) * 12;
      }
      return cost;
    };
  }

  /// Reorders [tracks] so each one flows into the next, keeping the first track first,
  /// without the same artist twice in a row. With a harmonic [strength] (percent) each next song is one of the best
  /// matches, fewer the higher it is (see [harmonicOrder]); without, always the best.
  static Future<List<BaseItemDto>> smoothOrder(
    List<BaseItemDto> tracks, {
    bool allowArtistRepeats = false,
    int? strength,
  }) async {
    List<BaseItemDto> spaced(List<BaseItemDto> items) => allowArtistRepeats ? items : spreadArtists(items);
    if (tracks.length < 3 || !await AnalyzerService.isConfigured()) return spaced(tracks);
    // Reuses the last hour's answers, so a mix ordered right after its songs were looked up costs no extra request.
    final analysis = await AnalyzerService.cachedAnalysis([for (final track in tracks) track.id.raw]);
    if (analysis.length < tracks.length / 2) {
      _logger.info("Only ${analysis.length} of ${tracks.length} songs analysed, keeping the mix order");
      return spaced(tracks);
    }
    _analysis.addAll(analysis);
    TrackAnalysis? analysed(BaseItemDto track) => analysis[track.id.raw];
    if (strength == null) return spaced(await orderByCostAway(tracks, analysed));
    return spaced([
      tracks.first,
      ...await harmonicOrderAway(tracks.sublist(1), analysed, strength: strength, after: tracks.first),
    ]);
  }

  /// Moves tracks as little as possible so the same artist doesn't play twice in a row.
  /// Uses the track artist rather than the album artist, so compilations aren't one "Various Artists" block.
  static List<BaseItemDto> spreadArtists(List<BaseItemDto> tracks) => spreadOut(tracks, artistKey);

  /// [spreadArtists] for a mix whose first song may change too: a majority artist can lead when it has to. Keeping
  /// the first song can leave the same artist twice at the end, which the queue then drops, so the mix comes up
  /// short. Not for mixes that must start with a chosen song (a seed).
  static List<BaseItemDto> spreadArtistsFreely(List<BaseItemDto> tracks) =>
      ArtistSpacing.order(tracks, artistKey, keepFirst: false);

  /// The track's main artist for comparing, or null if it has none.
  static String? artistKey(BaseItemDto track) => ArtistSpacing.artistKey(track);

  /// Preserves the incoming order where possible without exhausting an artist's separators too early.
  static List<T> spreadOut<T>(List<T> items, Object? Function(T item) key) => ArtistSpacing.order(items, key);

  /// Orders [items] along an energy [shape], by each one's [intensity] (0 calm to 1 intense, from the analyzer).
  /// Items without one count as middling.
  static List<T> shapeOrder<T>(List<T> items, double? Function(T item) intensity, EnergyShape shape) {
    if (items.length < 3 || shape == EnergyShape.free) return items;
    final known = [for (final item in items) intensity(item)].nonNulls.toList()..sort();
    final middle = known.isEmpty ? 0.5 : known[known.length ~/ 2];
    double level(T item) => intensity(item) ?? middle;
    if (shape == EnergyShape.steady) {
      // No big jumps anywhere: up the energy ladder on every other rung and back down on the rest, a loop of small
      // steps, entered at its most typical song.
      final sorted = [...items]..sort((a, b) => level(a).compareTo(level(b)));
      final loop = [
        for (var i = 0; i < sorted.length; i += 2) sorted[i],
        for (var i = sorted.length - 1 - sorted.length % 2; i > 0; i -= 2) sorted[i],
      ];
      var entry = 0;
      for (var i = 1; i < loop.length; i++) {
        if ((level(loop[i]) - middle).abs() < (level(loop[entry]) - middle).abs()) entry = i;
      }
      return [...loop.skip(entry), ...loop.take(entry)];
    }
    // Each place in the mix gets a target energy; the calmest song goes to the calmest place, and so on.
    final last = items.length - 1;
    double target(int place) {
      final t = place / last;
      return switch (shape) {
        EnergyShape.build => t,
        EnergyShape.windDown => 1 - t,
        // Up to a peak about two thirds of the way in, then easing off, though not all the way down.
        EnergyShape.peak => t <= 0.68 ? t / 0.68 : 1 - (t - 0.68) / 0.32 * 0.55,
        // Two rises, each easing back down: calm, high, calm, high, calm.
        EnergyShape.wave => 0.5 - 0.5 * cos(t * 4 * pi),
        EnergyShape.steady || EnergyShape.free => 0.5,
      };
    }

    final places = List.generate(items.length, (place) => place)..sort((a, b) => target(a).compareTo(target(b)));
    final calmFirst = [...items]..sort((a, b) => level(a).compareTo(level(b)));
    final ordered = List<T?>.filled(items.length, null);
    for (final (rank, place) in places.indexed) {
      ordered[place] = calmFirst[rank];
    }
    return ordered.cast<T>();
  }

  /// From this many songs an ordering is worked out off the main thread: it compares each song with every one left,
  /// so a long mix would otherwise stall the screen for a moment. Fewer are quicker to order than to hand over.
  @visibleForTesting
  static const awayFrom = 500;

  /// [harmonicOrder] by key and tempo ([analysed], null for a song not analysed), worked out off the main thread
  /// when there are [awayFrom] or more. With [random] given, as in tests, it's worked out here, so the same seed gives
  /// the same order.
  static Future<List<T>> harmonicOrderAway<T>(
    List<T> items,
    TrackAnalysis? Function(T item) analysed, {
    required int strength,
    T? after,
    Random? random,
  }) async {
    final analyses = [for (final item in items) analysed(item)];
    final carryOn = after != null;
    final from = carryOn ? analysed(after as T) : null;
    final order = random != null || items.length < awayFrom
        ? _harmonicIndices(analyses, strength, from, carryOn, random)
        : await _away(() => _harmonicIndices(analyses, strength, from, carryOn, null));
    return [for (final index in order) items[index]];
  }

  /// [orderByCost] by key and tempo ([analysed]), worked out off the main thread when there are [awayFrom] or more.
  static Future<List<T>> orderByCostAway<T>(List<T> items, TrackAnalysis? Function(T item) analysed) async {
    final analyses = [for (final item in items) analysed(item)];
    final order = items.length < awayFrom ? _costIndices(analyses) : await _away(() => _costIndices(analyses));
    return [for (final index in order) items[index]];
  }

  /// Runs [work] on its own isolate, or here if one can't be started. Kept apart, so the work holds nothing but what
  /// it's given: only plain data can be sent.
  static Future<List<int>> _away(List<int> Function() work) async {
    try {
      return await Isolate.run(work);
    } catch (e) {
      _logger.warning("Couldn't order the mix in the background, ordering it here", e);
      return work();
    }
  }

  /// The order of [analyses] by [harmonicOrder], as their indices; carrying on from [from] when [carryOn].
  static List<int> _harmonicIndices(
    List<TrackAnalysis?> analyses,
    int strength,
    TrackAnalysis? from,
    bool carryOn,
    Random? random,
  ) {
    final cost = cachedTransitionCost();
    // -1 is the song carried on from.
    TrackAnalysis? of(int index) => index < 0 ? from : analyses[index];
    return harmonicOrder(
      [for (var index = 0; index < analyses.length; index++) index],
      (a, b) => cost(of(a), of(b)),
      known: (index) => analyses[index] != null,
      strength: strength,
      after: carryOn ? -1 : null,
      random: random,
    );
  }

  /// The order of [analyses] by [orderByCost], as their indices.
  static List<int> _costIndices(List<TrackAnalysis?> analyses) {
    final cost = cachedTransitionCost();
    return orderByCost([
      for (var index = 0; index < analyses.length; index++) index,
    ], (a, b) => cost(analyses[a], analyses[b]));
  }

  /// Greedy nearest-neighbour ordering, starting from the first item.
  static List<T> orderByCost<T>(List<T> items, double Function(T from, T to) cost) {
    final remaining = [...items.skip(1)];
    final ordered = [items.first];
    while (remaining.isNotEmpty) {
      var best = 0;
      var bestCost = cost(ordered.last, remaining.first);
      for (var i = 1; i < remaining.length; i++) {
        final step = cost(ordered.last, remaining[i]);
        if (step < bestCost) {
          best = i;
          bestCost = step;
        }
      }
      ordered.add(remaining.removeAt(best));
    }
    return ordered;
  }

  /// How long a harmonic shuffle waits for fresh analysis before ordering with what's already known.
  static const harmonicAnalysisWait = Duration(seconds: 5);

  /// [tracks] in a random order where each song flows into the next in key and tempo, for harmonic mixing.
  /// [strength] (percent) is the harmonic strength (see [harmonicOrder]). Null when too few of them have been analysed for it to work,
  /// so the caller shuffles as usual.
  static Future<List<BaseItemDto>?> harmonicShuffle(
    List<BaseItemDto> tracks, {
    required int strength,
    Random? random,
  }) async {
    if (tracks.length < 3 || !await AnalyzerService.isConfigured()) return null;
    final ids = [for (final track in tracks) track.id.raw];
    final analysis = await AnalyzerService.cachedAnalysis(
      ids,
    ).timeout(harmonicAnalysisWait, onTimeout: () => {for (final id in ids) id: ?AnalyzerService.cached(id)});
    if (analysis.length < tracks.length / 2) return null;
    _analysis.addAll(analysis);
    return spreadArtists(
      await harmonicOrderAway(tracks, (track) => analysis[track.id.raw], strength: strength, random: random),
    );
  }

  /// [items] reordered to carry on from [after] (the song playing) with each song flowing into the next in key and
  /// tempo, for turning harmonic order on for a queue that's already playing. [track] gives each item's song.
  /// Null when too few of them have been analysed for it to work.
  static Future<List<T>?> harmonicContinuation<T>(
    T after,
    List<T> items,
    BaseItemDto Function(T item) track, {
    required int strength,
    bool allowArtistRepeats = false,
    Random? random,
  }) async {
    if (items.length < 2 || !await AnalyzerService.isConfigured()) return null;
    // Looked up once each: the ordering compares every pair it considers, and [track] may be costly.
    final songs = {
      for (final item in [after, ...items]) item: track(item),
    };
    final ids = [for (final song in songs.values) song.id.raw];
    final analysis = await AnalyzerService.cachedAnalysis(
      ids,
    ).timeout(harmonicAnalysisWait, onTimeout: () => {for (final id in ids) id: ?AnalyzerService.cached(id)});
    TrackAnalysis? analysed(T item) => analysis[songs[item]!.id.raw];
    final known = items.where((item) => analysed(item) != null).length;
    if (known < items.length / 2) return null;
    _analysis.addAll(analysis);
    final ordered = await harmonicOrderAway(items, analysed, strength: strength, after: after, random: random);
    if (allowArtistRepeats) return ordered;
    Object? artist(T item) => artistKey(songs[item]!);
    return ArtistSpacing.order(ordered, artist, previousKey: artist(after), keepFirst: false);
  }

  /// A random walk through [items] where each step goes to one of the best fitting items by [cost], how many set by
  /// the harmonic [strength] (percent): always the best at 100%, any at 0%, and in between a share of the pool that
  /// stays about the same feel whatever its size (the pool's size to the power of 1 - strength: for 200 songs about 4
  /// at 75%, 14 at 50%). Items that aren't [known]
  /// (not analysed) are spread evenly through the walk, in random order. Starts from a random item, or carries on
  /// from [after] (not part of the result) when given.
  static List<T> harmonicOrder<T>(
    List<T> items,
    double Function(T from, T to) cost, {
    required bool Function(T item) known,
    required int strength,
    T? after,
    Random? random,
  }) {
    final dice = random ?? Random();
    final remaining = items.where(known).toList();
    final unknown = items.where((item) => !known(item)).toList()..shuffle(dice);
    if (remaining.isEmpty) return unknown;
    final choices = max(1, pow(remaining.length, 1 - strength.clamp(0, 100) / 100).round());
    final walk = [after ?? remaining.removeAt(dice.nextInt(remaining.length))];
    while (remaining.isNotEmpty) {
      final int next;
      if (choices >= remaining.length) {
        // Any of them may come next, so there's nothing to compare.
        next = dice.nextInt(remaining.length);
      } else if (choices == 1) {
        // The best, the first of equally good ones.
        var best = 0;
        var bestCost = cost(walk.last, remaining.first);
        for (var i = 1; i < remaining.length; i++) {
          final step = cost(walk.last, remaining[i]);
          if (step < bestCost) (best, bestCost) = (i, step);
        }
        next = best;
      } else {
        final steps = [for (final (index, item) in remaining.indexed) (index: index, cost: cost(walk.last, item))];
        _cheapestFirst(steps, choices);
        next = steps[dice.nextInt(choices)].index;
      }
      walk.add(remaining.removeAt(next));
    }
    if (after != null) walk.removeAt(0);
    final result = <T>[];
    var spread = 0;
    for (final (index, item) in walk.indexed) {
      result.add(item);
      while (spread < unknown.length && (spread + 1) * walk.length / (unknown.length + 1) <= index + 1) {
        result.add(unknown[spread++]);
      }
    }
    return [...result, ...unknown.skip(spread)];
  }

  /// Moves the [count] cheapest of [steps] to its start, in no particular order, without sorting the rest
  /// (quickselect), so picking among many of the best stays quick in a big pool.
  static void _cheapestFirst(List<({int index, double cost})> steps, int count) {
    final wanted = count - 1;
    var low = 0, high = steps.length - 1;
    while (low < high) {
      final pivot = steps[(low + high) >> 1].cost;
      var i = low, j = high;
      while (i <= j) {
        while (steps[i].cost < pivot) {
          i++;
        }
        while (steps[j].cost > pivot) {
          j--;
        }
        if (i <= j) {
          final swapped = steps[i];
          steps[i] = steps[j];
          steps[j] = swapped;
          i++;
          j--;
        }
      }
      if (wanted <= j) {
        high = j;
      } else if (wanted >= i) {
        low = i;
      } else {
        return;
      }
    }
  }

  /// Reorders each run of [size] neighbouring items so it flows best by [cost], counting the step in from the item
  /// before it, trying every order. Items only move within their run, so a shaped mix keeps its energy arc. Below
  /// full harmonic [strength] (percent) a run takes one of its best orders instead, more of them to choose from the
  /// lower it is (as in [harmonicOrder]), and any at 0%.
  static List<T> smoothWithinGroups<T>(
    List<T> items,
    double Function(T from, T to) cost, {
    int size = 4,
    int strength = 100,
    Random? random,
  }) {
    final dice = random ?? Random();
    final result = <T>[];
    for (var start = 0; start < items.length; start += size) {
      final orders = [
        for (final order in _permutations(items.sublist(start, min(start + size, items.length))))
          (order: order, total: _pathCost(order, cost, before: result.lastOrNull)),
      ];
      final choices = max(1, pow(orders.length, 1 - strength.clamp(0, 100) / 100).round());
      // Cheapest first; the first order tried is the current one, which wins ties.
      final ranked = [...orders.indexed]
        ..sort((a, b) {
          final total = a.$2.total.compareTo(b.$2.total);
          return total == 0 ? a.$1.compareTo(b.$1) : total;
        });
      result.addAll(ranked[choices == 1 ? 0 : dice.nextInt(min(choices, ranked.length))].$2.order);
    }
    return result;
  }

  static double _pathCost<T>(List<T> order, double Function(T from, T to) cost, {T? before}) {
    var total = before == null ? 0.0 : cost(before, order.first);
    for (var i = 1; i < order.length; i++) {
      total += cost(order[i - 1], order[i]);
    }
    return total;
  }

  static Iterable<List<T>> _permutations<T>(List<T> items) sync* {
    if (items.length <= 1) {
      yield items;
      return;
    }
    for (var i = 0; i < items.length; i++) {
      for (final tail in _permutations([...items.take(i), ...items.skip(i + 1)])) {
        yield [items[i], ...tail];
      }
    }
  }
}
