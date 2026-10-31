import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:finamp/services/lrclib_service.dart';
import 'package:finamp/services/lyrics_timeline.dart';
import 'package:finamp/services/music_player_background_task.dart';
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
  // A remix (a mashup) plays under the original song's item, with its own title and length.
  final remix = LyricsTimeline.of(currentTrack);

  // Fall back to LRCLIB when the server has no lyrics (or failed to give them), online only.
  final value = metadata.valueOrNull;
  final AsyncValue<MetadataProvider?> found;
  if (value == null || value.lyrics != null || ref.watch(finampSettingsProvider.isOffline)) {
    found = metadata;
  } else {
    found = switch (ref.watch(lrclibLyricsProvider(remix?.original(value.item) ?? value.item))) {
      AsyncData(value: final lyrics?) => AsyncValue.data(value.withLyrics(lyrics)),
      AsyncLoading() => const AsyncLoading<MetadataProvider?>().copyWithPrevious(metadata),
      _ => metadata,
    };
  }
  if (remix == null) return found;
  // Its lyrics move with the singing, but only while its own audio plays rather than another karaoke mix.
  ref.watch(karaokeMixChangesProvider);
  final player = GetIt.instance<MusicPlayerBackgroundTask>();
  final timeline = LyricsTimeline.playing(currentTrack, player.karaokeMixPathFor(currentTrack));
  if (timeline == null) return found;
  // Also while loading, so the original timings never show for a moment.
  return found.whenData(
    (value) => value?.lyrics == null ? value : value!.withLyrics(timeline.apply(value.lyrics!), original: value.lyrics),
  );
});

/// Ticks when the karaoke mix a queue entry plays may have changed.
final karaokeMixChangesProvider = StreamProvider.autoDispose(
  (_) => GetIt.instance<MusicPlayerBackgroundTask>().karaokeMixChanges,
);

final currentTrackProvider = StreamProvider((_) => GetIt.instance<QueueService>().getCurrentTrackStream());
