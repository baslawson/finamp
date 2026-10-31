import 'dart:io';
import 'dart:ui' as ui;

import 'package:finamp/components/album_image.dart';
import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/current_track_metadata_provider.dart';
import 'package:finamp/services/music_player_background_task.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// The synced lyric line playing right now, if [item] is the current track.
String? currentLyricLine(BaseItemDto item) {
  final metadata = GetIt.instance<ProviderContainer>().read(currentTrackMetadataProvider).valueOrNull;
  final lines = metadata?.item.id == item.id ? metadata?.lyrics?.lyrics : null;
  if (lines == null || lines.isEmpty || lines.first.start == null) return null;
  // Lyric start times are in ticks of 100 ns.
  final ticks = GetIt.instance<MusicPlayerBackgroundTask>().playbackPosition.inMicroseconds * 10;
  final line = lines.lastWhere((line) => (line.start ?? 0) <= ticks, orElse: () => lines.first).text?.trim();
  return line == null || line.isEmpty ? null : line;
}

/// Shows a preview of a shareable "now playing" image for [item] and shares it as a PNG.
Future<void> showShareCard(BuildContext context, BaseItemDto item, {String? lyric}) {
  return showDialog<void>(
    context: context,
    builder: (context) => _ShareCardDialog(item: item, lyric: lyric),
  );
}

class _ShareCardDialog extends StatefulWidget {
  const _ShareCardDialog({required this.item, this.lyric});

  final BaseItemDto item;
  final String? lyric;

  @override
  State<_ShareCardDialog> createState() => _ShareCardDialogState();
}

class _ShareCardDialogState extends State<_ShareCardDialog> {
  final _boundary = GlobalKey();
  late bool _showLyric = widget.lyric != null;
  bool _sharing = false;

  static const _cardWidth = 300.0;
  static const _outputWidth = 1080.0;

  Future<void> _share() async {
    setState(() => _sharing = true);
    try {
      final boundary = _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: _outputWidth / _cardWidth);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File("${(await getTemporaryDirectory()).path}/finamp-plus-now-playing.png");
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      final artist = widget.item.albumArtist ?? widget.item.artists?.firstOrNull;
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: "image/png")],
          text: [widget.item.name, artist].nonNulls.join(" – "),
        ),
      );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      GlobalSnackbar.error(e);
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      contentPadding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          RepaintBoundary(
            key: _boundary,
            child: _ShareCard(item: widget.item, lyric: _showLyric ? widget.lyric : null, width: _cardWidth),
          ),
          if (widget.lyric != null)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(context.l10n.shareCardIncludeLyric),
              value: _showLyric,
              onChanged: (show) => setState(() => _showLyric = show),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        FilledButton.icon(
          onPressed: _sharing ? null : _share,
          icon: const Icon(TablerIcons.share),
          label: Text(context.l10n.shareCardShare),
        ),
      ],
    );
  }
}

class _ShareCard extends StatelessWidget {
  const _ShareCard({required this.item, required this.lyric, required this.width});

  final BaseItemDto item;
  final String? lyric;
  final double width;

  @override
  Widget build(BuildContext context) {
    const white = Colors.white;
    final artist = item.albumArtist ?? item.artists?.firstOrNull;
    return SizedBox(
      width: width,
      height: width * 1.25,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // A blurred, darkened copy of the cover as the background.
            ImageFiltered(
              imageFilter: ui.ImageFilter.blur(sigmaX: 30, sigmaY: 30, tileMode: TileMode.mirror),
              child: AlbumImage(item: item, borderRadius: BorderRadius.zero),
            ),
            const ColoredBox(color: Color(0x88000000)),
            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: SizedBox.square(
                      dimension: width * 0.62,
                      child: AlbumImage(item: item, borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    item.name ?? "",
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: white, fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  if (artist != null)
                    Text(
                      artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Color(0xDDFFFFFF), fontSize: 15),
                    ),
                  if (lyric != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      "“$lyric”",
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: white, fontSize: 14, fontStyle: FontStyle.italic),
                    ),
                  ],
                  const Spacer(),
                  const Row(
                    children: [
                      Icon(TablerIcons.music, color: Color(0xAAFFFFFF), size: 14),
                      SizedBox(width: 4),
                      Text("Finamp+", style: TextStyle(color: Color(0xAAFFFFFF), fontSize: 12)),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
