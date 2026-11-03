import 'dart:async';
import 'dart:math';

import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/analyzer_service.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:finamp/services/mix_export_actions.dart';
import 'package:finamp/services/mix_map.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

/// The song playing and what's coming up, drawn as a mix: energy and tempo along the way, and how each song follows
/// on in key and tempo, with a way to smooth out each clash.
class MixMapScreen extends StatefulWidget {
  const MixMapScreen({super.key});

  static const routeName = "/mixmap";

  /// How many songs are drawn: the one playing and the next ones.
  static const songCount = 100;

  @override
  State<MixMapScreen> createState() => _MixMapScreenState();
}

class _MixMapScreenState extends State<MixMapScreen> {
  final _queueService = GetIt.instance<QueueService>();
  StreamSubscription<FinampQueueInfo?>? _subscription;
  List<FinampQueueItem> _songs = [];

  /// Whether the first song drawn is the one playing, which moves count from. Without it nothing is moved.
  bool _playing = false;

  /// Where the main queue starts among the songs drawn, after the one playing and Next Up. Only songs from there on
  /// are moved, so they stay in the main queue.
  int _firstMovable = 1;

  /// Counts loads, so a slow one doesn't replace a newer queue.
  int _generation = 0;

  /// While the queue has changed since the songs drawn were loaded.
  bool _stale = false;
  Map<String, TrackAnalysis> _analysis = {};
  bool _loading = true;
  bool _moving = false;

