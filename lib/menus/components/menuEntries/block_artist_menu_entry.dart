import 'package:finamp/components/block_artist_dialog.dart';
import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/menus/components/menuEntries/menu_entry.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/artist_spacing.dart';
import 'package:finamp/services/listening_preferences.dart';
import 'package:flutter/material.dart';

/// "Block artist…": an artist, or the artists credited on a song, left out for a while or for good.
class BlockArtistMenuEntry extends StatelessWidget implements HideableMenuEntry {
  const BlockArtistMenuEntry({super.key, required this.item});

  /// An artist, or a song.
  final BaseItemDto item;

  List<BlockableArtist> get _artists => item.type == "MusicArtist"
      ? [if (item.name case final name? when ArtistSpacing.keyOfName(name) != null) (name: name, id: item.id.raw)]
      : ListeningPreferences.artistsOf(item);

  @override
  bool get isVisible => _artists.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final artists = _artists;
    if (artists.isEmpty) return const SizedBox.shrink();
    return MenuEntry(
      icon: Icons.block,
      title: artists.length == 1 && item.type == "MusicArtist"
          ? context.l10n.blockArtist
          : context.l10n.blockSongArtist,
      onTap: () async {
        // Over the menu, which closes once something was blocked or unblocked.
        if (await showBlockArtistDialog(context, artists) && context.mounted) Navigator.of(context).pop();
      },
    );
  }
}
