import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/menus/components/menuEntries/menu_entry.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/screens/karaoke_screen.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:finamp/services/karaoke_service.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

/// Preparation does not interrupt playback or replace the queue.
class PrepareKaraokeMenuEntry extends ConsumerWidget implements HideableMenuEntry {
  const PrepareKaraokeMenuEntry({super.key, required this.item});
  final BaseItemDto item;
  @override
  bool get isVisible => item.type == 'Audio';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!isVisible) return const SizedBox.shrink();
    final offline = ref.watch(finampSettingsProvider.isOffline);
    final current = GetIt.instance<QueueService>().getCurrentTrack()?.baseItem.id == item.id;
    return MenuEntry(
      icon: TablerIcons.microphone_2,
      title: current ? context.l10n.karaoke : context.l10n.karaokePrepare,
      enabled: !offline || current,
      onTap: () async {
        final navigator = Navigator.of(context);
        navigator.pop();
        if (current) {
          await navigator.pushNamed(KaraokeScreen.routeName);
          return;
        }
        try {
          await KaraokeService.instance.prepare(item.id.raw);
          GlobalSnackbar.message((context) => context.l10n.karaokePreparing, isConfirmation: true);
        } catch (error) {
          GlobalSnackbar.error(error);
        }
      },
    );
  }
}
