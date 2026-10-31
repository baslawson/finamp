import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/menus/components/menuEntries/menu_entry.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/screens/mashup_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

/// Opens mashups for the song: partners the server suggests, or one picked by hand. Saved mashups play offline too.
class MashupMenuEntry extends StatelessWidget implements HideableMenuEntry {
  const MashupMenuEntry({super.key, required this.item});
  final BaseItemDto item;

  @override
  bool get isVisible => item.type == 'Audio';

  @override
  Widget build(BuildContext context) {
    if (!isVisible) return const SizedBox.shrink();
    return MenuEntry(
      icon: TablerIcons.arrows_join_2,
      title: context.l10n.mashupMenu,
      onTap: () {
        final navigator = Navigator.of(context);
        navigator.pop();
        navigator.push(
          MaterialPageRoute<void>(
            builder: (_) => MashupScreen(item: item),
            settings: const RouteSettings(name: MashupScreen.routeName),
          ),
        );
      },
    );
  }
}
