import 'dart:async';

import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/services/karaoke_export.dart';
import 'package:finamp/services/server_hub_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

/// Opens this account's download links, each with Copy and Stop.
Future<void> showKaraokeLinksSheet(BuildContext context, {KaraokeExport? export}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (context) => SafeArea(
    child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      child: KaraokeLinksList(export: export, showEmpty: true),
    ),
  ),
);

/// This account's download links that still work, each with Copy and Stop. They're loaded again whenever a link is
/// made or stopped anywhere in the app, and when the app comes back to the front (their download counts change).
/// With nothing to list it shows nothing, unless [showEmpty].
class KaraokeLinksList extends StatefulWidget {
  const KaraokeLinksList({super.key, this.hub, this.export, this.showEmpty = false});

  /// The server hub to ask, when the caller already has one.
  final ServerHubService? hub;
  final KaraokeExport? export;
  final bool showEmpty;

  @override
  State<KaraokeLinksList> createState() => _KaraokeLinksListState();
}

class _KaraokeLinksListState extends State<KaraokeLinksList> with AutomaticKeepAliveClientMixin {
  // In a scrolling screen it stays when scrolled away: what it just said, and the links, aren't lost.
  @override
  bool get wantKeepAlive => true;

  late final KaraokeExport _export = widget.export ?? KaraokeExport();
  late final AppLifecycleListener _lifecycle;
  List<KaraokeLink> _links = [];
  bool _public = true, _loaded = false, _busy = false;
  String? _error;
  // What was just done, or why a Stop failed. Shown in the list: a snack bar would show behind a sheet.
  String? _notice;
  bool _noticeIsError = false;
  // Each load numbered: one that finishes after a newer one doesn't overwrite it.
  var _loads = 0;
  Timer? _expiry, _noticeTimer;

  @override
  void initState() {
    super.initState();
    KaraokeExport.linksChanged.addListener(_load);
    _lifecycle = AppLifecycleListener(onResume: _load);
    _load();
  }

  @override
  void didUpdateWidget(KaraokeLinksList old) {
    super.didUpdateWidget(old);
    // The screen around it connected again (its Refresh, or another account): the links are asked for again too.
    if (identical(old.hub, widget.hub)) return;
    // Another account's (or server's), or not known to be this one's: they go meanwhile, as this one can't stop them.
    if (old.hub?.scope != widget.hub?.scope || old.hub?.url != widget.hub?.url) {
      _links = [];
      _loaded = false;
    }
    _load();
  }

  @override
  void dispose() {
    KaraokeExport.linksChanged.removeListener(_load);
    _lifecycle.dispose();
    _expiry?.cancel();
    _noticeTimer?.cancel();
    super.dispose();
  }

  /// Takes a link away when it ends, without waiting for anything else to happen.
  void _watchExpiry() {
    _expiry?.cancel();
    final now = DateTime.now();
    DateTime? next;
    for (final link in _links) {
      if (link.expires.isAfter(now) && (next == null || link.expires.isBefore(next))) next = link.expires;
    }
    if (next == null) return;
    _expiry = Timer(next.difference(now) + const Duration(seconds: 1), () {
      if (!mounted) return;
      setState(() {});
      _watchExpiry();
    });
  }

  Future<void> _load() async {
    final load = ++_loads;
    try {
      final shared = await _export.links(hub: widget.hub);
      if (!mounted || load != _loads) return;
      setState(() {
        _links = shared.links;
        _public = shared.public;
        _loaded = true;
        _error = null;
      });
      _watchExpiry();
    } catch (error) {
      if (!mounted || load != _loads) return;
      // The links shown before go: one may have stopped meanwhile, or belong to another account. The failure is shown,
      // a 404 too: a proxy's (while the hub restarts, say) is no sign there are no links.
      setState(() {
        _loaded = true;
        _links = [];
        _error = error is ServerHubException ? error.message : context.l10n.karaokeLinksFailed;
      });
    }
  }

  void _say(String notice, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _notice = notice;
      _noticeIsError = error;
    });
    // Said for a while, then gone: with no links left, the list goes with it.
    _noticeTimer?.cancel();
    _noticeTimer = Timer(const Duration(seconds: 6), () {
      if (mounted) setState(() => _notice = null);
    });
  }

  Future<void> _stop(KaraokeLink link) async {
    if (_busy) return;
    setState(() => _busy = true);
    final l10n = context.l10n;
    try {
      await _export.stop(link.id, hub: widget.hub);
      if (mounted) setState(() => _links.remove(link));
      _say(l10n.karaokeLinkStopped);
    } on ServerHubException catch (error) {
      // Refused by the server, or not sent at all: the link still works.
      _say(error.message, error: true);
    } catch (_) {
      // No answer: it may have stopped after all. Loading the list again shows which.
      _say(l10n.karaokeLinkStopUnsure, error: true);
      unawaited(_load());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    // Not those stopped here meanwhile (a list loaded before, or a load that failed after), nor those that ended.
    final now = DateTime.now();
    final links = [
      for (final link in _links)
        if (!KaraokeExport.stopped.contains(link.id) && link.expires.isAfter(now)) link,
    ];
    // Nothing to show, unless what was just done is still to be said (the last link stopped, say).
    if (!widget.showEmpty && links.isEmpty && _error == null && _notice == null) return const SizedBox.shrink();
    final l10n = context.l10n;
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!widget.showEmpty) const Divider(height: 32),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.link),
          title: Text(l10n.karaokeLinksTitle),
          subtitle: Text(_public ? l10n.karaokeLinksAbout : l10n.karaokeLinksAboutHomeOnly),
        ),
        if (!_loaded)
          const LinearProgressIndicator()
        else if (_error != null)
          Text(_error!, style: TextStyle(color: colors.error))
        else if (links.isEmpty)
          Text(l10n.karaokeLinksNone),
        if (_notice != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_notice!, style: TextStyle(color: _noticeIsError ? colors.error : colors.primary)),
          ),
        for (final link in links)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(link.name),
            subtitle: Text(l10n.karaokeLinkUntil(DateFormat.MMMEd().add_jm().format(link.expires), link.downloads)),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: l10n.karaokeExportCopy,
                  icon: const Icon(Icons.copy),
                  onPressed: () async {
                    final copied = l10n.karaokeExportCopied;
                    await Clipboard.setData(ClipboardData(text: link.url));
                    _say(copied);
                  },
                ),
                IconButton(
                  tooltip: l10n.karaokeLinkStop,
                  icon: const Icon(Icons.link_off),
                  onPressed: _busy ? null : () => _stop(link),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
