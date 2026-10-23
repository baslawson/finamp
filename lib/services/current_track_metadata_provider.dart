import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:finamp/services/lrclib_service.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get_it/get_it.dart';

import 'metadata_provider.dart';

/// Provider to handle pre-fetching metadata for upcoming tracks
final currentTrackMetadataProvider = AutoDisposeProvider<AsyncValue<MetadataProvider?>>((ref) {
  final List<FinampQueueItem> precacheItems = GetIt.instance<QueueService>().peekQueue(
    next: 3,
    previous: 1,
    current: true,
  );
  for (final itemToPrecache in precacheItems) {
    BaseItemDto? base = itemToPrecache.baseItem;
    ref.listen(metadataProvider(base), (_, _) {});
    ref.read(
      metadataProvider(base),
    ); // forces it even in background https://github.com/rrousselGit/riverpod/issues/2671
  }

  final currentTrack = ref.watch(currentTrackProvider).value;
  if (currentTrack?.baseItem == null) return const AsyncValue.data(null);
  final metadata = ref.watch(metadataProvider(currentTrack!.baseItem));

  // Fall back to LRCLIB when the server has no lyrics (or failed to give them), online only.
  final value = metadata.valueOrNull;
  if (value == null || value.lyrics != null || ref.watch(finampSettingsProvider.isOffline)) return metadata;
  return switch (ref.watch(lrclibLyricsProvider(value.item))) {
    AsyncData(value: final lyrics?) => AsyncValue.data(value.withLyrics(lyrics)),
    AsyncLoading() => const AsyncLoading<MetadataProvider?>().copyWithPrevious(metadata),
    _ => metadata,
  };
});

final currentTrackProvider = StreamProvider((_) => GetIt.instance<QueueService>().getCurrentTrackStream());
