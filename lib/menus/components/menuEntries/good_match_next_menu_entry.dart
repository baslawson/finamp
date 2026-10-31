import 'package:finamp/components/menu_sheet.dart';
import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/menus/components/menuEntries/menu_entry.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/models/music_slices.dart';
import 'package:finamp/services/analyzer_service.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:finamp/services/good_match.dart';
import 'package:finamp/services/jellyfin_api_helper.dart';
import 'package:finamp/services/listening_preferences.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

/// For the song playing: offers a few songs that would follow on well from it (sounding alike, in a matching key and
/// tempo) to play next, without changing the rest of the queue.
class GoodMatchNextMenuEntry extends ConsumerWidget implements HideableMenuEntry {
  const GoodMatchNextMenuEntry({super.key, required this.baseItem});

  final BaseItemDto baseItem;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final configured = ref.watch(analyzerConfiguredProvider).valueOrNull ?? false;
    if (!configured || baseItem.type != "Audio") return const SizedBox.shrink();
    final offline = ref.watch(finampSettingsProvider.isOffline);
    return MenuEntry(
      icon: TablerIcons.arrow_merge_right,
      title: context.l10n.goodMatchNext,
      enabled: !offline,
      tooltip: offline ? context.l10n.notAvailableInOfflineMode : null,
      onTap: () {
        final navigator = Navigator.of(context);
        navigator.pop(); // close menu
        showMenuSheet<void>(
          context: navigator.context,
          builder: (context) => _GoodMatchSheet(seed: baseItem),
        );
      },
    );
  }

  @override
  bool get isVisible => true;
}

/// Up to [GoodMatch.count] songs that follow on well from [seed], best first, leaving out ones already queued and
/// resting songs.
Future<List<BaseItemDto>> loadGoodMatches(BaseItemDto seed) async {
  final ids = await AnalyzerService.similar(seed.id.raw, limit: 40);
  if (ids.isEmpty) return [];
  final tracks =
      await GetIt.instance<JellyfinApiHelper>().getItems(itemIds: [for (final id in ids) BaseItemId(id)]) ?? [];
  // In the analyzer's order, most alike first; ids may come back with or without dashes.
  String plain(String id) => id.replaceAll("-", "");
  final byId = {for (final track in tracks) plain(track.id.raw): track};
  final queue = GetIt.instance<QueueService>().getQueue();
  final playing = [
    seed,
    for (final item in [?queue.currentTrack, ...queue.nextUp, ...queue.queue]) item.baseItem,
  ];
  final similar = GoodMatch.candidates([for (final id in ids) ?byId[plain(id)]], playing);
  final analysis = await AnalyzerService.cachedAnalysis([seed.id.raw, for (final track in similar) track.id.raw]);
  final queued = {for (final track in playing) plain(track.id.raw)};
  await ListeningPreferences.ensureLoaded();
  return GoodMatch.rank(
    analysis[seed.id.raw],
    similar,
    analysis: (track) => analysis[track.id.raw],
    skip: (track) => queued.contains(plain(track.id.raw)) || !ListeningPreferences.permits(track),
  );
}

class _GoodMatchSheet extends StatefulWidget {
  const _GoodMatchSheet({required this.seed});

  final BaseItemDto seed;

  @override
  State<_GoodMatchSheet> createState() => _GoodMatchSheetState();
}

class _GoodMatchSheetState extends State<_GoodMatchSheet> {
  late final Future<List<BaseItemDto>> _matches = loadGoodMatches(widget.seed);

  Future<void> _playNext(BaseItemDto track) async {
    final l10n = context.l10n;
    Navigator.of(context).pop();
    try {
      await GetIt.instance<QueueService>().addNext(
        PlayableSlice.simple(
          [track],
          QueueItemSource.rawId(
            type: QueueItemSourceType.unknown,
            name: QueueItemSourceName(
              type: QueueItemSourceNameType.preTranslated,
              pretranslatedName: l10n.goodMatchSource(widget.seed.name ?? ""),
            ),
            id: "goodMatch",
          ),
        ),
      );
      GlobalSnackbar.message((context) => context.l10n.goodMatchAdded(track.name ?? ""), isConfirmation: true);
    } catch (e) {
      GlobalSnackbar.error(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    // Scrolls when the matches don't fit a short screen's sheet.
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.goodMatchTitle(widget.seed.name ?? ""), style: TextTheme.of(context).titleMedium),
            const SizedBox(height: 8),
            FutureBuilder(
              future: _matches,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                if (snapshot.hasError) {
                  final error = snapshot.error;
                  return Text(
                    error is AnalyzerException && error.message.contains("404")
                        ? l10n.songNotAnalyzedYet
                        : error.toString(),
                  );
                }
                final matches = snapshot.data ?? [];
                if (matches.isEmpty) return Text(l10n.goodMatchNone);
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final track in matches)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(TablerIcons.music),
                        title: Text(track.name ?? "", maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          track.artists?.join(", ") ?? track.albumArtist ?? "",
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: const Icon(TablerIcons.corner_right_down),
                        onTap: () => _playNext(track),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
