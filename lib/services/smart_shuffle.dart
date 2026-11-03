import 'dart:math';

import 'package:finamp/components/mix_length_chips.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/artist_spacing.dart';
import 'package:finamp/services/dj_transition_service.dart';

/// Spaces the full cleaned pool before counting the songs that fill the mix.
List<BaseItemDto> prepareSmartShuffle(
  List<BaseItemDto> tracks,
  QueueItemSource source, {
  int? minutes,
  bool harmonic = false,
}) {
  final prepared = ArtistSpacing.prepareStart(tracks, source, startingIndex: harmonic ? 0 : null);
  // A spaced prefix stays feasible when the queue sorts it again for shuffled playback.
  return fillMixLength(prepared.items, minutes);
}

/// A Smart Shuffle along an energy [shape]. The songs that fill the mix are chosen first, spaced by artist from the
/// pool's random order like any Smart Shuffle, so the shape runs across the songs that play. They're then put along
/// the shape by [intensity] (from the analyzer), smoothed in key and tempo within it by [cost] at the harmonic
/// [strength] when given, and spaced by artist again, which may move a song or two off the shape. Null when fewer than half the chosen songs are measured, so the
/// caller shuffles as usual.
List<BaseItemDto>? shapeSmartShuffle(
  List<BaseItemDto> tracks,
  QueueItemSource source, {
  required EnergyShape shape,
  required double? Function(BaseItemDto track) intensity,
  int? minutes,
  double Function(BaseItemDto from, BaseItemDto to)? cost,
  int strength = 100,
  Random? random,
}) {
  // Spaced without keeping the pool's first song first, which may be an artist the rest can't be spaced around:
  // the shape decides the order afterwards anyway.
  final chosen = prepareSmartShuffle(tracks, source, minutes: minutes);
  if (chosen.length < 3 || chosen.where((track) => intensity(track) != null).length < chosen.length / 2) return null;
  var shaped = DjTransitionService.shapeOrder(chosen, intensity, shape);
  // At 0% harmonic strength key and tempo don't count, so the energy shape stands as it is.
  if (cost != null && strength > 0) {
    shaped = DjTransitionService.smoothWithinGroups(shaped, cost, strength: strength, random: random);
  }
  return DjTransitionService.spreadArtistsFreely(shaped);
}
