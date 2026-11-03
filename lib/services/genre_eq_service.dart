import 'dart:async';

import 'package:finamp/services/headphone_eq_service.dart';
import 'package:finamp/services/music_player_background_task.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A sound for a kind of music, as (frequency Hz, gain dB) points. The EQ keeps the overall loudness the same, so
/// these shape the balance rather than turning things up.
enum GenreEqPreset {
  flat([], []),
  rock(["rock", "punk", "grunge", "alternative", "indie"], [4, 2, -1, -1, 1, 3, 3]),
  metal(["metal", "hardcore", "thrash", "doom"], [4, 3, -2, 0, 2, 3, 2]),
  pop(["pop", "disco", "schlager", "k-pop", "j-pop"], [-1, 1, 2, 2, 1, 1, 0]),
  hipHop(["hip hop", "hip-hop", "hiphop", "rap", "trap", "r&b", "rnb", "grime"], [5, 4, 1, 0, 0, 1, 2]),
  electronic(
    ["electro", "dance", "house", "techno", "trance", "edm", "dubstep", "drum", "garage", "synth"],
    [5, 3, 0, -1, 1, 2, 4],
  ),
  jazz(["jazz", "blues", "soul", "funk", "swing"], [2, 1, 0, 1, 1, 2, 2]),
  classical(["classical", "orchestra", "symphon", "opera", "baroque", "soundtrack", "score"], [1, 0, 0, 0, 0, 1, 2]),
  acoustic(["acoustic", "folk", "country", "singer", "bluegrass", "americana"], [1, 1, 1, 0, 1, 2, 2]),
  spoken(["spoken", "podcast", "audiobook", "comedy", "speech"], [-4, -2, 1, 3, 3, 1, -2]);

  const GenreEqPreset(this.keywords, this.gains);

  /// Words in a genre name that pick this preset.
  final List<String> keywords;

  /// Gains at [GenreEqService.frequencies].
  final List<double> gains;

  List<(double, double)> get curve => [
    for (final (index, gain) in gains.indexed) (GenreEqService.frequencies[index], gain),
  ];
}

/// Switches the equalizer to suit each song's genre: more bass for hip-hop, clearer voices for podcasts, and so on.
/// It works on top of a headphone correction.
class GenreEqService {
  GenreEqService._();

  static final _logger = Logger("GenreEqService");
  static const _enabledKey = "genreEqEnabled";
  static const frequencies = [60.0, 150.0, 400.0, 1000.0, 2400.0, 6000.0, 15000.0];

  static bool _enabled = false;
  static bool get enabled => _enabled;
  static StreamSubscription<String?>? _subscription;

  /// The preset in use for the current song.
  static final current = BehaviorSubject<GenreEqPreset>.seeded(GenreEqPreset.flat);

  /// The preset for a song with [genres]: the first genre with a match wins, so the main genre counts most.
  static GenreEqPreset presetFor(List<String> genres) {
    for (final genre in genres) {
      final preset = _presetForGenre(genre.toLowerCase());
      if (preset != null) return preset;
    }
    return GenreEqPreset.flat;
  }

  /// Words that make a style gentle whatever else it names, as in "Soft Rock" or "Indie Folk".
  static const _gentle = ["soft", "acoustic", "unplugged", "ballad", "easy listening", "mellow", "folk", "singer"];

  /// Words that keep a style loud even with a gentle word, as in "Folk Metal".
  static const _loud = ["metal", "punk", "hardcore", "grunge"];

  /// The preset for one genre [name] (lower case), or null if it names no style. A compound genre is what its last
  /// style word says ("Indie Pop" is pop, "Alternative R&B" is R&B, "Synthpop" is pop), unless a gentle word makes it
  /// acoustic.
  static GenreEqPreset? _presetForGenre(String name) {
    if (_gentle.any(name.contains) && !_loud.any(name.contains)) return GenreEqPreset.acoustic;
    GenreEqPreset? best;
    var bestAt = -1, bestLength = 0;
    for (final preset in GenreEqPreset.values) {
      for (final keyword in preset.keywords) {
        final at = name.lastIndexOf(keyword);
        if (at > bestAt || (at == bestAt && at >= 0 && keyword.length > bestLength)) {
          (best, bestAt, bestLength) = (preset, at, keyword.length);
        }
      }
    }
    return bestAt < 0 ? null : best;
  }

  static Future<void> initialize() async {
    _enabled = await SharedPreferencesAsync().getBool(_enabledKey) ?? false;
    if (_enabled) _start();
  }

  static Future<void> setEnabled(bool enabled) async {
    await SharedPreferencesAsync().setBool(_enabledKey, enabled);
    _enabled = enabled;
    if (enabled) {
      _start();
    } else {
      await _subscription?.cancel();
      _subscription = null;
      await _use(GenreEqPreset.flat);
    }
  }

  static void _start() {
    if (_subscription != null) return;
    final player = GetIt.instance<MusicPlayerBackgroundTask>();
    _subscription = player.mediaItem.map((item) => item?.id).distinct().listen((_) {
      final json = player.mediaItem.valueOrNull?.extras?["itemJson"];
      final genres = json is Map ? (json["Genres"] as List?)?.cast<String>() ?? const <String>[] : const <String>[];
      unawaited(_use(presetFor(genres)));
    });
  }

  static Future<void> _use(GenreEqPreset preset) async {
    if (preset == current.value) return;
    current.add(preset);
    HeadphoneEqService.extraCurve = preset.curve;
    final equalizer = GetIt.instance<MusicPlayerBackgroundTask>().equalizer;
    if (equalizer == null) return;
    try {
      await HeadphoneEqService.refresh(equalizer);
      _logger.info("Genre EQ: ${preset.name}");
    } catch (e) {
      _logger.warning("Couldn't apply the genre EQ", e);
    }
  }
}
