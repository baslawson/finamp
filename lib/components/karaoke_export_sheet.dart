import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:finamp/components/karaoke_links.dart';
import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:finamp/services/karaoke_export.dart';
import 'package:finamp/services/karaoke_service.dart';
import 'package:finamp/services/server_hub_service.dart';
import 'package:finamp/utils/platform_helper.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

/// Offers [song]'s mix ([part] at [guide]) as a file: saved on this phone, shared, or as a download link. [title]
/// names the mix at the top. Offline, the copy saved on this phone ([saved]) can still be shared as FLAC. With
/// [savedGuides], the guide level can be chosen too: any online, those saved on the phone offline.
Future<void> showKaraokeExportSheet(
  BuildContext context, {
  required String song,
  required KaraokePart part,
  required int guide,
  required String Function(int guide) title,
  Future<File?> Function(int guide)? saved,
  List<int>? savedGuides,
  KaraokeExport? export,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => KaraokeExportSheet(
    song: song,
    part: part,
    guide: guide,
    title: title,
    saved: saved,
    savedGuides: savedGuides,
    export: export ?? KaraokeExport(),
  ),
);

/// What the sheet does with the file once it's on the phone.
enum _Use { save, share }

class KaraokeExportSheet extends StatefulWidget {
  const KaraokeExportSheet({
    super.key,
    required this.song,
    required this.part,
    required this.guide,
    required this.title,
    required this.export,
    this.saved,
    this.savedGuides,
    this.offline,
  });

  final String song;
  final String Function(int guide) title;
  final KaraokePart part;
  final int guide;
  final KaraokeExport export;
  final Future<File?> Function(int guide)? saved;
  final List<int>? savedGuides;

  /// The largest file saved through the phone's picker, which takes the whole file in memory: an hour of MP3, or
  /// about ten minutes of WAV.
  static const mostToSave = 100 * 1024 * 1024;

  /// Whether the app is offline; the setting when not given.
  @visibleForTesting
  final bool? offline;

  @override
  State<KaraokeExportSheet> createState() => _KaraokeExportSheetState();
}

class _KaraokeExportSheetState extends State<KaraokeExportSheet> {
  var _format = KaraokeFileFormat.mp3;
  var _length = KaraokeLinkLength.day;
  late int _guide = widget.guide;
  bool _busy = false;
  // What's under way, what went wrong, and what was done. Shown in the sheet: a snack bar would show behind it.
  String? _status, _error, _notice;
  ({KaraokeLink link, bool public})? _shared;

  bool get _offline => widget.offline ?? FinampSettingsHelper.finampSettings.isOffline;

  @override
  void initState() {
    super.initState();
    unawaited(widget.export.clearOld().catchError((Object _) {}));
    KaraokeExport.linksChanged.addListener(_linksChanged);
  }

  @override
  void dispose() {
    KaraokeExport.linksChanged.removeListener(_linksChanged);
    super.dispose();
  }

  /// The link shown here stopped elsewhere (from Your download links): it no longer works, so it can't stay on offer.
  void _linksChanged() {
    final shared = _shared;
    if (shared != null && KaraokeExport.stopped.contains(shared.link.id)) setState(() => _shared = null);
  }

  String _hint(KaraokeFileFormat format) => switch (format) {
    KaraokeFileFormat.flac => context.l10n.karaokeExportFlacHint,
    KaraokeFileFormat.wav => context.l10n.karaokeExportWavHint,
    KaraokeFileFormat.mp3 => context.l10n.karaokeExportMp3Hint,
  };

  String _lengthName(KaraokeLinkLength length) => switch (length) {
    KaraokeLinkLength.hour => context.l10n.karaokeLinkHour,
    KaraokeLinkLength.day => context.l10n.karaokeLinkDay,
    KaraokeLinkLength.week => context.l10n.karaokeLinkWeek,
  };

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
      _shared = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) {
        setState(() => _error = error is ServerHubException ? error.message : context.l10n.karaokeExportFailed);
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = null;
        });
      }
    }
  }

  Future<KaraokeExportFile> _prepare() async {
    setState(() => _status = context.l10n.karaokeExportConverting);
    // Closing the sheet stops the wait (and the download after it), which nothing would show any more.
    return widget.export.prepare(widget.song, widget.part, _guide, _format, cancelled: () => !mounted);
  }

  /// Where the share popover points on an iPad, which can't show one without it.
  Rect? _origin() {
    final box = context.findRenderObject();
    return box is RenderBox && box.hasSize ? box.localToGlobal(Offset.zero) & box.size : null;
  }

  Future<void> _use(_Use use) => _run(() async {
    final File file;
    final String name;
    // Read once: the file and the format it's shared as must agree even if the app goes offline meanwhile.
    final offline = _offline;
    if (offline) {
      final saved = await widget.saved?.call(_guide);
      if (!mounted) return;
      if (saved == null) throw ServerHubException(context.l10n.karaokeExportOffline);
      file = saved;
      name = '${widget.title(_guide)}.flac'.replaceAll(RegExp(r'[/\\:*?"<>|]+'), ' ');
    } else {
      final prepared = await _prepare();
      if (!mounted) return;
      setState(() => _status = context.l10n.karaokeExportDownloading(0));
      file = await widget.export.download(
        prepared,
        progress: (fraction) {
          if (mounted) setState(() => _status = context.l10n.karaokeExportDownloading((fraction * 100).floor()));
        },
        cancelled: () => !mounted,
      );
      name = prepared.name;
    }
    if (!mounted) return;
    final format = offline ? KaraokeFileFormat.flac : _format;
    if (use == _Use.share) {
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: format.mimeType, name: name)],
          fileNameOverrides: [name],
          sharePositionOrigin: _origin(),
        ),
      );
      return;
    }
    if (isDesktop) {
      // On computers the picker only says where; the file is copied there without reading it all in.
      final path = await FilePicker.saveFile(fileName: name);
      if (path == null) return;
      await file.copy(path);
    } else {
      // On phones the picker writes the file itself, from bytes it's given: a very long file would need too much
      // memory. Sharing hands over the file itself, and can save it to the phone's files too.
      if (await file.length() > KaraokeExportSheet.mostToSave) {
        if (!mounted) return;
        throw ServerHubException(context.l10n.karaokeExportTooLarge);
      }
      final path = await FilePicker.saveFile(fileName: name, bytes: await file.readAsBytes());
      if (path == null) return;
    }
    if (mounted) setState(() => _notice = context.l10n.karaokeExportSaved(name));
  });

  /// Stops the link just made: it ends straight away for everyone who has it.
  Future<void> _stopLink(KaraokeLink link) {
    final shared = _shared;
    return _run(() async {
      try {
        await widget.export.stop(link.id);
      } on ServerHubException {
        // Refused by the server, or not sent at all: the link still works, so it stays in view with its buttons.
        // Without an answer (timed out, no connection) it may have stopped after all, so it isn't offered again:
        // Your download links shows it if it's still there.
        if (mounted) setState(() => _shared = shared);
        rethrow;
      } catch (_) {
        if (!mounted) rethrow;
        throw ServerHubException(context.l10n.karaokeLinkStopUnsure);
      }
      if (mounted) setState(() => _notice = context.l10n.karaokeLinkStopped);
    });
  }

  Future<void> _link() => _run(() async {
    await _prepare();
    if (!mounted) return;
    final shared = await widget.export.share(widget.song, widget.part, _guide, _format, _length);
    if (mounted) setState(() => _shared = shared);
  });

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final shared = _shared;
    final offline = _offline;
    final savedGuides = widget.savedGuides;
    final guides = savedGuides == null ? null : (offline ? savedGuides : KaraokeService.guideLevels);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l10n.karaokeExport, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(widget.title(_guide), style: Theme.of(context).textTheme.bodyMedium),
            if (guides != null && guides.length > 1) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [
                  for (final guide in guides)
                    ChoiceChip(
                      label: Text('$guide%'),
                      selected: guide == _guide,
                      onSelected: _busy
                          ? null
                          : (_) => setState(() {
                              _guide = guide;
                              _shared = null;
                            }),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 16),
            if (offline)
              Text(l10n.karaokeExportOffline)
            else ...[
              SegmentedButton<KaraokeFileFormat>(
                segments: [
                  for (final format in KaraokeFileFormat.values)
                    ButtonSegment(value: format, label: Text(format.name.toUpperCase())),
                ],
                selected: {_format},
                onSelectionChanged: _busy
                    ? null
                    : (chosen) => setState(() {
                        _format = chosen.single;
                        // The link made offers the file in the format it was made for.
                        _shared = null;
                      }),
              ),
              const SizedBox(height: 8),
              Text(_hint(_format), style: Theme.of(context).textTheme.bodySmall),
            ],
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: _busy ? null : () => _use(_Use.save),
                  icon: const Icon(Icons.save_alt),
                  label: Text(l10n.karaokeExportSave),
                ),
                // Sharing on Linux takes text only, not files.
                if (!Platform.isLinux)
                  OutlinedButton.icon(
                    onPressed: _busy ? null : () => _use(_Use.share),
                    icon: const Icon(Icons.share),
                    label: Text(l10n.karaokeExportShare),
                  ),
              ],
            ),
            if (!offline) ...[
              const Divider(height: 32),
              Text(l10n.karaokeExportLink, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: DropdownButton<KaraokeLinkLength>(
                      isExpanded: true,
                      value: _length,
                      items: [
                        for (final length in KaraokeLinkLength.values)
                          DropdownMenuItem(
                            value: length,
                            child: Text(l10n.karaokeExportLinkLength(_lengthName(length))),
                          ),
                      ],
                      onChanged: _busy ? null : (length) => setState(() => _length = length ?? _length),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _link,
                    icon: const Icon(Icons.link),
                    label: Text(l10n.karaokeExportMakeLink),
                  ),
                ],
              ),
            ],
            if (_busy) ...[const SizedBox(height: 16), const LinearProgressIndicator()],
            if (_status != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_status!)),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
            if (_notice != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_notice!, style: TextStyle(color: Theme.of(context).colorScheme.primary)),
              ),
            if (shared != null) ...[
              const SizedBox(height: 16),
              SelectableText(shared.link.url, maxLines: 3),
              const SizedBox(height: 4),
              Text(
                [
                  l10n.karaokeExportLinkReady(DateFormat.MMMEd().add_jm().format(shared.link.expires)),
                  if (!shared.public) l10n.karaokeExportLinkHomeOnly,
                ].join(' '),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              Wrap(
                spacing: 8,
                children: [
                  TextButton.icon(
                    onPressed: () async {
                      final copied = l10n.karaokeExportCopied;
                      await Clipboard.setData(ClipboardData(text: shared.link.url));
                      if (mounted) setState(() => _notice = copied);
                    },
                    icon: const Icon(Icons.copy),
                    label: Text(l10n.karaokeExportCopy),
                  ),
                  TextButton.icon(
                    onPressed: () =>
                        SharePlus.instance.share(ShareParams(text: shared.link.url, sharePositionOrigin: _origin())),
                    icon: const Icon(Icons.share),
                    label: Text(l10n.karaokeExportShareLink),
                  ),
                  TextButton.icon(
                    onPressed: _busy ? null : () => _stopLink(shared.link),
                    icon: const Icon(Icons.link_off),
                    label: Text(l10n.karaokeLinkStop),
                  ),
                ],
              ),
            ],
            if (!offline)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  onPressed: () => showKaraokeLinksSheet(context, export: widget.export),
                  icon: const Icon(Icons.list),
                  label: Text(l10n.karaokeLinksYours),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
