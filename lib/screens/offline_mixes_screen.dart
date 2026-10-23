import 'dart:async';

import 'package:finamp/components/AlbumScreen/download_dialog.dart';
import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/services/downloads_service.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:finamp/services/offline_dj_library.dart';
import 'package:finamp/services/offline_mix_service.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:finamp/services/radio_preferences.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

class OfflineMixesScreen extends StatefulWidget {
  const OfflineMixesScreen({super.key, this.createFromQueue = false});
  final bool createFromQueue;
  @override
  State<OfflineMixesScreen> createState() => _OfflineMixesScreenState();
}

class _OfflineMixesScreenState extends State<OfflineMixesScreen> {
  OfflineDjLibrary? _library;
  final _statuses = <String, ({int music, int voices, bool ready})>{};
  Timer? _timer;
  bool _busy = false, _refreshing = false;
  bool _createShown = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    OfflineMixService.preparing.addListener(_changed);
    _load();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => unawaited(_refresh()));
  }

  @override
  void dispose() {
    _timer?.cancel();
    _library?.changed.removeListener(_changed);
    OfflineMixService.preparing.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) {
      setState(() {});
      unawaited(_refresh());
    }
  }

  Future<void> _load() async {
    try {
      final library = await OfflineDjLibrary.current();
      if (!mounted) return;
      _library?.changed.removeListener(_changed);
      _library = library;
      library.changed.addListener(_changed);
      setState(() {});
      await _refresh();
      if (widget.createFromQueue && !_createShown && mounted) {
        _createShown = true;
        await _create();
      }
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  Future<void> _refresh() async {
    final library = _library;
    if (!mounted || _refreshing || library == null) return;
    if (library.scope != RadioPreferencesStore.scope) {
      await _load();
      return;
    }
    _refreshing = true;
    try {
      final values = <String, ({int music, int voices, bool ready})>{};
      for (final mix in library.mixes) {
        values[mix.id] = await OfflineMixService.status(library, mix);
      }
      if (mounted) {
        setState(() {
          _statuses
            ..clear()
            ..addAll(values);
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      _refreshing = false;
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    if (_library?.scope != RadioPreferencesStore.scope) {
      await _load();
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      await _refresh();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _prepare(OfflineDjMix mix) {
    unawaited(
      OfflineMixService.prepare(mix)
          .catchError((Object error) {
            if (mounted) setState(() => _error = '$error');
          })
          .whenComplete(() {
            if (mounted) unawaited(_refresh());
          }),
    );
  }

  Future<void> _download(OfflineDjMix mix) async {
    final scope = RadioPreferencesStore.scope;
    if (_library?.scope != scope || !(_library?.contains(mix) ?? false)) return;
    final stub = DownloadStub.fromItem(type: DownloadItemType.collection, item: mix.playlist);
    await DownloadDialog.show(context, stub, null, trackCount: mix.tracks.length);
    if (!mounted || scope != RadioPreferencesStore.scope) return;
    if (mix.includeDj && GetIt.instance<DownloadsService>().getStatus(stub, null).isRequired) _prepare(mix);
  }

  Future<void> _create() async {
    if (_busy || FinampSettingsHelper.finampSettings.isOffline) return;
    final queue = GetIt.instance<QueueService>().getQueue();
    if (OfflineMixService.snapshot(queue, 50).isEmpty) {
      setState(() => _error = context.l10n.offlineMixUnavailable);
      return;
    }
    final options = await showDialog<({String name, int limit, bool includeDj})>(
      context: context,
      builder: (_) => OfflineMixDownloadDialog(initialName: queue.source.name.getLocalized(context.l10n)),
    );
    if (options == null || !mounted) return;
    await _run(() async {
      final mix = await OfflineMixService.create(
        name: options.name,
        limit: options.limit,
        includeDj: options.includeDj,
      );
      if (mounted) await _download(mix);
    });
  }

  Future<void> _remove(OfflineDjMix mix) async {
    if (GetIt.instance<QueueService>().getQueue().source.id == mix.playlist.id.raw) {
      GlobalSnackbar.message((context) => context.l10n.offlineMixInUse);
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.offlineMixRemove),
        content: Text(context.l10n.offlineMixRemovePrompt),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
          ),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(context.l10n.offlineMixRemove)),
        ],
      ),
    );
    if ((confirmed ?? false) && mounted) await _run(() => OfflineMixService.remove(mix));
  }

  @override
  Widget build(BuildContext context) {
    final offline = FinampSettingsHelper.finampSettings.isOffline;
    final library = _library;
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.offlineMixes)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(context.l10n.offlineMixHelp),
          Text(context.l10n.offlineMixDjOffHelp),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _busy || offline || library == null ? null : _create,
            icon: const Icon(Icons.download),
            label: Text(context.l10n.offlineMixDownload),
          ),
          if (_busy || (library == null && _error == null)) const LinearProgressIndicator(),
          if (_error != null) Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(_error!)),
          if (library != null && library.mixes.isEmpty) Text(context.l10n.offlineMixEmpty),
          if (library != null)
            for (final mix in library.mixes)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(mix.playlist.name ?? '', style: Theme.of(context).textTheme.titleMedium),
                      Text(
                        mix.includeDj
                            ? context.l10n.offlineMixProgress(
                                _statuses[mix.id]?.music ?? 0,
                                _statuses[mix.id]?.voices ?? 0,
                                mix.tracks.length,
                              )
                            : context.l10n.offlineMixMusicProgress(_statuses[mix.id]?.music ?? 0, mix.tracks.length),
                      ),
                      if (OfflineMixService.preparing.value.contains(mix.id)) ...[
                        Text(context.l10n.offlineMixWorking),
                        const LinearProgressIndicator(),
                      ] else if (_statuses[mix.id]?.ready ?? false)
                        Text(context.l10n.offlineMixReady)
                      else
                        Text(
                          mix.includeDj && (_statuses[mix.id]?.music ?? 0) == mix.tracks.length
                              ? context.l10n.offlineMixDjUnavailable
                              : context.l10n.offlineMixPending,
                        ),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          TextButton.icon(
                            onPressed: _busy || (_statuses[mix.id]?.music ?? 0) != mix.tracks.length
                                ? null
                                : () => _run(() => OfflineMixService.play(mix)),
                            icon: const Icon(Icons.play_arrow),
                            label: Text(context.l10n.playButtonLabel),
                          ),
                          if (!offline && (_statuses[mix.id]?.music ?? 0) < mix.tracks.length)
                            TextButton.icon(
                              onPressed: _busy ? null : () => _run(() => _download(mix)),
                              icon: const Icon(Icons.download),
                              label: Text(context.l10n.offlineMixDownload),
                            ),
                          if (OfflineMixService.preparing.value.contains(mix.id))
                            TextButton(
                              onPressed: () => OfflineMixService.cancel(mix),
                              child: Text(context.l10n.offlineMixCancel),
                            )
                          else if (!offline && mix.includeDj && (_statuses[mix.id]?.voices ?? 0) < mix.tracks.length)
                            TextButton(onPressed: () => _prepare(mix), child: Text(context.l10n.offlineMixRetry)),
                          if (mix.includeDj)
                            TextButton(
                              onPressed: _busy ? null : () => _run(() => OfflineMixService.clearVoices(mix)),
                              child: Text(context.l10n.offlineMixClearDj),
                            ),
                          TextButton.icon(
                            onPressed: _busy ? null : () => _remove(mix),
                            icon: const Icon(Icons.delete_outline),
                            label: Text(context.l10n.offlineMixRemove),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
        ],
      ),
    );
  }
}

