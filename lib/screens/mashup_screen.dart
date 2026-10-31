import 'dart:async';
import 'dart:io';

import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:finamp/services/jellyfin_api_helper.dart';
import 'package:finamp/services/karaoke_service.dart';
import 'package:finamp/services/lyrics_timeline.dart';
import 'package:finamp/services/mashup_service.dart';
import 'package:finamp/services/music_player_background_task.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

/// Mashups made on the server: one song's vocals over another's instrumental. With [item], suggests partners for
/// it and lets any other song be picked; always lists the server's mashups to play or delete.
class MashupScreen extends StatefulWidget {
  const MashupScreen({super.key, this.item, this.service, this.songs, this.offline, this.isPlaying, this.played});
  final BaseItemDto? item;
  final MashupService? service;

  /// Whether the app is offline; the app's setting by default.
  final bool? offline;

  /// Whether the player is playing this mashup's phone copy; asks the player by default.
  final Future<bool> Function(MashupJob job)? isPlaying;

  /// Looks songs up by id, or by name with [searchTerm]; Jellyfin's by default.
  final Future<List<BaseItemDto>> Function({List<String>? ids, String? searchTerm})? songs;

  /// The songs played lately, which "Mashups to try" start from; Jellyfin's by default.
  final Future<List<BaseItemDto>> Function()? played;

  static const routeName = '/mashups';

  @override
  State<MashupScreen> createState() => _MashupScreenState();
}

class _MashupScreenState extends State<MashupScreen> {
  late final _service = widget.service ?? MashupService.instance;
  final Map<String, BaseItemDto> _songs = {};
  List<MashupPartner> _partners = [];
  List<MashupIdea>? _ideas;
  String? _ideasError;
  List<MashupJob> _jobs = [];
  List<SavedMashup> _saved = [];
  bool _sings = true, _loadingPartners = false, _loadingJobs = false, _reloadJobs = false, _busy = false;
  String? _partnersError, _error;
  Timer? _poll;
  int _generation = 0;
  bool get _offline => widget.offline ?? FinampSettingsHelper.finampSettings.isOffline;

  @override
  void initState() {
    super.initState();
    unawaited(_loadPartners());
    unawaited(_loadIdeas());
    unawaited(_loadSaved());
    unawaited(_loadJobs());
    _poll = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_jobs.any((job) => job.waiting)) unawaited(_loadJobs());
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<List<BaseItemDto>> _lookUp({List<String>? ids, String? searchTerm}) async {
    if (widget.songs != null) return widget.songs!(ids: ids, searchTerm: searchTerm);
    final api = GetIt.instance<JellyfinApiHelper>();
    if (ids != null) return await api.getItems(itemIds: ids.map(BaseItemId.new).toList()) ?? [];
    return await api.getItems(includeItemTypes: 'Audio', searchTerm: searchTerm, recursive: true, limit: 30) ?? [];
  }

  /// Fills in the names of songs not seen yet.
  Future<void> _remember(Iterable<String> ids) async {
    final missing = ids.where((id) => !_songs.containsKey(id)).toSet().toList();
    if (missing.isEmpty) return;
    for (final song in await _lookUp(ids: missing)) {
      _songs[KaraokeService.songId(song.id.raw)] = song;
    }
  }

  Future<void> _loadPartners() async {
    final item = widget.item;
    if (item == null || _offline) return;
    final generation = ++_generation, sings = _sings;
    setState(() {
      _loadingPartners = true;
      _partnersError = null;
      _partners = [];
    });
    try {
      // Looked up rather than taken from [item], which is a mashup's own title and length while one plays.
      await _remember([KaraokeService.songId(item.id.raw)]);
      final partners = await _service.partners(item.id.raw, sings: sings);
      await _remember(partners.map((partner) => partner.id));
      if (mounted && generation == _generation) {
        setState(() => _partners = partners.where((partner) => _songs.containsKey(partner.id)).toList());
      }
    } catch (error) {
      if (mounted && generation == _generation) setState(() => _partnersError = '$error');
    } finally {
      if (mounted && generation == _generation) setState(() => _loadingPartners = false);
    }
  }

