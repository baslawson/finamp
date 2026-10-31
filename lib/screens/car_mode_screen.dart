import 'package:audio_service/audio_service.dart';
import 'package:finamp/components/album_image.dart';
import 'package:finamp/components/favorite_button.dart';
import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/services/current_track_metadata_provider.dart';
import 'package:finamp/services/music_player_background_task.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

/// A simple player with big buttons that are easy to hit while driving.
class CarModeScreen extends ConsumerWidget {
  const CarModeScreen({super.key});

  static const routeName = "/carmode";

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = GetIt.instance<MusicPlayerBackgroundTask>();
    final track = ref.watch(currentTrackProvider).valueOrNull?.baseItem;
    final colors = Theme.of(context).colorScheme;
    final landscape = MediaQuery.orientationOf(context) == Orientation.landscape;

    Widget button(IconData icon, String label, VoidCallback onPressed, {bool primary = false}) => Expanded(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Semantics(
          label: label,
          button: true,
          child: primary
              ? FilledButton(
                  onPressed: () {
                    HapticFeedback.mediumImpact();
                    onPressed();
                  },
                  style: FilledButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24))),
                  child: Icon(icon, size: 72),
                )
              : FilledButton.tonal(
                  onPressed: () {
                    HapticFeedback.mediumImpact();
                    onPressed();
                  },
                  style: FilledButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24))),
                  child: Icon(icon, size: 56),
                ),
        ),
      ),
    );

    final info = Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          track?.name ?? context.l10n.carModeNothingPlaying,
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          track?.albumArtist ?? track?.artists?.firstOrNull ?? "",
          style: Theme.of(context).textTheme.titleLarge?.copyWith(color: colors.onSurfaceVariant),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
        ),
      ],
    );

    final controls = StreamBuilder<PlaybackState>(
      stream: player.playbackState,
      builder: (context, snapshot) {
        final playing = snapshot.data?.playing ?? false;
        return Row(
          children: [
            button(TablerIcons.player_skip_back, context.l10n.skipToPreviousTrackButtonTooltip, player.skipToPrevious),
            button(
              playing ? TablerIcons.player_pause : TablerIcons.player_play,
              context.l10n.togglePlaybackButtonTooltip,
              player.togglePlayback,
              primary: true,
            ),
            button(TablerIcons.player_skip_forward, context.l10n.skipToNextTrackButtonTooltip, player.skipToNext),
          ],
        );
      },
    );

    final art = track == null
        ? const SizedBox.shrink()
        : AspectRatio(
            aspectRatio: 1,
            child: AlbumImage(item: track, borderRadius: BorderRadius.circular(16)),
          );

    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.carMode),
        actions: [if (track != null) FavoriteButton(item: track, size: 40)],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: landscape
              ? Row(
                  children: [
                    art,
                    const SizedBox(width: 24),
                    Expanded(
                      child: Column(
                        children: [
                          Expanded(child: info),
                          SizedBox(height: 180, child: controls),
                        ],
                      ),
                    ),
                  ],
                )
              : Column(
                  children: [
                    Flexible(child: art),
                    const SizedBox(height: 16),
                    info,
                    const SizedBox(height: 16),
                    SizedBox(height: 200, child: controls),
                  ],
                ),
        ),
      ),
    );
  }
}
