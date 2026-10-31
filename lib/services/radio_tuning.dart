import 'dart:math';

import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/analyzer_service.dart';
import 'package:finamp/services/dj_transition_service.dart';
import 'package:finamp/services/skip_service.dart';
import 'package:finamp/services/shuffle_randomness.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:finamp/services/artist_spacing.dart';
import 'package:finamp/services/listening_hour.dart';
import 'package:finamp/services/radio_clock_settings.dart';
import 'package:finamp/services/radio_time_of_day.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// "Harmonic mixing for Radio", with the analyzer: radio strongly prefers songs in a compatible key and tempo, and
/// crossfades line the next song up with this song's bars (groups of four beats) rather than any beat. Smart Shuffle
/// and the Ai DJ have their own, separate switches ([menuEnabled]).
class HarmonicMixing {
  HarmonicMixing._();

  static const _key = 'harmonicMixing';
  static const _strengthKey = 'harmonicMixingStrength';

  /// How closely songs follow on in key and tempo with harmonic mixing, in percent, unless changed.
  static const defaultStrength = 75;

  /// "Harmonic strength", shared by Radio and every harmonic mix: at 100% each song is the best match for the one
  /// before, at 0% key and tempo don't count. Loaded at startup by [load] and kept up to date by [setStrength].
  static final strength = ValueNotifier<int>(defaultStrength);

  /// Read synchronously while mixing; loaded at startup and kept up to date by [setEnabled].
  static bool enabled = false;

  static Future<bool> load() async {
    try {
      final preferences = SharedPreferencesAsync();
      strength.value = (await preferences.getInt(_strengthKey) ?? defaultStrength).clamp(0, 100);
      return enabled = await preferences.getBool(_key) ?? false;
    } catch (_) {
      return enabled;
    }
  }

  static Future<void> setEnabled(bool value) async {
    enabled = value;
    await SharedPreferencesAsync().setBool(_key, value);
  }

  static Future<void> setStrength(int value) async {
    strength.value = value.clamp(0, 100);
    await SharedPreferencesAsync().setInt(_strengthKey, strength.value);
  }

