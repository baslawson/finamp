import 'dart:async';
import 'dart:io';

import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:finamp/services/downloads_service.dart';
import 'package:finamp/services/finamp_user_helper.dart';
import 'package:finamp/services/headphone_eq_service.dart';
import 'package:finamp/services/loudness_cache.dart';
import 'package:finamp/services/loudness_normalization.dart';
import 'package:finamp/services/normalization_session.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get_it/get_it.dart';

class NormalizationDetailsDialog extends ConsumerStatefulWidget {
  const NormalizationDetailsDialog({super.key, required this.item});
  final BaseItemDto item;

  @override
  ConsumerState<NormalizationDetailsDialog> createState() => _NormalizationDetailsDialogState();
}

class _NormalizationDetailsDialogState extends ConsumerState<NormalizationDetailsDialog> {
  late final String _server;

  @override
  void initState() {
    super.initState();
    _server = GetIt.instance<FinampUserHelper>().currentUser?.serverId ?? '';
    unawaited(
      LoudnessCache.instance.load().then((_) {
        if (mounted) setState(() {});
      }),
    );
    unawaited(
      LoudnessCache.instance.fetch(_server, [
        widget.item.id.raw,
      ], offline: FinampSettingsHelper.finampSettings.isOffline),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(finampSettingsProvider).valueOrNull ?? FinampSettingsHelper.finampSettings;
    final queue = GetIt.instance<QueueService>();
    return StreamBuilder<FinampQueueItem?>(
      stream: queue.getCurrentTrackStream(),
      initialData: queue.getCurrentTrack(),
      builder: (context, currentState) => StreamBuilder<void>(
        stream: LoudnessCache.instance.changes.stream,
        builder: (context, _) {
          final current = currentState.data;
          final playing = current?.baseItem.id == widget.item.id;
          final downloaded =
              (playing && current?.item.extras?['downloadedTrackPath'] != null) ||
              (!playing &&
                  GetIt.instance.isRegistered<DownloadsService>() &&
                  GetIt.instance<DownloadsService>().getTrackDownload(item: widget.item) != null);
          final measured = LoudnessCache.instance.get(_server, widget.item.id.raw, downloaded: downloaded);
          final frozen = playing ? NormalizationSession.playback.get(_server, current!.item.id) : null;
          final album =
              settings.volumeNormalizationMode == VolumeNormalizationMode.albumBased ||
              settings.volumeNormalizationMode == VolumeNormalizationMode.albumOnly;
          final snapshot =
              frozen ??
              NormalizationSnapshot.calculate(
                enabled: settings.volumeNormalizationActive,
                album: album,
                level: LoudnessLevel.fromSetting(settings.normalizationLevel),
                headroomDb: HeadphoneEqService.headroomDb,
                measurement: measured,
                legacyGain: album ? widget.item.albumNormalizationGain : widget.item.normalizationGain,
                attenuationOnly: !Platform.isAndroid,
              );
          final needsAlbum = frozen?.usesAlbum ?? album;
          final ready =
              measured != null && (!needsAlbum || (measured.albumLufs != null && measured.albumTruePeak != null));
          return AlertDialog(
            title: Text(context.l10n.volumeNormalizationSettingsTitle),
            content: SingleChildScrollView(
              child: NormalizationDetailsContent(snapshot: snapshot, active: frozen != null, analysisReady: ready),
            ),
            actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(context.l10n.close))],
          );
        },
      ),
    );
  }
}

/// A description of the decision actually used, rather than a newly fetched gain.
class NormalizationDetailsContent extends StatelessWidget {
  const NormalizationDetailsContent({
    super.key,
    required this.snapshot,
    required this.active,
    required this.analysisReady,
  });
  final NormalizationSnapshot snapshot;
  final bool active;
  final bool analysisReady;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final status = switch (snapshot.source) {
      NormalizationSource.off => l10n.normalizationStatusOff,
      NormalizationSource.track => l10n.normalizationStatusTrack,
      NormalizationSource.album => l10n.normalizationStatusAlbum,
      NormalizationSource.fallback =>
        analysisReady && active ? l10n.normalizationReadyNextPlayback : l10n.normalizationAwaitingAnalysis,
    };
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(status, style: Theme.of(context).textTheme.titleMedium),
        if (snapshot.enabled) ...[
          const SizedBox(height: 12),
          Text(l10n.normalizationAppliedGain(l10n.numberAsDecibel(double.parse(snapshot.gainDb.toStringAsFixed(1))))),
        ],
        const SizedBox(height: 12),
        Text(active ? l10n.normalizationFixedForPlayback : l10n.normalizationPreviewDescription),
      ],
    );
  }
}
