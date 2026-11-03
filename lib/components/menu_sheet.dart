import 'dart:math';

import 'package:flutter/material.dart';

/// The most of the screen a menu sheet takes, leaving room above it to tap to close it.
const menuSheetMaxHeight = 0.9;

/// The height of the sheet's drag handle, above its content.
const _handleHeight = kMinInteractiveDimension;

/// Shows a menu sheet as tall as its content, below the status bar and short of the top of the screen. However tall
/// its content, it can be closed by dragging its handle, tapping above it, or pulling its content down from the top.
Future<T?> showMenuSheet<T>({required BuildContext context, required WidgetBuilder builder}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    // Measured as it is shown, so the room above stays when the window changes size.
    builder: (context) => ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: max(0, MediaQuery.sizeOf(context).height * menuSheetMaxHeight - _handleHeight),
      ),
      child: PullDownToClose(child: builder(context)),
    ),
  );
}

/// Closes the route it is in when its scrolling content, already at the top, is pulled further down.
class PullDownToClose extends StatefulWidget {
  const PullDownToClose({super.key, required this.child});

  /// How far past the top the content is pulled to close.
  static const distance = 64.0;

  final Widget child;

  @override
  State<PullDownToClose> createState() => _PullDownToCloseState();
}

class _PullDownToCloseState extends State<PullDownToClose> {
  double _pulled = 0;

  /// Whether this pull already asked to close: once per pull, so one turned down can be tried again with the next.
  bool _asked = false;

  bool _onScroll(ScrollNotification notification) {
    // Only the sheet's own scrolling, not a text field or list inside it.
    if (notification.depth != 0) return false;
    final metrics = notification.metrics;
    if (notification is OverscrollNotification && notification.dragDetails != null) {
      // Scrolling that stops at the top (Android): pulled past the top counts up, past the bottom only counts down.
      _pulled -= notification.overscroll;
    } else if (notification is ScrollUpdateNotification &&
        notification.dragDetails != null &&
        metrics.pixels < metrics.minScrollExtent) {
      // Scrolling that bounces (iOS) follows the finger past the top instead.
      _pulled = metrics.minScrollExtent - metrics.pixels;
    } else if (notification is ScrollUpdateNotification) {
      _pulled = 0;
    } else if (notification is ScrollEndNotification) {
      _pulled = 0;
      _asked = false;
    }
    if (_pulled >= PullDownToClose.distance && !_asked) {
      _asked = true;
      Navigator.of(context).maybePop();
    }
    return false;
  }

  @override
  Widget build(BuildContext context) =>
      NotificationListener<ScrollNotification>(onNotification: _onScroll, child: widget.child);
}
