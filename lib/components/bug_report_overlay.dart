import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/services/report_service.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

/// The app, with a floating bug button over it while bug reports are on. Tapping it takes a screenshot of the app
/// (without the button), asks what went wrong, and sends both with the logs to the server hub.
class BugReportOverlay extends StatefulWidget {
  const BugReportOverlay({super.key, required this.child});

  final Widget child;

  @override
  State<BugReportOverlay> createState() => _BugReportOverlayState();
}

class _BugReportOverlayState extends State<BugReportOverlay> {
  final _app = GlobalKey();
  // From the bottom right corner, so it stays put when the screen turns.
  Offset _fromCorner = const Offset(16, 160);
  // While dragging: the button's distance from the corner plus the finger's position, which stays the same as both
  // move together.
  Offset _grab = Offset.zero;
  bool _busy = false;

  Future<void> _report() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final boundary = _app.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) return;
      final image = await boundary.toImage(pixelRatio: MediaQuery.devicePixelRatioOf(context).clamp(1, 2));
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      final dialogContext = GlobalSnackbar.navigatorState?.overlay?.context;
      if (png == null || dialogContext == null || !dialogContext.mounted) return;
      final note = await showDialog<String>(context: dialogContext, builder: (context) => const _NoteDialog());
      if (note == null) return;
      await ReportService.uploadBug(png.buffer.asUint8List(), note);
      GlobalSnackbar.message((context) => context.l10n.bugReportSent, isConfirmation: true);
    } catch (e) {
      GlobalSnackbar.error(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      textDirection: TextDirection.ltr,
      children: [
        Positioned.fill(
          child: RepaintBoundary(key: _app, child: widget.child),
        ),
        ValueListenableBuilder(
          valueListenable: ReportService.bugButton,
          builder: (context, shown, _) {
            if (!shown) return const SizedBox.shrink();
            final size = MediaQuery.sizeOf(context);
            final padding = MediaQuery.paddingOf(context);
            // Kept on the screen, clear of the system bars, however it was dragged or the screen turned.
            double within(double value, double low, double high) => value.clamp(low, max(low, high));
            final right = within(_fromCorner.dx, padding.right, size.width - 56 - padding.left);
            final bottom = within(_fromCorner.dy, padding.bottom, size.height - 56 - padding.top);
            return Positioned(
              right: right,
              bottom: bottom,
              child: GestureDetector(
                // From where the finger first touched, so the button moves with it from the start and stays under it.
                dragStartBehavior: DragStartBehavior.down,
                onPanStart: (details) => _grab = Offset(right, bottom) + details.globalPosition,
                onPanUpdate: (details) => setState(() => _fromCorner = _grab - details.globalPosition),
                child: Material(
                  color: Theme.of(context).colorScheme.errorContainer.withValues(alpha: 0.9),
                  shape: const CircleBorder(),
                  elevation: 4,
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: _busy ? null : () => unawaited(_report()),
                    child: SizedBox.square(
                      dimension: 48,
                      child: _busy
                          ? const Padding(padding: EdgeInsets.all(14), child: CircularProgressIndicator(strokeWidth: 2))
                          : Icon(TablerIcons.bug, color: Theme.of(context).colorScheme.onErrorContainer),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

class _NoteDialog extends StatefulWidget {
  const _NoteDialog();

  @override
  State<_NoteDialog> createState() => _NoteDialogState();
}

class _NoteDialogState extends State<_NoteDialog> {
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(context.l10n.bugReportTitle),
      content: TextField(
        controller: _note,
        autofocus: true,
        minLines: 2,
        maxLines: 6,
        maxLength: 2000,
        decoration: InputDecoration(hintText: context.l10n.bugReportHint),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        FilledButton(onPressed: () => Navigator.of(context).pop(_note.text), child: Text(context.l10n.bugReportSend)),
      ],
    );
  }
}
