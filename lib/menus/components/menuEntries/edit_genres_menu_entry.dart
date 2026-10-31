import 'package:finamp/components/MusicScreen/music_screen_tab_view.dart';
import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/menus/components/menuEntries/menu_entry.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/ai_dj_service.dart';
import 'package:finamp/services/album_screen_provider.dart';
import 'package:finamp/services/genre_screen_provider.dart';
import 'package:finamp/services/item_by_id_provider.dart';
import 'package:finamp/services/genre_editor.dart';
import 'package:finamp/services/permission_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

/// "Edit genres…": changes a song's or an album's genres in Jellyfin, for administrators. An album's songs get the
/// same genres.
class EditGenresMenuEntry extends ConsumerWidget implements HideableMenuEntry {
  const EditGenresMenuEntry({super.key, required this.item});

  final BaseItemDto item;

  @override
  bool get isVisible => true;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(canEditMetadataProvider) || (item.type != "Audio" && item.type != "MusicAlbum")) {
      return const SizedBox.shrink();
    }
    return MenuEntry(
      icon: TablerIcons.tag,
      title: context.l10n.editGenresAction,
      onTap: () => showDialog<void>(
        context: context,
        builder: (_) => EditGenresDialog(item: item),
      ),
    );
  }
}

class EditGenresDialog extends StatefulWidget {
  const EditGenresDialog({super.key, required this.item});

  final BaseItemDto item;

  /// The library's genres, offered while typing.
  @visibleForTesting
  static Future<List<NameLongIdPair>> Function() libraryGenres = () => AiDjService.loadGenres().then(
    (genres) => [for (final genre in genres) NameLongIdPair(name: genre.name, id: genre.id)],
  );

  @override
  State<EditGenresDialog> createState() => _EditGenresDialogState();
}

class _EditGenresDialogState extends State<EditGenresDialog> {
  List<String>? _genres;

  /// The library's genres, offered while typing.
  List<String> _known = const [];

  /// Their ids, by name in lower case.
  Map<String, BaseItemId> _knownIds = const {};

  /// For an album, its songs, which get the same genres.
  List<String> _songs = const [];
  Object? _error;
  bool _saving = false;

  /// What's being typed: added when saving, too, so a genre typed without pressing Done isn't lost.
  TextEditingController? _field;

  bool get _album => widget.item.type == "MusicAlbum";

  @override
  void initState() {
    super.initState();
    () async {
      try {
        final id = widget.item.id.raw;
        final genres = await GenreEditor.genresOf(id);
        final songs = _album ? await GenreEditor.songsOf(id) : const <String>[];
        final known = await EditGenresDialog.libraryGenres().catchError((Object _) => const <NameLongIdPair>[]);
        if (mounted) {
          setState(() {
            _genres = genres;
            _songs = songs;
            _known = [for (final genre in known) ?genre.name];
            _knownIds = {
              for (final genre in [...known, ...?widget.item.genreItems])
                if (genre.name case final name?) name.toLowerCase(): genre.id,
            };
          });
        }
      } catch (e) {
        if (mounted) setState(() => _error = e);
      }
    }();
  }

  /// The library's genres matching [typed] that aren't among [genres] yet.
  Iterable<String> _options(String typed, List<String> genres) {
    final wanted = typed.trim().toLowerCase();
    if (wanted.isEmpty) return const [];
    final have = {for (final genre in genres) genre.toLowerCase()};
    return _known.where((genre) => genre.toLowerCase().contains(wanted) && !have.contains(genre.toLowerCase())).take(8);
  }

  void _add(String genre) {
    final genres = _genres;
    if (genres == null) return;
    setState(() => _genres = GenreEditor.tidy([...genres, genre]));
  }

