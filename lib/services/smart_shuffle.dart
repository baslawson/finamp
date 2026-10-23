import 'package:finamp/components/mix_length_chips.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/artist_spacing.dart';

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
