import 'dart:async';
import 'dart:math';

import 'package:finamp/components/album_image.dart';
import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/services/current_album_image_provider.dart';
import 'package:finamp/services/spectrum_reader.dart';
import 'package:finamp/services/theme_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

enum VisualizerStyle { bars, ring }

/// A full-screen visualizer that moves with the music, in the colours of the album. Nice on a TV or a tablet stand.
class VisualizerScreen extends StatelessWidget {
  const VisualizerScreen({super.key});

  static const routeName = "/visualizer";

  @override
  Widget build(BuildContext context) => const PlayerScreenTheme(child: _Visualizer());
}

class _Visualizer extends ConsumerStatefulWidget {
  const _Visualizer();

  @override
  ConsumerState<_Visualizer> createState() => _VisualizerState();
}

class _VisualizerState extends ConsumerState<_Visualizer> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  List<double> _levels = List.filled(SpectrumReader.bands, 0);
  bool _reading = false;
  VisualizerStyle _style = VisualizerStyle.ring;
  bool _showInfo = true;
  Timer? _hideInfo;

  @override
  void initState() {
    super.initState();
    unawaited(SpectrumReader.setEnabled(true));
    unawaited(WakelockPlus.enable());
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky));
    _ticker = createTicker((_) => _poll())..start();
    _scheduleHide();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _hideInfo?.cancel();
    unawaited(SpectrumReader.setEnabled(false));
    unawaited(WakelockPlus.disable());
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    super.dispose();
  }

  void _scheduleHide() {
    _hideInfo?.cancel();
    _hideInfo = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _showInfo = false);
    });
  }

  Future<void> _poll() async {
    if (_reading) return;
    _reading = true;
    final fresh = await SpectrumReader.read();
    _reading = false;
    if (!mounted || fresh.length != _levels.length) return;
    setState(() {
      // Rise fast, fall slowly, like a real level meter.
      _levels = [
        for (var i = 0; i < fresh.length; i++) fresh[i] > _levels[i] ? fresh[i] : _levels[i] * 0.88 + fresh[i] * 0.12,
      ];
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final track = ref.watch(currentTrackProvider).value;
    final item = track?.baseItem;
    final colors = [scheme.primary, scheme.tertiary, scheme.secondary];
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          setState(() => _showInfo = !_showInfo);
          if (_showInfo) _scheduleHide();
        },
        onDoubleTap: () =>
            setState(() => _style = _style == VisualizerStyle.ring ? VisualizerStyle.bars : VisualizerStyle.ring),
        child: Stack(
          fit: StackFit.expand,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  colors: [Color.lerp(Colors.black, scheme.primary, 0.12 + 0.25 * _bass)!, Colors.black],
                  radius: 1.1,
                ),
              ),
            ),
            CustomPaint(
              painter: _SpectrumPainter(levels: _levels, colors: colors, style: _style),
            ),
            if (_style == VisualizerStyle.ring && item != null)
              Center(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final size = min(MediaQuery.sizeOf(context).width, MediaQuery.sizeOf(context).height) * 0.42;
                    return Transform.scale(
                      scale: 1 + _bass * 0.06,
                      child: SizedBox.square(
                        dimension: size,
                        child: ClipOval(
                          child: AlbumImage(item: item, borderRadius: BorderRadius.zero),
                        ),
                      ),
                    );
                  },
                ),
              ),
            AnimatedOpacity(
              opacity: _showInfo ? 1 : 0,
              duration: const Duration(milliseconds: 400),
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          IconButton(
                            color: Colors.white,
                            icon: const Icon(TablerIcons.chevron_down),
                            tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                            onPressed: () => Navigator.of(context).pop(),
                          ),
                          const Spacer(),
                          IconButton(
                            color: Colors.white,
                            tooltip: context.l10n.visualizerChangeStyle,
                            icon: Icon(
                              _style == VisualizerStyle.ring ? TablerIcons.chart_bar : TablerIcons.circle_dashed,
                            ),
                            onPressed: () => setState(
                              () =>
                                  _style = _style == VisualizerStyle.ring ? VisualizerStyle.bars : VisualizerStyle.ring,
                            ),
                          ),
                        ],
                      ),
                      const Spacer(),
                      Text(
                        item?.name ?? "",
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w700),
                      ),
                      Text(
                        item?.albumArtist ?? item?.artists?.firstOrNull ?? "",
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white70, fontSize: 18),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// How loud the low end is right now, for pulsing.
  double get _bass => (_levels.take(5).fold(0.0, (sum, level) => sum + level) / 5).clamp(0.0, 1.0);
}

class _SpectrumPainter extends CustomPainter {
  _SpectrumPainter({required this.levels, required this.colors, required this.style});

  final List<double> levels;
  final List<Color> colors;
  final VisualizerStyle style;

  Color _colorAt(double t) {
    final scaled = t * (colors.length - 1);
    final index = scaled.floor().clamp(0, colors.length - 2);
    return Color.lerp(colors[index], colors[index + 1], scaled - index)!;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (levels.isEmpty) return;
    final paint = Paint()..strokeCap = StrokeCap.round;
    switch (style) {
      case VisualizerStyle.bars:
        // Mirrored around the middle: bass in the centre, treble towards the edges.
        final count = levels.length * 2;
        final slot = size.width / count;
        paint.strokeWidth = slot * 0.6;
        final baseline = size.height * 0.62;
        for (var i = 0; i < count; i++) {
          final band = (i - levels.length).abs().clamp(0, levels.length - 1);
          final level = levels[band];
          final height = max(4.0, level * size.height * 0.5);
          final x = slot * (i + 0.5);
          paint.color = _colorAt(band / levels.length).withValues(alpha: 0.9);
          canvas.drawLine(Offset(x, baseline), Offset(x, baseline - height), paint);
          // A faint reflection.
          paint.color = paint.color.withValues(alpha: 0.18);
          canvas.drawLine(Offset(x, baseline + 6), Offset(x, baseline + 6 + height * 0.35), paint);
        }
      case VisualizerStyle.ring:
        final center = size.center(Offset.zero);
        final radius = min(size.width, size.height) * 0.23;
        final count = levels.length * 2;
        paint.strokeWidth = max(3.0, 2 * pi * radius / count * 0.55);
        for (var i = 0; i < count; i++) {
          // Both halves go from bass at the top to treble at the bottom.
          final band = i < levels.length ? i : count - 1 - i;
          final level = levels[band];
          final angle = -pi / 2 + 2 * pi * i / count;
          final direction = Offset(cos(angle), sin(angle));
          final length = 6 + level * radius * 0.9;
          paint.color = _colorAt(band / levels.length).withValues(alpha: 0.95);
          canvas.drawLine(center + direction * (radius + 10), center + direction * (radius + 10 + length), paint);
        }
    }
  }

  @override
  bool shouldRepaint(_SpectrumPainter oldDelegate) => true;
}