class OfflineMixDownloadDialog extends StatefulWidget {
  const OfflineMixDownloadDialog({super.key, required this.initialName});
  final String initialName;
  @override
  State<OfflineMixDownloadDialog> createState() => _OfflineMixDownloadDialogState();
}

class _OfflineMixDownloadDialogState extends State<OfflineMixDownloadDialog> {
  late final _name = TextEditingController(text: widget.initialName);
  int _limit = 20;
  bool _includeDj = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(context.l10n.offlineMixDownload),
    content: SizedBox(
      width: 420,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              maxLength: 100,
              decoration: InputDecoration(labelText: context.l10n.offlineMixName),
            ),
            DropdownButtonFormField<int>(
              initialValue: _limit,
              isExpanded: true,
              decoration: InputDecoration(labelText: context.l10n.offlineMixSongLimit),
              items: [
                for (final count in [20, 50])
                  DropdownMenuItem(value: count, child: Text(context.l10n.offlineMixSongs(count))),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _limit = value);
              },
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(context.l10n.offlineMixIncludeDj),
              value: _includeDj,
              onChanged: (value) => setState(() => _includeDj = value ?? false),
            ),
            Text(context.l10n.offlineMixDjHelp),
            const SizedBox(height: 8),
            Text(context.l10n.offlineMixHelp),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
      ),
      FilledButton(
        onPressed: () {
          if (_name.text.trim().isNotEmpty) {
            Navigator.pop(context, (name: _name.text.trim(), limit: _limit, includeDj: _includeDj));
          }
        },
        child: Text(context.l10n.offlineMixDownload),
      ),
    ],
  );
}
