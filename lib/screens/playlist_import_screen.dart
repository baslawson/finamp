import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/item_helper.dart';
import 'package:finamp/services/library_matcher.dart';
import 'package:finamp/services/playlist_import_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

/// Rebuilds a playlist from another service out of the songs in the user's library.
class PlaylistImportScreen extends StatefulWidget {
  const PlaylistImportScreen({super.key});

  static const routeName = "/playlistimport";

  @override
  State<PlaylistImportScreen> createState() => _PlaylistImportScreenState();
}

class _PlaylistImportScreenState extends State<PlaylistImportScreen> {
  final _input = TextEditingController();
  final _name = TextEditingController();
  List<SongRef>? _songs;
  List<BaseItemDto?>? _matches;
  int _matched = 0;
  bool _busy = false;

  @override
  void dispose() {
    _input.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ["csv", "txt"]);
    final path = result?.files.single.path;
    if (path == null) return;
    _input.text = await File(path).readAsString();
    await _read();
  }

  Future<void> _read() async {
    FocusScope.of(context).unfocus();
    final noSongs = context.l10n.importNoSongs;
    setState(() {
      _busy = true;
      _songs = null;
      _matches = null;
      _matched = 0;
    });
    try {
      final playlist = await PlaylistImportService.read(_input.text);
      if (playlist.songs.isEmpty) throw PlaylistImportException(noSongs);
      _name.text = playlist.name ?? "";
      setState(() => _songs = playlist.songs);
      final matches = await LibraryMatcher.findAll(
        playlist.songs,
        onProgress: (done) {
          if (mounted) setState(() => _matched = done);
        },
      );
      if (mounted) setState(() => _matches = matches);
    } catch (e) {
      GlobalSnackbar.error(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _create() async {
    final tracks = _matches!.nonNulls.toList();
    final name = _name.text.trim().isEmpty ? context.l10n.importDefaultName : _name.text.trim();
    setState(() => _busy = true);
    try {
      final playlist = await PlaylistImportService.createPlaylist(name, tracks);
      GlobalSnackbar.message((context) => context.l10n.importCreated(name, tracks.length), isConfirmation: true);
      if (mounted) openItemPage(playlist, Navigator.of(context), showTracks: true);
    } catch (e) {
      GlobalSnackbar.error(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final songs = _songs;
    final matches = _matches;
    final found = matches?.nonNulls.length ?? 0;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.importPlaylist)),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          Text(context.l10n.importDescription),
          const SizedBox(height: 12),
          TextField(
            controller: _input,
            minLines: 1,
            maxLines: 6,
            keyboardType: TextInputType.multiline,
            decoration: InputDecoration(
              hintText: context.l10n.importHint,
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: const Icon(TablerIcons.file_import),
                tooltip: context.l10n.importOpenFile,
                onPressed: _busy ? null : _pickFile,
              ),
            ),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _busy ? null : _read,
            icon: const Icon(TablerIcons.list_search),
            label: Text(context.l10n.importFindSongs),
          ),
          if (songs != null && matches == null) ...[
            const SizedBox(height: 16),
            LinearProgressIndicator(value: _matched / songs.length),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(context.l10n.importMatching(_matched, songs.length)),
            ),
          ],
          if (songs != null && matches != null) ...[
            const Divider(height: 32),
            Text(context.l10n.importFound(found, songs.length), style: textTheme.titleMedium),
            const SizedBox(height: 12),
            TextField(
              controller: _name,
              decoration: InputDecoration(
                labelText: context.l10n.importPlaylistName,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _busy || found == 0 ? null : _create,
              icon: const Icon(TablerIcons.playlist_add),
              label: Text(context.l10n.importCreate),
            ),
            const SizedBox(height: 8),
            for (final (index, song) in songs.indexed)
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                leading: Icon(
                  matches[index] == null ? TablerIcons.circle_x : TablerIcons.circle_check,
                  color: matches[index] == null ? Theme.of(context).colorScheme.outline : null,
                ),
                title: Text(matches[index]?.name ?? song.title),
                subtitle: Text(
                  matches[index] == null
                      ? "${song.artist} · ${context.l10n.importNotInLibrary}"
                      // The track's own artists, since compilations have "Various Artists" as album artist.
                      : matches[index]!.artists?.join(", ") ?? matches[index]!.albumArtist ?? song.artist,
                ),
              ),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
