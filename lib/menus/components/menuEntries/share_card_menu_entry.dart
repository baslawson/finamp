import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/components/share_card.dart';
import 'package:finamp/menus/components/menuEntries/menu_entry.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

import '../../../extensions/localizations.dart';

/// Shares a "now playing" image of a track.
class ShareCardMenuEntry extends StatelessWidget implements HideableMenuEntry {
  final BaseItemDto baseItem;

  const ShareCardMenuEntry({super.key, required this.baseItem});

  @override
  Widget build(BuildContext context) {
    return MenuEntry(
      icon: TablerIcons.photo_share,
      title: context.l10n.shareCard,
      onTap: () async {
        final lyric = currentLyricLine(baseItem);
        Navigator.pop(context); // close menu
        final appContext = GlobalSnackbar.rawMaterialAppNavigatorKey.currentContext;
        if (appContext != null && appContext.mounted) await showShareCard(appContext, baseItem, lyric: lyric);
      },
    );
  }

  @override
  bool get isVisible => true;
}
