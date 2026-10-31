import 'dart:async';
import 'dart:math';

import 'package:finamp/components/karaoke_delete_dialog.dart';
import 'package:finamp/components/karaoke_part_text.dart';
import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/screens/karaoke_screen.dart';
import 'package:finamp/screens/saved_karaoke_screen.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:finamp/services/jellyfin_api_helper.dart';
import 'package:finamp/services/karaoke_service.dart';
import 'package:finamp/services/music_player_background_task.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

class KaraokeDashboardScreen extends StatefulWidget {
  const KaraokeDashboardScreen({super.key, this.service});
  final KaraokeService? service;
  @override
  State<KaraokeDashboardScreen> createState() => _KaraokeDashboardScreenState();
}

class _KaraokeDashboardScreenState extends State<KaraokeDashboardScreen> {
  late final _service = widget.service ?? KaraokeService.instance;
  List<({BaseItemDto item, KaraokeJob job})> _jobs = [];
  int _offset = 0, _total = 0;
  KaraokeState? _filter;
  Timer? _timer;
  bool _busy = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_jobs.any((entry) => entry.job.waiting)) unawaited(_load());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool more = false}) async {
    if (_busy || FinampSettingsHelper.finampSettings.isOffline) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      var offset = more ? _offset : 0;
      final pages = more ? 1 : max(1, (_offset / 50).ceil());
      final jobs = more ? [..._jobs] : <({BaseItemDto item, KaraokeJob job})>[];
      var total = 0;
      for (var page = 0; page < pages; page++) {
        final catalogue = await _service.catalogue(offset: offset, state: _filter);
        total = catalogue.total;
        if (catalogue.items.isEmpty) break;
        final items =
            await GetIt.instance<JellyfinApiHelper>().getItems(
              itemIds: catalogue.items.map((entry) => BaseItemId(entry.id)).toList(),
            ) ??
            [];
        final byId = {for (final item in items) KaraokeService.songId(item.id.raw): item};
        for (final entry in catalogue.items) {
          final item = byId[entry.id];
          if (item != null) jobs.add((item: item, job: entry.job));
        }
        offset += catalogue.items.length;
        if (offset >= total) break;
      }
      if (mounted) {
        setState(() {
          _jobs = {for (final entry in jobs) (entry.item.id, entry.job.part): entry}.values.toList();
          _offset = offset;
          _total = total;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = error is KaraokeDashboardUnavailable ? context.l10n.karaokeDashboardUpgrade : '$error');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _action(BaseItemDto item, KaraokePart part, {bool retry = false, bool save = false}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final missingMessage = context.l10n.karaokeStateMissing;
    try {
      if (retry) {
        await _service.prepare(item.id.raw, part: part);
      } else {
        final job = await _service.status(item.id.raw, part: part);
        if (!job.ready) throw StateError(job.message ?? missingMessage);
        final file = await _service.download(item.id.raw, job, 0, keepOffline: save);
        if (save) {
          await _service.saveOfflineDetails(item, null);
        } else if (mounted) {
          await GetIt.instance<MusicPlayerBackgroundTask>().playSavedKaraoke(
            item,
            file,
            job.measurement(0),
            part.label(context) ?? context.l10n.karaoke,
          );
          if (mounted) {
            await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => KaraokeScreen(initialPart: part)));
          }
        }
      }
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted && _error == null) await _load();
  }

  String _state(KaraokeState state) => switch (state) {
    KaraokeState.queued => context.l10n.karaokeStateQueued,
    KaraokeState.processing => context.l10n.karaokeStateProcessing,
    KaraokeState.ready => context.l10n.karaokeStateReady,
    KaraokeState.failed => context.l10n.karaokeStateFailed,
    KaraokeState.missing => context.l10n.karaokeStateMissing,
  };

  Future<void> _delete(BaseItemDto item, KaraokeJob job) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    var deleted = false;
    try {
      if (!await confirmKaraokeDeletion(context, item, server: true, part: job.part) || !mounted) return;
      await _service.deleteServer(item.id.raw, job);
      deleted = true;
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted && deleted) await _load();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(context.l10n.karaokeDashboard),
      actions: [
        IconButton(
          tooltip: context.l10n.featureRefresh,
          onPressed: _busy ? null : () => _load(),
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: Column(
      children: [
        if (_busy) const LinearProgressIndicator(),
        Padding(padding: const EdgeInsets.all(16), child: Text(context.l10n.karaokeDashboardHelp)),
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pushNamed(SavedKaraokeScreen.routeName),
          child: Text(context.l10n.karaokeSavedLibrary),
        ),
        if (_error != null) Padding(padding: const EdgeInsets.all(12), child: Text(_error!)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: DropdownButton<KaraokeState?>(
            isExpanded: true,
            value: _filter,
            items: [
              DropdownMenuItem(value: null, child: Text(context.l10n.karaokeAllStates)),
              for (final state in KaraokeState.values.where((s) => s != KaraokeState.missing))
                DropdownMenuItem(value: state, child: Text(_state(state))),
            ],
            onChanged: _busy
                ? null
                : (filter) {
                    setState(() {
                      _filter = filter;
                      _offset = 0;
                    });
                    _load();
                  },
          ),
        ),
        Expanded(
          child: _jobs.isEmpty && !_busy
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      FinampSettingsHelper.finampSettings.isOffline
                          ? context.l10n.karaokeOfflineMissing
                          : context.l10n.karaokeDashboardEmpty,
                    ),
                  ),
                )
              : ListView(
                  children: [
                    for (final entry in _jobs)
                      ListTile(
                        title: Text([entry.item.name ?? '', entry.job.part.label(context)].nonNulls.join(' · ')),
                        subtitle: Text(
                          '${entry.item.artists?.join(', ') ?? ''}\n${_state(entry.job.state)}${entry.job.waiting || entry.job.state == KaraokeState.failed ? ': ${entry.job.message ?? ''}' : ''}',
                        ),
                        isThreeLine: true,
                        trailing: entry.job.state == KaraokeState.processing
                            ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator())
                            : PopupMenuButton<String>(
                                enabled: !_busy,
                                onSelected: (action) => action == 'delete'
                                    ? _delete(entry.item, entry.job)
                                    : _action(
                                        entry.item,
                                        entry.job.part,
                                        retry: action == 'retry',
                                        save: action == 'save',
                                      ),
                                itemBuilder: (_) => [
                                  if (entry.job.ready) ...[
                                    PopupMenuItem(value: 'play', child: Text(entry.job.part.play(context))),
                                    PopupMenuItem(value: 'save', child: Text(context.l10n.karaokeSaveOffline)),
                                  ] else if (!entry.job.waiting)
                                    PopupMenuItem(value: 'retry', child: Text(context.l10n.featureRetry)),
                                  PopupMenuItem(value: 'delete', child: Text(context.l10n.karaokeDeleteServer)),
                                ],
                              ),
                      ),
                    if (_offset < _total)
                      TextButton(
                        onPressed: _busy ? null : () => _load(more: true),
                        child: Text(context.l10n.featureLoadMore),
                      ),
                  ],
                ),
        ),
      ],
    ),
  );
}
