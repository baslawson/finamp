import 'dart:async';

import 'package:finamp/components/confirmation_prompt_dialog.dart';
import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/l10n/app_localizations.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/finamp_user_helper.dart';
import 'package:finamp/services/jellyfin_api_helper.dart';
import 'package:finamp/services/smart_playlist_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

String _playCountName(AppLocalizations l10n, PlayCountRule rule) => switch (rule) {
  PlayCountRule.any => l10n.smartPlaylistPlaysAny,
  PlayCountRule.never => l10n.smartPlaylistPlaysNever,
  PlayCountRule.rarely => l10n.smartPlaylistPlaysRarely,
  PlayCountRule.often => l10n.smartPlaylistPlaysOften,
};

String _orderName(AppLocalizations l10n, SmartPlaylistOrder order) => switch (order) {
  SmartPlaylistOrder.random => l10n.smartPlaylistOrderRandom,
  SmartPlaylistOrder.mostPlayed => l10n.smartPlaylistOrderMostPlayed,
  SmartPlaylistOrder.leastPlayed => l10n.smartPlaylistOrderLeastPlayed,
  SmartPlaylistOrder.newestRelease => l10n.smartPlaylistOrderNewest,
  SmartPlaylistOrder.oldestRelease => l10n.smartPlaylistOrderOldest,
  SmartPlaylistOrder.recentlyAdded => l10n.smartPlaylistOrderRecentlyAdded,
};

/// A one-line description of [playlist]'s rules.
String describeRules(AppLocalizations l10n, SmartPlaylist playlist) => [
  if (playlist.genres.isNotEmpty) playlist.genres.join(", "),
  if (playlist.fromYear != null || playlist.toYear != null) "${playlist.fromYear ?? "…"}–${playlist.toYear ?? "…"}",
  if (playlist.favoritesOnly) l10n.smartPlaylistFavoritesOnly,
  if (playlist.playCount != PlayCountRule.any) _playCountName(l10n, playlist.playCount),
  _orderName(l10n, playlist.order),
].join(" · ");

/// The smart playlists on this phone.
class SmartPlaylistsScreen extends StatefulWidget {
  const SmartPlaylistsScreen({super.key});

  static const routeName = "/smartplaylists";

  @override
  State<SmartPlaylistsScreen> createState() => _SmartPlaylistsScreenState();
}

class _SmartPlaylistsScreenState extends State<SmartPlaylistsScreen> {
  List<SmartPlaylist>? _playlists;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final playlists = await SmartPlaylistService.load();
    if (mounted) setState(() => _playlists = playlists);
  }

  Future<void> _edit(SmartPlaylist? playlist) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (context) => SmartPlaylistEditorScreen(playlist: playlist)),
    );
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final playlists = _playlists;
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.smartPlaylists)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(null),
        icon: const Icon(TablerIcons.plus),
        label: Text(context.l10n.smartPlaylistNew),
      ),
      body: playlists == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.only(bottom: 96),
              children: [
                Padding(padding: const EdgeInsets.all(16), child: Text(context.l10n.smartPlaylistsDescription)),
                if (playlists.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(context.l10n.smartPlaylistsNone, textAlign: TextAlign.center),
                  ),
                for (final playlist in playlists)
                  ListTile(
                    leading: Icon(playlist.playlistId == null ? TablerIcons.wand : TablerIcons.cloud_check),
                    title: Text(playlist.name),
                    subtitle: Text(
                      [
                        describeRules(context.l10n, playlist),
                        playlist.playlistId == null
                            ? context.l10n.smartPlaylistLocalOnly
                            : context.l10n.smartPlaylistSynced,
                      ].join("\n"),
                    ),
                    isThreeLine: true,
                    onTap: () => _edit(playlist),
                    trailing: IconButton(
                      tooltip: context.l10n.smartPlaylistPlay,
                      icon: const Icon(TablerIcons.player_play),
                      onPressed: () async {
                        try {
                          await SmartPlaylistService.play(playlist);
                        } catch (e) {
                          GlobalSnackbar.error(e);
                        }
                      },
                    ),
                  ),
              ],
            ),
    );
  }
}

/// Edits the rules of a smart playlist, with a live preview of what matches.
class SmartPlaylistEditorScreen extends StatefulWidget {
  const SmartPlaylistEditorScreen({super.key, this.playlist});