  Future<void> _save() async {
    final chosen = _genres;
    if (chosen == null || _saving) return;
    final genres = GenreEditor.tidy([...chosen, ?_field?.text]);
    setState(() => _saving = true);
    GenreEditorAccount? who;
    try {
      // The account it's saved with, which save takes too.
      who = GenreEditor.signedIn;
      final saved = await GenreEditor.save([widget.item.id.raw, ..._songs], genres, album: _album);
      await _showSaved(genres, saved, who);
      if (mounted) Navigator.of(context).pop();
      GlobalSnackbar.message((context) => context.l10n.editGenresSaved(saved.length), isConfirmation: true);
    } on GenreEditException catch (e) {
      // The ones that were saved show it.
      await _showSaved(genres, e.savedIds, who!);
      if (mounted) setState(() => _saving = false);
      GlobalSnackbar.message((context) => context.l10n.editGenresFailed(e.saved, e.total, e.reason));
    } catch (e) {
      if (mounted) setState(() => _saving = false);
      GlobalSnackbar.error(e);
    }
  }

  /// Shows the [genres] at once on the items [saved]: on this item, which the menu and screen behind show, and in
  /// what's been loaded from Jellyfin (the items, album and playlist lists, genre pages, the music screen's lists,
  /// filtered by genre too), which loads again.
  Future<void> _showSaved(List<String> genres, List<String> saved, GenreEditorAccount who) async {
    if (saved.isEmpty) return;
    final item = widget.item;
    // The album's songs have the same genres now: the same genre items.
    final shown = await GenreEditor.showSaved(
      saved,
      who,
      // With the ids known for them. A genre new to the library has none until Jellyfin's is read.
      genres: [
        for (final genre in genres)
          NameLongIdPair(name: genre, id: _knownIds[genre.toLowerCase()] ?? const BaseItemId("")),
      ],
    );
    if (saved.contains(item.id.raw)) {
      item.genreItems = shown;
      item.genres = shown == null ? genres : [for (final genre in shown) ?genre.name];
    }
    // After the edit is known, so what loads again shows on copies loaded before too.
    musicScreenRefreshStream.add(null);
    if (!GetIt.instance.isRegistered<ProviderContainer>()) return;
    final container = GetIt.instance<ProviderContainer>();
    for (final id in saved) {
      container.invalidate(itemByIdProvider(BaseItemId(id)));
    }
    container
      ..invalidate(getAlbumOrPlaylistTracksProvider)
      ..invalidate(getDefaultSortedPlaylistTracksProvider)
      ..invalidate(getSortedPlaylistTracksProvider)
      ..invalidate(genreCuratedItemsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final genres = _genres;
    return AlertDialog(
      title: Text(context.l10n.editGenresTitle(widget.item.name ?? "")),
      content: SizedBox(
        width: 360,
        child: _error != null
            ? Text(context.l10n.editGenresUnavailable)
            : genres == null
            ? const Center(heightFactor: 2, child: CircularProgressIndicator())
            // Scrolls when many genres and the keyboard leave too little room.
            : SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (genres.isEmpty) Text(context.l10n.editGenresNone),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        for (final genre in genres)
                          InputChip(
                            label: Text(genre),
                            onDeleted: _saving
                                ? null
                                : () => setState(() => _genres = [...genres.where((other) => other != genre)]),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Autocomplete<String>(
                      optionsBuilder: (value) => _options(value.text, genres),
                      onSelected: (genre) {
                        _add(genre);
                        _field?.clear();
                      },
                      fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) => TextField(
                        controller: _field = controller,
                        focusNode: focusNode,
                        enabled: !_saving,
                        textCapitalization: TextCapitalization.words,
                        decoration: InputDecoration(
                          hintText: context.l10n.editGenresAdd,
                          prefixIcon: const Icon(TablerIcons.plus),
                        ),
                        onSubmitted: (text) {
                          // A suggestion showing is the one chosen; otherwise the genre as typed.
                          if (_options(text, genres).isNotEmpty) return onFieldSubmitted();
                          _add(text);
                          controller.clear();
                        },
                      ),
                    ),
                    if (_album) ...[
                      const SizedBox(height: 12),
                      Text(
                        context.l10n.editGenresAlbumNote(_songs.length),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ],
                ),
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        FilledButton(
          onPressed: genres == null || _saving ? null : _save,
          child: Text(MaterialLocalizations.of(context).saveButtonLabel),
        ),
      ],
    );
  }
}
