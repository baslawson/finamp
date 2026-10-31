import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/menus/components/menuEntries/menu_entry.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/analyzer_service.dart';
import 'package:finamp/services/dj_transition_service.dart';
import 'package:finamp/services/jellyfin_api_helper.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

import '../../../extensions/localizations.dart';
import '../../../services/finamp_settings_helper.dart';

final _analyzerConfiguredProvider = FutureProvider.autoDispose((ref) => AnalyzerService.isConfigured());

/// Plays songs that sound like this one, judged by the analyzer from the audio itself rather than by tags.
class MoreLikeThisMenuEntry extends ConsumerWidget implements HideableMenuEntry {
  final BaseItemDto baseItem;

  const MoreLikeThisMenuEntry({super.key, required this.baseItem});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final configured = ref.watch(_analyzerConfiguredProvider).valueOrNull ?? false;
    if (!configured || baseItem.type != "Audio") return const SizedBox.shrink();
    final offline = ref.watch(finampSettingsProvider.isOffline);
    return MenuEntry(
      icon: TablerIcons.wave_sine,
      title: context.l10n.moreLikeThis,
      enabled: !offline,
      tooltip: offline ? context.l10n.notAvailableInOfflineMode : null,
      onTap: () async {
        Navigator.pop(context); // close menu
        try {
          await playMoreLike(baseItem);
          GlobalSnackbar.message((context) => context.l10n.startingMoreLikeThis, isConfirmation: true);
        } on AnalyzerException catch (e) {
          GlobalSnackbar.message((context) => e.message.contains("404") ? context.l10n.songNotAnalyzedYet : e.message);
        } catch (e) {
          GlobalSnackbar.error(e);
        }
      },
    );
  }

  @override
  bool get isVisible => true;
}

/// Starts a mix of [seed] followed by the songs that sound most like it, spread out by artist.
Future<void> playMoreLike(BaseItemDto seed) async {
  final ids = await AnalyzerService.similar(seed.id.raw, limit: 60);
  final tracks =
      await GetIt.instance<JellyfinApiHelper>().getItems(itemIds: [for (final id in ids) BaseItemId(id)]) ?? [];
  final byId = {for (final track in tracks) track.id.raw.replaceAll("-", ""): track};
  final similar = [for (final id in ids) ?byId[id.replaceAll("-", "")]];
  await GetIt.instance<QueueService>().startPlayback(
    // The song asked about first, then the rest flowing by key and tempo, without the same artist twice in a row.
    items: await DjTransitionService.smoothOrder([seed, ...similar]),
    source: QueueItemSource.rawId(
      type: QueueItemSourceType.unknown,
      name: QueueItemSourceName(
        type: QueueItemSourceNameType.preTranslated,
        pretranslatedName: "Sounds like ${seed.name ?? ""}",
      ),
      id: "moreLikeThis",
    ),
    order: FinampPlaybackOrder.linear,
  );
}
