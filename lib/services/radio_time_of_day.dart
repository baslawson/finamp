import 'dart:math';

import 'package:finamp/services/listening_hour.dart';

/// A decayed skip in the current listening-hour band.
typedef TimedRadioSkip = ({String trackId, String? artist, double? energy, double weight});

/// Soft preferences only: even a poor match keeps a positive weight.
class RadioTimeOfDay {
  RadioTimeOfDay({required int hour, Iterable<TimedRadioSkip> skips = const []}) : band = listeningHour(hour) {
    for (final skip in skips) {
      if (!skip.weight.isFinite || skip.weight <= 0) continue;
      songs.update(skip.trackId, (value) => value + skip.weight, ifAbsent: () => skip.weight);
      final artist = artistKey(skip.artist);
      if (artist != null) artists.update(artist, (value) => value + skip.weight, ifAbsent: () => skip.weight);
      final energy = energyBand(skip.energy);
      if (energy != null) energies[energy] += skip.weight;
    }
  }

  final ListeningHour band;
  final songs = <String, double>{}, artists = <String, double>{};
  final energies = List<double>.filled(3, 0);

  static String? artistKey(String? artist) {
    final key = (artist ?? '')
        .toLowerCase()
        .replaceAll(RegExp(r'\s+(?:feat\.?|ft\.?|featuring)\s+.*$'), '')
        .replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');
    return key.isEmpty || const {'unknown', 'unknownartist', 'variousartists'}.contains(key) ? null : key;
  }

  /// Analyzer energy is RMS in dB; avoid treating it as a normalised intensity.
  static int? energyBand(double? energy) => energy == null || !energy.isFinite
      ? null
      : energy < -22
      ? 0
      : energy < -14
      ? 1
      : 2;

  double weight({required String trackId, String? artist, double? energy}) {
    final level = energyBand(energy);
    final bias = switch (band) {
      ListeningHour.night => -0.22,
      ListeningHour.morning => -0.16,
      ListeningHour.daytime => 0.0,
      ListeningHour.evening => 0.20,
    };
    final daily = level == null ? 1.0 : 1 + bias * (level - 1);
    final songSkips = songs[trackId] ?? 0;
    final artistSkips = artists[artistKey(artist)] ?? 0;
    // Generalise cautiously: many skips of one song should not suppress a whole artist or energy band.
    final energySkips = level == null ? 0.0 : energies[level];
    final learned = 1 / (1 + 0.35 * min(songSkips, 4) + 0.10 * min(artistSkips, 4) + 0.06 * min(energySkips, 4));
    return daily * learned;
  }
}
