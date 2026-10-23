import 'dart:math';

import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/analyzer_service.dart';
import 'package:finamp/services/dj_transition_service.dart';
import 'package:finamp/services/skip_service.dart';
import 'package:finamp/services/shuffle_randomness.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// "Harmonic mixing for Radio", with the analyzer: radio strongly prefers songs in a compatible key and tempo, and
/// crossfades line the next song up with this song's bars (groups of four beats) rather than any beat. Smart Shuffle
/// and the Ai DJ have their own, separate switches ([menuEnabled]).
class HarmonicMixing {
  HarmonicMixing._();

  static const _key = 'harmonicMixing';

  /// Read synchronously while mixing; loaded at startup and kept up to date by [setEnabled].
  static bool enabled = false;

  static Future<bool> load() async {
    try {
      return enabled = await SharedPreferencesAsync().getBool(_key) ?? false;
    } catch (_) {
      return enabled;
    }
  }

  static Future<void> setEnabled(bool value) async {
    enabled = value;
    await SharedPreferencesAsync().setBool(_key, value);
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

  static Future<List<BaseItemDto>> order(BaseItemDto seed, List<BaseItemDto> candidates, {Random? random}) async {
    final chance = await SkipService.chanceToPlay();
    Map<String, TrackAnalysis> analysis = const {};
    final ids = [seed.id.raw, for (final track in candidates) track.id.raw];
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
    // Harmonic mixing makes a clash in key or tempo count four times as much.
    final strictness = HarmonicMixing.enabled ? 1.0 : 0.25;
    double weight(BaseItemDto track) {
      var weight = chance(track.id.raw);
      final trackAnalysis = analysis[track.id.raw];
      if (seedAnalysis != null && trackAnalysis != null) {
        weight /= 1 + DjTransitionService.transitionCost(seedAnalysis, trackAnalysis) * strictness;
      }
      return weight;
    }

    return weightedShuffle(
      candidates,
      weight,
      randomness: FinampSettingsHelper.finampSettings.shuffleRandomness,
      random: random,
    );
  }

  static List<T> rankByWeight<T>(List<T> items, double Function(T item) weight) {
    final keyed = [for (final (index, item) in items.indexed) (item: item, index: index, weight: weight(item))]
      ..sort((a, b) {
        final score = b.weight.compareTo(a.weight);
        return score == 0 ? a.index.compareTo(b.index) : score;
      });
    return [for (final entry in keyed) entry.item];
  }

  /// Low randomness follows the suitability ranking; 100% uses a random order.
  static List<T> weightedShuffle<T>(
    List<T> items,
    double Function(T item) weight, {
    Random? random,
    int randomness = DefaultSettings.shuffleRandomness,
  }) => ShuffleRandomness.order(rankByWeight(items, weight), randomness, random: random);
}