  /// Whether a menu's own harmonic mixing switch is on, off until it's turned on. Separate from Radio's setting above.
  static Future<bool> menuEnabled(HarmonicMixingMenu menu) async {
    try {
      return await SharedPreferencesAsync().getBool(_menuKey(menu)) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> setMenuEnabled(HarmonicMixingMenu menu, bool value) =>
      SharedPreferencesAsync().setBool(_menuKey(menu), value);

  static String _menuKey(HarmonicMixingMenu menu) => '${_key}_${menu.name}';
}

/// Menus with their own harmonic mixing switch, which orders the songs they pick to flow in key and tempo.
enum HarmonicMixingMenu { smartShuffle, aiDj }

/// Orders radio candidates so often skipped songs come later, and, with the analyzer, so songs that sound like
/// the seed (tempo and key) come first. Still random, just weighted.
class RadioTuning {
  RadioTuning._();

  static final _logger = Logger("RadioTuning");

  /// How long to wait for fresh analysis before ordering with what's already cached.
  static const analysisWait = Duration(milliseconds: 1500);

  static Future<List<BaseItemDto>> order(
    BaseItemDto seed,
    List<BaseItemDto> candidates, {
    Random? random,
    DateTime Function()? now,
  }) async {
    final chance = await SkipService.chanceToPlay();
    final matchTime = await RadioClockSettings.load();
    final time = (now ?? DateTime.now)();
    final skips = matchTime ? (await SkipService.atHour(time)).take(100).toList() : <SkipRecord>[];
    Map<String, TrackAnalysis> analysis = const {};
    final ids = [seed.id.raw, for (final track in candidates) track.id.raw, for (final skip in skips) skip.trackId];
    try {
      if (await AnalyzerService.isConfigured()) {
        // A cold analysis can take a while. Rather than lose all tuning (skips included), use what's already known;
        // the request carries on and fills the cache for the next refill.
        analysis = await AnalyzerService.analysis(
          ids,
        ).timeout(analysisWait, onTimeout: () => {for (final id in ids) id: ?AnalyzerService.cached(id)});
      }
    } catch (e) {
      _logger.fine("No analysis for radio tuning", e);
    }
    final seedAnalysis = analysis[seed.id.raw];
    final harmonic = HarmonicMixing.enabled;
    final strictness = harmonic ? harmonicStrictness(HarmonicMixing.strength.value) : 0.25;
    final clock = RadioTimeOfDay(
      hour: time.hour,
      skips: [
        for (final skip in skips)
          (
            trackId: skip.trackId,
            // The same identity candidates are judged by; older skips only know the name shown.
            artist: skip.artistKey ?? skip.artist,
            energy: analysis[skip.trackId]?.energy,
            weight: skip.hourWeight(listeningHour(time.hour), time),
          ),
      ],
    );
    double weight(BaseItemDto track) {
      var weight = chance(track.id.raw);
      final trackAnalysis = analysis[track.id.raw];
      if (seedAnalysis != null && trackAnalysis != null) {
        weight /= 1 + DjTransitionService.transitionCost(seedAnalysis, trackAnalysis) * strictness;
      }
      if (matchTime) {
        weight *= clock.weight(
          trackId: track.id.raw,
          artist: ArtistSpacing.artistKey(track),
          energy: trackAnalysis?.energy,
        );
      }
      return weight;
    }

    return weightedShuffle(
      candidates,
      weight,
      randomness: FinampSettingsHelper.finampSettings.shuffleRandomness,
      // With harmonic mixing even a fully random order leans towards songs in a matching key and tempo, unless the
      // strength is 0%, which is the same as harmonic mixing off.
      weightedRandom: matchTime || (harmonic && HarmonicMixing.strength.value > 0),
      random: random,
    );
  }

  /// How much a clash in key or tempo counts with harmonic mixing at [strength] (percent): as little as without it at
  /// 0%, four times as much at the default 75%, and more above.
  static double harmonicStrictness(int strength) =>
      0.25 * pow(4, strength.clamp(0, 100) / HarmonicMixing.defaultStrength).toDouble();

  static List<T> rankByWeight<T>(List<T> items, double Function(T item) weight) {
    final keyed = [for (final (index, item) in items.indexed) (item: item, index: index, weight: weight(item))]
      ..sort((a, b) {
        final score = b.weight.compareTo(a.weight);
        return score == 0 ? a.index.compareTo(b.index) : score;
      });
    return [for (final entry in keyed) entry.item];
  }

  /// Low randomness follows the suitability ranking; 100% uses a random order, or with [weightedRandom] a random order
  /// in which heavier items tend to come first.
  static List<T> weightedShuffle<T>(
    List<T> items,
    double Function(T item) weight, {
    Random? random,
    int randomness = DefaultSettings.shuffleRandomness,
    bool weightedRandom = false,
  }) {
    final ranked = rankByWeight(items, weight);
    if (!weightedRandom) return ShuffleRandomness.order(ranked, randomness, random: random);
    final amount = randomness.clamp(0, 100) / 100;
    if (amount == 0 || ranked.length < 2) return ranked;
    final dice = random ?? Random();
    // A weighted random order (each item's key is a random number to the power of 1 / weight, highest first), blended
    // with the ranking the way the shared randomizer blends in a plain random order.
    final drawn = [
      for (final (index, item) in ranked.indexed)
        (index: index, key: pow(dice.nextDouble(), 1 / max(weight(item), 1e-9)).toDouble()),
    ]..sort((a, b) => b.key.compareTo(a.key));
    final place = List.filled(ranked.length, 0);
    for (final (position, entry) in drawn.indexed) {
      place[entry.index] = position;
    }
    final last = ranked.length - 1;
    final scored =
        [
          for (var index = 0; index < ranked.length; index++)
            (index: index, score: (1 - amount) * index / last + amount * place[index] / last),
        ]..sort((a, b) {
          final score = a.score.compareTo(b.score);
          return score == 0 ? a.index.compareTo(b.index) : score;
        });
    return [for (final entry in scored) ranked[entry.index]];
  }
}