  Future<void> _loadJobs() async {
    if (!mounted || _offline) return;
    if (_loadingJobs) {
      _reloadJobs = true;
      return;
    }
    setState(() => _loadingJobs = true);
    try {
      final listed = await _service.list();
      await _remember(listed.expand((job) => [job.vocals!, job.backing!]));
      final song = widget.item == null ? null : KaraokeService.songId(widget.item!.id.raw);
      bool mine(MashupJob job) => job.vocals == song || job.backing == song;
      // This song's mashups first, each group in the server's order (the ones being made, then the newest).
      final jobs = [...listed.where(mine), ...listed.where((job) => !mine(job))];
      if (mounted) {
        setState(() {
          _jobs = jobs;
          _error = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _loadingJobs = false);
    }
    if (_reloadJobs && mounted) {
      _reloadJobs = false;
      await _loadJobs();
    }
  }

  String _name(String? id) => _songs[id]?.name ?? context.l10n.mashupUnknownSong;

  String _describe(MashupPlan plan) {
    final l10n = context.l10n;
    return [
      switch (plan.key) {
        'relative' => l10n.mashupKeyRelative,
        'neighbour' => l10n.mashupKeyNeighbour,
        _ => l10n.mashupKeySame,
      },
      if (plan.semitones > 0) l10n.mashupHigher(plan.semitones),
      if (plan.semitones < 0) l10n.mashupLower(-plan.semitones),
      if (plan.tempoPercent > 0) l10n.mashupFaster(plan.tempoPercent),
      if (plan.tempoPercent < 0) l10n.mashupSlower(-plan.tempoPercent),
    ].join(' · ');
  }

  /// The pair in order: the singer's song, then the backing song.
  /// Without a song, pairs to try from the songs played lately.
  Future<void> _loadIdeas() async {
    if (widget.item != null || _offline) return;
    try {
      final played = await (widget.played ?? _played)();
      for (final song in played) {
        _songs[KaraokeService.songId(song.id.raw)] = song;
      }
      final ideas = await _service.ideas([for (final song in played) song.id.raw]);
      await _remember(ideas.expand((idea) => [idea.vocals, idea.backing]));
      if (!mounted) return;
      setState(() {
        _ideas = ideas.where((idea) => _songs.containsKey(idea.vocals) && _songs.containsKey(idea.backing)).toList();
        _ideasError = null;
      });
    } catch (error) {
      if (mounted) setState(() => _ideasError = '$error');
    }
  }

  Future<List<BaseItemDto>> _played() async =>
      await GetIt.instance<JellyfinApiHelper>().getItems(
        includeItemTypes: 'Audio',
        sortBy: 'DatePlayed',
        sortOrder: 'Descending',
        filters: 'IsPlayed',
        recursive: true,
        limit: 12,
      ) ??
      [];

  (String, String) _pairWith(String other) {
    final song = KaraokeService.songId(widget.item!.id.raw);
    return _sings ? (song, other) : (other, song);
  }

  Future<void> _confirm(String vocals, String backing, MashupPlan? known) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final plan = known ?? await _service.plan(vocals, backing);
      if (!mounted) return;
      final make = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(context.l10n.mashupOver(_name(vocals), _name(backing))),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_describe(plan)),
              for (final warning in plan.warnings)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(warning, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ),
              Padding(padding: const EdgeInsets.only(top: 12), child: Text(context.l10n.mashupTime)),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
            ),
            FilledButton(onPressed: () => Navigator.of(context).pop(true), child: Text(context.l10n.mashupMake)),
          ],
        ),
      );
      if (make != true) return;
      await _service.make(vocals, backing);
      GlobalSnackbar.message((context) => context.l10n.mashupMaking, isConfirmation: true);
      await _loadJobs();
    } catch (error) {
      GlobalSnackbar.error(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pick() async {
    final picked = await showDialog<BaseItemDto>(
      context: context,
      builder: (context) => _SongSearchDialog(search: (term) => _lookUp(searchTerm: term)),
    );
    if (picked == null || !mounted) return;
    final id = KaraokeService.songId(picked.id.raw);
    if (id == KaraokeService.songId(widget.item!.id.raw)) {
      GlobalSnackbar.message((context) => context.l10n.mashupSameSong);
      return;
    }
    _songs[id] = picked;
    final (vocals, backing) = _pairWith(id);
    await _confirm(vocals, backing, null);
  }

  Future<void> _loadSaved() async {
    if (!mounted) return;
    try {
      final saved = await _service.saved();
      if (!mounted) return;
      setState(() {
        _saved = saved;
        for (final entry in saved) {
          _songs.putIfAbsent(KaraokeService.songId(entry.singer.id.raw), () => entry.singer);
          _songs.putIfAbsent(KaraokeService.songId(entry.band.id.raw), () => entry.band);
        }
      });
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  SavedMashup? _savedCopy(MashupJob job) => _saved.where((entry) => entry.job.revision == job.revision).firstOrNull;

  /// Plays a server mashup, from the phone's saved copy when it has one.
  Future<void> _play(MashupJob job) async {
    final saved = _savedCopy(job);
    if (saved != null) return _playSaved(saved);
    final l10n = context.l10n;
    await _run(() async {
      final current = await _service.status(job.vocals!, job.backing!);
      if (!current.ready) throw StateError(current.message ?? l10n.karaokeStateMissing);
      final singer = _songs[job.vocals], band = _songs[job.backing];
      if (singer == null || band == null) throw StateError(l10n.mashupUnknownSong);
      await _playFile(await _service.download(current), current, singer, band);
    });
  }

  Future<void> _playSaved(SavedMashup saved) => _run(() => _playFile(saved.file, saved.job, saved.singer, saved.band));

  Future<void> _playFile(File file, MashupJob job, BaseItemDto singer, BaseItemDto band) async {
    if (!mounted) return;
    // Plays as the singer's song (its words are the ones sung), for as long as the backing song lasts.
    final item = BaseItemDto.fromJson(singer.toJson(setOffline: false))
      ..name = context.l10n.mashupOver(singer.name ?? '', band.name ?? '')
      ..runTimeTicks = band.runTimeTicks
      ..artists = {...?singer.artists, ...?band.artists}.toList();
    final timeline = job.lyricsTimeline?.ofSong(singer);
    await GetIt.instance<MusicPlayerBackgroundTask>().playSavedKaraoke(
      item,
      file,
      job.measurement,
      context.l10n.mashups,
      extras: {if (timeline != null) LyricsTimeline.key: timeline.toJson()},
    );
  }

  Future<void> _save(MashupJob job) {
    final l10n = context.l10n;
    return _run(() async {
      final current = await _service.status(job.vocals!, job.backing!);
      if (!current.ready) throw StateError(current.message ?? l10n.karaokeStateMissing);
      final singer = _songs[job.vocals], band = _songs[job.backing];
      if (singer == null || band == null) throw StateError(l10n.mashupUnknownSong);
      await _service.download(current, keepOffline: true, singer: singer, band: band);
      GlobalSnackbar.message((context) => context.l10n.mashupSavedOffline, isConfirmation: true);
    });
  }

  Future<bool> _sure(String prompt, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          content: Text(prompt),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
            ),
            FilledButton(onPressed: () => Navigator.of(context).pop(true), child: Text(action)),
          ],
        ),
      ) ??
      false;

  Future<void> _deleteServer(MashupJob job) async {
    if (_busy) return;
    final name = context.l10n.mashupOver(_name(job.vocals), _name(job.backing));
    if (!await _sure(context.l10n.mashupDeleteServerPrompt(name), context.l10n.mashupDeleteServer)) return;
    await _run(() => _service.deleteServer(job));
  }

  Future<bool> _playing(MashupJob job) async {
    final path = GetIt.instance<MusicPlayerBackgroundTask>().karaokeMixPath?.replaceAll('\\', '/');
    if (path == null) return false;
    return (await _service.localPaths(job)).any((local) => local.replaceAll('\\', '/') == path);
  }

  Future<void> _deletePhone(MashupJob job) async {
    if (_busy) return;
    final name = context.l10n.mashupOver(_name(job.vocals), _name(job.backing));
    final prompt = context.l10n.mashupDeletePhonePrompt(name), action = context.l10n.mashupDeletePhone;
    final inUse = context.l10n.mashupDeleteInUse;
    final playing = widget.isPlaying ?? _playing;
    final messenger = ScaffoldMessenger.of(context);
    void refuse() => messenger.showSnackBar(SnackBar(content: Text(inUse)));
    if (await playing(job)) return refuse();
    if (!mounted || !await _sure(prompt, action)) return;
    await _run(() async {
      // Checked again: it may have started playing while the question was open.
      if (await playing(job)) return refuse();
      await _service.deleteLocal(job);
    });
  }

  /// Runs one action at a time, then refreshes what's on the server and the phone.
  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      GlobalSnackbar.error(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    await _loadSaved();
    await _loadJobs();
  }

  Future<void> _retry(MashupJob job) => _run(() => _service.make(job.vocals!, job.backing!));

  String _state(MashupJob job) {
    final l10n = context.l10n;
    final state = switch (job.state) {
      KaraokeState.queued => l10n.karaokeStateQueued,
      KaraokeState.processing => l10n.karaokeStateProcessing,
      KaraokeState.ready => l10n.karaokeStateReady,
      KaraokeState.failed => l10n.karaokeStateFailed,
      KaraokeState.missing => l10n.karaokeStateMissing,
    };
    final message = job.waiting || job.state != KaraokeState.ready ? job.message : null;
    return [state, if (message != null && message.isNotEmpty) message].join(': ');
  }

  Widget _jobTile(MashupJob job) => ListTile(
    leading: const Icon(TablerIcons.arrows_join_2),
    title: Text(context.l10n.mashupOver(_name(job.vocals), _name(job.backing))),
    subtitle: Text([_state(job), if (job.plan != null) _describe(job.plan!)].join('\n')),
    isThreeLine: true,
    onTap: job.ready && !_busy ? () => _play(job) : null,
    trailing: job.state == KaraokeState.processing
        ? SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(value: job.progress > 0 ? job.progress : null),
          )
        : PopupMenuButton<String>(
            enabled: !_busy,
            onSelected: (action) => switch (action) {
              'play' => _play(job),
              'save' => _save(job),
              'phone' => _deletePhone(job),
              'retry' => _retry(job),
              _ => _deleteServer(job),
            },
            itemBuilder: (_) => [
              if (job.ready) PopupMenuItem(value: 'play', child: Text(context.l10n.mashupPlay)),
              if (job.ready && _savedCopy(job) == null)
                PopupMenuItem(value: 'save', child: Text(context.l10n.mashupSaveOffline)),
              if (_savedCopy(job) != null) PopupMenuItem(value: 'phone', child: Text(context.l10n.mashupDeletePhone)),
              if (!job.ready && !job.waiting) PopupMenuItem(value: 'retry', child: Text(context.l10n.featureRetry)),
              PopupMenuItem(value: 'server', child: Text(context.l10n.mashupDeleteServer)),
            ],
          ),
  );

  Widget _savedTile(SavedMashup saved) => ListTile(
    leading: const Icon(Icons.download_done),
    title: Text(context.l10n.mashupOver(saved.singer.name ?? '', saved.band.name ?? '')),
    subtitle: saved.job.plan == null ? null : Text(_describe(saved.job.plan!)),
    onTap: _busy ? null : () => _playSaved(saved),
    trailing: PopupMenuButton<String>(
      enabled: !_busy,
      onSelected: (action) => action == 'play' ? _playSaved(saved) : _deletePhone(saved.job),
      itemBuilder: (_) => [
        PopupMenuItem(value: 'play', child: Text(context.l10n.mashupPlay)),
        PopupMenuItem(value: 'phone', child: Text(context.l10n.mashupDeletePhone)),
      ],
    ),
  );

  Widget _heading(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
    child: Text(text, style: Theme.of(context).textTheme.titleMedium),
  );

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final item = widget.item;
    final offline = _offline;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          item == null ? l10n.mashups : l10n.mashupTitle(_songs[KaraokeService.songId(item.id.raw)]?.name ?? ''),
        ),
        actions: [
          IconButton(
            tooltip: l10n.featureRefresh,
            onPressed: _loadingJobs ? null : () => _loadJobs(),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        children: [
          if (_busy || _loadingJobs || _loadingPartners) const LinearProgressIndicator(),
          if (offline) Padding(padding: const EdgeInsets.all(16), child: Text(l10n.mashupOffline)),
          if (item != null && !offline) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: SegmentedButton<bool>(
                segments: [
                  ButtonSegment(value: true, icon: const Icon(TablerIcons.microphone_2), label: Text(l10n.mashupSings)),
                  ButtonSegment(value: false, icon: const Icon(TablerIcons.vinyl), label: Text(l10n.mashupBacks)),
                ],
                selected: {_sings},
                onSelectionChanged: _busy
                    ? null
                    : (selected) {
                        setState(() => _sings = selected.first);
                        unawaited(_loadPartners());
                      },
              ),
            ),
            _heading(l10n.mashupSuggestions),
            if (_partnersError != null)
              Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Text(_partnersError!))
            else if (!_loadingPartners && _partners.isEmpty)
              Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Text(l10n.mashupNoSuggestions)),
            for (final partner in _partners)
              ListTile(
                title: Text(_songs[partner.id]?.name ?? ''),
                subtitle: Text([_songs[partner.id]?.artists?.join(', ') ?? '', _describe(partner.plan)].join('\n')),
                isThreeLine: true,
                trailing: Text('${(partner.plan.score * 100).round()}%'),
                enabled: !_busy,
                onTap: () {
                  final (vocals, backing) = _pairWith(partner.id);
                  _confirm(vocals, backing, partner.plan);
                },
              ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: OutlinedButton.icon(
                onPressed: _busy ? null : _pick,
                icon: const Icon(Icons.search),
                label: Text(l10n.mashupPick),
              ),
            ),
          ],
          if (item == null && !offline) ...[
            _heading(l10n.mashupIdeas),
            if (_ideasError != null)
              Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Text(_ideasError!))
            else if (_ideas == null)
              const Padding(padding: EdgeInsets.all(16), child: LinearProgressIndicator())
            else if (_ideas!.isEmpty)
              Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Text(l10n.mashupIdeasNone)),
            for (final idea in _ideas ?? const <MashupIdea>[])
              ListTile(
                leading: const Icon(TablerIcons.arrows_join_2),
                title: Text(l10n.mashupOver(_name(idea.vocals), _name(idea.backing))),
                subtitle: Text(_describe(idea.plan)),
                trailing: Text('${(idea.plan.score * 100).round()}%'),
                enabled: !_busy,
                onTap: () => _confirm(idea.vocals, idea.backing, idea.plan),
              ),
          ],
          if (_saved.isNotEmpty) ...[_heading(l10n.mashupSavedOnPhone), for (final saved in _saved) _savedTile(saved)],
          if (!offline) ...[
            _heading(l10n.mashupYours),
            if (_error != null) Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Text(_error!)),
            if (_error == null && !_loadingJobs && _jobs.isEmpty)
              Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Text(l10n.mashupNone)),
            for (final job in _jobs) _jobTile(job),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

