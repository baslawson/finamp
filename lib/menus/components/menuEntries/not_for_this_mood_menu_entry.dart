import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/menus/components/menuEntries/menu_entry.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/mood_notes.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

/// What the AI DJ mix a song in the queue (or, without one, the song playing) came from was asked for, if any.
final _moodRequestProvider = Provider.autoDispose.family<String?, FinampQueueItem?>((ref, queueItem) {
  final queueService = GetIt.instance<QueueService>();
  final source = queueItem?.source ?? queueService.getCurrentTrack()?.source ?? queueService.getQueue().source;
  return MoodNotes.requestFor(source);
});

/// "Not for this mood": during an AI DJ mix, says this song doesn't fit what was asked for, so it leaves the mix and the
/// AI leaves it out of mixes for similar requests.
class NotForThisMoodMenuEntry extends ConsumerWidget implements HideableMenuEntry {
  const NotForThisMoodMenuEntry({super.key, required this.item, this.queueItem});

  final BaseItemDto item;

  /// The song in the queue, to take out of it.
  final FinampQueueItem? queueItem;

  @override
  bool get isVisible => true;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final request = ref.watch(_moodRequestProvider(queueItem));
    if (request == null || item.type != "Audio") return const SizedBox.shrink();
    return MenuEntry(
      icon: TablerIcons.mood_off,
      title: context.l10n.notForThisMood,
      onTap: () async {
        Navigator.pop(context); // close menu
        try {
          await MoodNotes.add(item, request);
        } catch (e) {
          GlobalSnackbar.error(e);
          return;
        }
        final queueService = GetIt.instance<QueueService>();
        final queued = queueItem;
        if (queued != null) {
          // The song playing is skipped (and stays in what's been played); a later one leaves the queue.
          if (queueService.getQueue().getOffsetForQueueItem(queued) == 0) {
            await queueService.skipByOffset(1);
          } else {
            await queueService.removeQueueItem(queued);
          }
        }
        GlobalSnackbar.message((context) => context.l10n.notForThisMoodDone, isConfirmation: true);
      },
    );
  }
}