  final SmartPlaylist? playlist;

  @override
  State<SmartPlaylistEditorScreen> createState() => _SmartPlaylistEditorScreenState();
}

class _SmartPlaylistEditorScreenState extends State<SmartPlaylistEditorScreen> {
  static const _firstYear = 1950;

  late final SmartPlaylist _playlist =
      widget.playlist?.copy() ?? SmartPlaylist(id: DateTime.now().microsecondsSinceEpoch.toString(), name: "");
  late final _name = TextEditingController(text: _playlist.name);
  List<String>? _genres;
  List<BaseItemDto>? _preview;
  Timer? _debounce;
  int _previewRun = 0;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadGenres());
    _refreshPreview();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _name.dispose();
    super.dispose();
  }

  Future<void> _loadGenres() async {
    try {
      final genres =
          await GetIt.instance<JellyfinApiHelper>().getItems(
            parentItem: GetIt.instance<FinampUserHelper>().currentUser?.currentView,
            includeItemTypes: BaseItemDtoType.genre.jellyfinName,
            sortBy: "SortName",
          ) ??
          [];
      if (mounted) setState(() => _genres = genres.map((genre) => genre.name ?? "").where((name) => name.isNotEmpty).toList());
    } catch (e) {
      if (mounted) setState(() => _genres = []);
    }
  }

  void _changed(void Function() change) {
    setState(change);
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), _refreshPreview);
  }

  Future<void> _refreshPreview() async {
    final run = ++_previewRun;
    setState(() => _preview = null);
    try {
      final tracks = await SmartPlaylistService.tracks(_playlist);
      if (mounted && run == _previewRun) setState(() => _preview = tracks);
    } catch (e) {
      if (mounted && run == _previewRun) setState(() => _preview = []);
      GlobalSnackbar.error(e);
    }
  }

  String get _effectiveName => _name.text.trim().isEmpty ? context.l10n.smartPlaylistDefaultName : _name.text.trim();

  Future<void> _save({required bool sync}) async {
    _playlist.name = _effectiveName;
    if (sync) {
      var confirmed = false;
      await showDialog<void>(
        context: context,
        builder: (context) => ConfirmationPromptDialog(
          promptText: _playlist.playlistId == null
              ? context.l10n.smartPlaylistCreatePrompt(_playlist.name)
              : context.l10n.smartPlaylistUpdatePrompt(_playlist.name),
          confirmButtonText: context.l10n.smartPlaylistSaveToJellyfin,
          onConfirmed: () => confirmed = true,
        ),
      );
      if (!confirmed) return;
    }
    setState(() => _busy = true);
    try {
      if (sync) {
        final count = await SmartPlaylistService.sync(_playlist);
        GlobalSnackbar.message((context) => context.l10n.smartPlaylistSaved(count), isConfirmation: true);
      } else {
        await SmartPlaylistService.save(_playlist);
      }
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      GlobalSnackbar.error(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    var confirmed = false;
    await showDialog<void>(
      context: context,
      builder: (context) => ConfirmationPromptDialog(
        promptText: context.l10n.smartPlaylistDeletePrompt,
        confirmButtonText: context.l10n.smartPlaylistDelete,
        onConfirmed: () => confirmed = true,
      ),
    );
    if (!confirmed) return;
    await SmartPlaylistService.delete(_playlist);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final textTheme = Theme.of(context).textTheme;
    final thisYear = DateTime.now().year;
    final preview = _preview;
    final yearsOn = _playlist.fromYear != null || _playlist.toYear != null;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.playlist == null ? l10n.smartPlaylistNew : l10n.smartPlaylistEdit),
        actions: [
          if (widget.playlist != null)
            IconButton(tooltip: l10n.smartPlaylistDelete, onPressed: _delete, icon: const Icon(TablerIcons.trash)),
          IconButton(
            tooltip: l10n.smartPlaylistSaveRules,
            onPressed: _busy ? null : () => _save(sync: false),
            icon: const Icon(TablerIcons.check),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          TextField(
            controller: _name,
            decoration: InputDecoration(labelText: l10n.smartPlaylistName, hintText: l10n.smartPlaylistDefaultName),
            textCapitalization: TextCapitalization.sentences,
          ),
          const SizedBox(height: 20),
          Text(l10n.smartPlaylistGenres, style: textTheme.titleMedium),
          const SizedBox(height: 4),
          if (_genres == null)
            const LinearProgressIndicator()
          else
            Wrap(
              spacing: 6,
              runSpacing: 2,
              children: [
                for (final genre in {..._playlist.genres, ..._genres!})
                  FilterChip(
                    label: Text(genre),
                    selected: _playlist.genres.contains(genre),
                    onSelected: (selected) => _changed(
                      () => _playlist.genres = selected
                          ? [..._playlist.genres, genre]
                          : _playlist.genres.where((other) => other != genre).toList(),
                    ),
                  ),
              ],
            ),
          if (_playlist.genres.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(l10n.smartPlaylistAllGenres, style: textTheme.bodySmall),
            ),
          const SizedBox(height: 12),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.smartPlaylistYears),
            subtitle: yearsOn ? Text("${_playlist.fromYear}–${_playlist.toYear}") : null,
            value: yearsOn,
            onChanged: (on) => _changed(() {
              _playlist.fromYear = on ? 1990 : null;
              _playlist.toYear = on ? 1999 : null;
            }),
          ),
          if (yearsOn)
            RangeSlider(
              values: RangeValues(
                (_playlist.fromYear ?? _firstYear).clamp(_firstYear, thisYear).toDouble(),
                (_playlist.toYear ?? thisYear).clamp(_firstYear, thisYear).toDouble(),
              ),
              min: _firstYear.toDouble(),
              max: thisYear.toDouble(),
              divisions: thisYear - _firstYear,
              onChanged: (values) => _changed(() {
                _playlist.fromYear = values.start.round();
                _playlist.toYear = values.end.round();
              }),
            ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.smartPlaylistFavoritesOnly),
            value: _playlist.favoritesOnly,
            onChanged: (on) => _changed(() => _playlist.favoritesOnly = on),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.smartPlaylistLeaveOutSkipped),
            value: _playlist.leaveOutSkipped,
            onChanged: (on) => _changed(() => _playlist.leaveOutSkipped = on),
          ),
          const SizedBox(height: 8),
          Text(l10n.smartPlaylistPlays, style: textTheme.titleMedium),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            children: [
              for (final rule in PlayCountRule.values)
                ChoiceChip(
                  label: Text(_playCountName(l10n, rule)),
                  selected: _playlist.playCount == rule,
                  onSelected: (_) => _changed(() => _playlist.playCount = rule),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Text(l10n.smartPlaylistOrder, style: textTheme.titleMedium),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            children: [
              for (final order in SmartPlaylistOrder.values)
                ChoiceChip(
                  label: Text(_orderName(l10n, order)),
                  selected: _playlist.order == order,
                  onSelected: (_) => _changed(() => _playlist.order = order),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Text(l10n.smartPlaylistSize(_playlist.size), style: textTheme.titleMedium),
          Slider(
            value: _playlist.size.toDouble(),
            min: 25,
            max: 500,
            divisions: 19,
            onChanged: (size) => setState(() => _playlist.size = size.round()),
            onChangeEnd: (size) => _changed(() => _playlist.size = size.round()),
          ),
          const Divider(height: 32),
          Text(
            preview == null ? l10n.smartPlaylistMatching : l10n.smartPlaylistMatches(preview.length),
            style: textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          if (preview == null) const LinearProgressIndicator(),
          for (final track in preview?.take(8) ?? const <BaseItemDto>[])
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Text(
                "${track.name ?? ""} · ${track.albumArtist ?? track.artists?.firstOrNull ?? ""}",
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: preview == null || preview.isEmpty || _busy
                      ? null
                      : () async {
                          _playlist.name = _effectiveName;
                          await SmartPlaylistService.play(_playlist, tracks: preview);
                        },
                  icon: const Icon(TablerIcons.player_play),
                  label: Text(l10n.smartPlaylistPlay),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: preview == null || preview.isEmpty || _busy ? null : () => _save(sync: true),
                  icon: const Icon(TablerIcons.cloud_upload),
                  label: Text(l10n.smartPlaylistSaveToJellyfin),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(l10n.smartPlaylistSyncExplained, style: textTheme.bodySmall),
        ],
      ),
    );
  }
}