/// Finds a song in the library by name.
class _SongSearchDialog extends StatefulWidget {
  const _SongSearchDialog({required this.search});
  final Future<List<BaseItemDto>> Function(String term) search;

  @override
  State<_SongSearchDialog> createState() => _SongSearchDialogState();
}

class _SongSearchDialogState extends State<_SongSearchDialog> {
  List<BaseItemDto> _results = [];
  Timer? _debounce;
  bool _searching = false;
  String? _error;
  int _generation = 0;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _changed(String term) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () async {
      final generation = ++_generation;
      if (term.trim().length < 2) {
        setState(() {
          _results = [];
          _searching = false;
        });
        return;
      }
      setState(() => _searching = true);
      try {
        final results = await widget.search(term.trim());
        if (mounted && generation == _generation) {
          setState(() {
            _results = results;
            _error = null;
          });
        }
      } catch (error) {
        if (mounted && generation == _generation) setState(() => _error = '$error');
      } finally {
        if (mounted && generation == _generation) setState(() => _searching = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(context.l10n.mashupPick),
    contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
    content: SizedBox(
      width: double.maxFinite,
      height: 420,
      child: Column(
        children: [
          TextField(
            autofocus: true,
            decoration: InputDecoration(hintText: context.l10n.mashupSearch, prefixIcon: const Icon(Icons.search)),
            onChanged: _changed,
          ),
          if (_searching) const LinearProgressIndicator(),
          if (_error != null) Padding(padding: const EdgeInsets.all(8), child: Text(_error!)),
          Expanded(
            child: ListView(
              children: [
                for (final song in _results)
                  ListTile(
                    title: Text(song.name ?? ''),
                    subtitle: Text(song.artists?.join(', ') ?? ''),
                    onTap: () => Navigator.of(context).pop(song),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
      ),
    ],
  );
}