  @override
  void initState() {
    super.initState();
    _load(_queueService.getQueue());
    _subscription = _queueService.getQueueStream().listen((queue) {
      if (queue != null) _load(queue);
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  Future<void> _load(FinampQueueInfo queue) async {
    final generation = ++_generation;
    // No moves are offered from the old order while the new one's analysis loads.
    if (mounted && !_stale) setState(() => _stale = true);
    // One more than drawn, so moving the last song drawn counts the song really after it.
    final songs = [?queue.currentTrack, ...queue.nextUp, ...queue.queue].take(MixMapScreen.songCount + 1).toList();
    final analysis = await AnalyzerService.cachedAnalysis([for (final song in songs) song.baseItem.id.raw]);
    if (!mounted || generation != _generation) return;
    setState(() {
      _songs = songs;
      _stale = false;
      _playing = queue.currentTrack != null;
      _firstMovable = 1 + queue.nextUp.length;
      _analysis = analysis;
      _loading = false;
    });
  }

  TrackAnalysis? _of(FinampQueueItem song) => _analysis[song.baseItem.id.raw];

  Future<void> _fix(MixFix fix) async {
    final moved = _songs[fix.from].baseItem.name ?? "";
    // Only if the queue is still as drawn, so the offsets point at the songs meant.
    final queue = _queueService.getQueue();
    final now = [?queue.currentTrack, ...queue.nextUp, ...queue.queue];
    if (_stale ||
        queue.currentTrack == null ||
        !MixMap.stillApplies(
          fix,
          drawn: [for (final song in _songs) song.id],
          drawnFirstMovable: _firstMovable,
          now: [for (final song in now) song.id],
          nowFirstMovable: 1 + queue.nextUp.length,
        )) {
      return _load(queue);
    }
    setState(() => _moving = true);
    try {
      // Offsets count from the song playing (0), which is the first song drawn.
      await _queueService.reorderByOffset(fix.from, fix.to);
      GlobalSnackbar.message((context) => context.l10n.mixMapFixed(moved), isConfirmation: true);
    } catch (e) {
      GlobalSnackbar.error(e);
    } finally {
      if (mounted) setState(() => _moving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    // All loaded, including the one past the songs drawn, which only counts towards moves.
    final analyses = [for (final song in _songs) _of(song)];
    final shown = min(_songs.length, MixMapScreen.songCount);
    final grades = [for (var i = 0; i + 1 < shown; i++) MixMap.grade(analyses[i], analyses[i + 1])];
    // Saved and exported in full, not only the songs drawn.
    List<BaseItemDto> mix() {
      final queue = _queueService.getQueue();
      return [
        for (final song in [?queue.currentTrack, ...queue.nextUp, ...queue.queue]) song.baseItem,
      ];
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.mixMap),
        actions: [
          IconButton(
            icon: const Icon(TablerIcons.playlist_add),
            tooltip: l10n.saveMixAsPlaylist,
            // Playlists live on the server.
            onPressed: _songs.isEmpty || FinampSettingsHelper.finampSettings.isOffline
                ? null
                : () => saveMixAsPlaylist(context, mix()),
          ),
          Builder(
            builder: (context) => IconButton(
              icon: const Icon(TablerIcons.file_export),
              tooltip: l10n.exportMixM3u,
              onPressed: _songs.isEmpty
                  ? null
                  : () => exportMixM3u(
                      mix(),
                      _queueService.getQueue().source.name.getLocalized(l10n),
                      origin: shareOriginOf(context),
                    ),
            ),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _songs.isEmpty
          ? Center(child: Text(l10n.mixMapEmpty))
          : ListView.builder(
              padding: const EdgeInsets.only(bottom: 24),
              itemCount: shown + 1,
              itemBuilder: (context, index) {
                if (index == 0) return _header(context, analyses.take(shown).toList(), grades);
                final i = index - 1;
                return Column(
                  children: [
                    _SongRow(song: _songs[i].baseItem, analysis: analyses[i], playing: _playing && i == 0),
                    if (i < grades.length)
                      _TransitionRow(
                        grade: grades[i],
                        fix: _playing && grades[i] == TransitionGrade.rough
                            ? MixMap.bestFix(analyses, i, firstMovable: _firstMovable, movableBefore: shown)
                            : null,
                        busy: _moving || _stale,
                        onFix: _fix,
                      ),
                  ],
                );
              },
            ),
    );
  }

  Widget _header(BuildContext context, List<TrackAnalysis?> analyses, List<TransitionGrade> grades) {
    final l10n = context.l10n;
    final textTheme = TextTheme.of(context);
    int count(TransitionGrade grade) => grades.where((g) => g == grade).length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 12,
        children: [
          Text(
            l10n.mixMapSummary(
              count(TransitionGrade.smooth),
              count(TransitionGrade.fine),
              count(TransitionGrade.rough),
            ),
            style: textTheme.titleMedium,
          ),
          // Two small charts rather than one with two scales: energy runs 0-100%, tempo in BPM.
          _LineStrip(
            title: l10n.mixMapEnergy,
            // Intensity runs 0 calm to 1 intense; the raw energy is loudness in dB, on another scale, so it's not mixed in.
            values: [for (final analysis in analyses) analysis?.intensity],
            label: (value) => "${(value * 100).round()}%",
            fixedRange: (0, 1),
          ),
          _LineStrip(
            title: l10n.mixMapTempo,
            values: [for (final analysis in analyses) analysis?.bpm],
            label: (value) => l10n.mixMapBpm(value.round()),
          ),
        ],
      ),
    );
  }
}

/// One measure along the mix as a thin line, with its lowest and highest values named. Gaps where songs aren't
/// analysed.
class _LineStrip extends StatelessWidget {
  const _LineStrip({required this.title, required this.values, required this.label, this.fixedRange});

  final String title;
  final List<double?> values;
  final String Function(double value) label;
  final (double, double)? fixedRange;

  @override
  Widget build(BuildContext context) {
    final known = values.nonNulls.toList();
    final textTheme = TextTheme.of(context);
    final scheme = ColorScheme.of(context);
    if (known.length < 2) return const SizedBox.shrink();
    final low = fixedRange?.$1 ?? known.reduce(min), high = fixedRange?.$2 ?? known.reduce(max);
    return Semantics(
      label: "$title: ${label(known.reduce(min))} – ${label(known.reduce(max))}",
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 4,
        children: [
          Row(
            children: [
              Expanded(child: Text(title, style: textTheme.labelLarge)),
              Text(
                "${label(known.reduce(min))} – ${label(known.reduce(max))}",
                style: textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
          SizedBox(
            height: 56,
            width: double.infinity,
            child: CustomPaint(
              painter: _LinePainter(
                values: values,
                low: low,
                high: high == low ? low + 1 : high,
                line: scheme.primary,
                grid: scheme.outlineVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LinePainter extends CustomPainter {
  _LinePainter({required this.values, required this.low, required this.high, required this.line, required this.grid});

  final List<double?> values;
  final double low, high;
  final Color line, grid;

  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, size.height), Offset(size.width, size.height), gridPaint);
    final linePaint = Paint()
      ..color = line
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final step = values.length > 1 ? size.width / (values.length - 1) : 0.0;
    Offset? at(int i) {
      final value = values[i];
      if (value == null) return null;
      final t = ((value - low) / (high - low)).clamp(0.0, 1.0);
      // A little room at the top and bottom so the line's ends aren't clipped.
      return Offset(i * step, 3 + (1 - t) * (size.height - 6));
    }

    var path = Path();
    var drawing = false;
    for (var i = 0; i < values.length; i++) {
      final point = at(i);
      if (point == null) {
        drawing = false;
        continue;
      }
      if (drawing) {
        path.lineTo(point.dx, point.dy);
      } else {
        path.moveTo(point.dx, point.dy);
        drawing = true;
      }
    }
    canvas.drawPath(path, linePaint);
    // The song playing, marked at the start.
    final first = at(0);
    if (first != null) canvas.drawCircle(first, 4, Paint()..color = line);
  }

  @override
  bool shouldRepaint(_LinePainter old) =>
      old.values != values || old.low != low || old.high != high || old.line != line || old.grid != grid;
}

class _SongRow extends StatelessWidget {
  const _SongRow({required this.song, required this.analysis, required this.playing});

  final BaseItemDto song;
  final TrackAnalysis? analysis;
  final bool playing;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final details = [
      if (analysis?.key != null) analysis!.key!,
      if (analysis?.camelot != null) analysis!.camelot!,
      if (analysis?.bpm != null) l10n.mixMapBpm(analysis!.bpm!.round()),
    ].join(" · ");
    return ListTile(
      dense: true,
      leading: Icon(playing ? TablerIcons.player_play : TablerIcons.music),
      title: Text(song.name ?? "", maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [song.artists?.join(", ") ?? song.albumArtist ?? "", if (details.isNotEmpty) details].join("  ·  "),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

/// How the next song follows on, by icon and word, with a fix offered for a clash.
class _TransitionRow extends StatelessWidget {
  const _TransitionRow({required this.grade, required this.fix, required this.busy, required this.onFix});

  final TransitionGrade grade;
  final MixFix? fix;
  final bool busy;
  final ValueChanged<MixFix> onFix;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = ColorScheme.of(context);
    final (icon, color, text) = switch (grade) {
      TransitionGrade.smooth => (TablerIcons.circle_check, scheme.primary, l10n.mixMapSmooth),
      TransitionGrade.fine => (TablerIcons.circle_minus, scheme.onSurfaceVariant, l10n.mixMapFine),
      TransitionGrade.rough => (TablerIcons.alert_triangle, scheme.error, l10n.mixMapRough),
      TransitionGrade.unknown => (TablerIcons.help_circle, scheme.outline, l10n.mixMapUnknown),
    };
    return Padding(
      padding: const EdgeInsets.only(left: 32, right: 16),
      child: Row(
        spacing: 8,
        children: [
          Icon(icon, size: 18, color: color),
          Expanded(child: Text(text, style: TextTheme.of(context).labelMedium)),
          if (fix != null)
            TextButton.icon(
              onPressed: busy ? null : () => onFix(fix!),
              icon: const Icon(TablerIcons.arrows_sort, size: 18),
              label: Text(l10n.mixMapFix),
            ),
        ],
      ),
    );
  }
}
