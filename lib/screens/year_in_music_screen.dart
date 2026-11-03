import 'package:collection/collection.dart';
import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:finamp/services/finamp_user_helper.dart';
import 'package:finamp/services/jellyfin_api_helper.dart';
import 'package:finamp/services/listening_log_service.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';
import 'package:intl/intl.dart';

/// A name with how often and how long it was listened to.
class RecapRank {
  RecapRank(this.id, this.name, {this.subtitle});

  final String? id;
  final String name;
  final String? subtitle;
  int plays = 0;
  Duration listened = Duration.zero;
}

/// Listening stats for one year, from the on-device listening log.
class YearRecap {
  YearRecap({
    required this.year,
    required this.listened,
    required this.plays,
    required this.uniqueTracks,
    required this.topTracks,
    required this.topArtists,
    required this.topAlbums,
    required this.topGenres,
    required this.busiestMonth,
  });

  final int year;
  final Duration listened;
  final int plays;
  final int uniqueTracks;
  final List<RecapRank> topTracks;
  final List<RecapRank> topArtists;
  final List<RecapRank> topAlbums;
  final List<RecapRank> topGenres;
  final int? busiestMonth;

  static const topCount = 5;

  static YearRecap fromEntries(int year, Iterable<ListenEntry> allEntries) {
    final entries = allEntries.where((entry) => entry.time.year == year).toList();
    final tracks = <String, RecapRank>{};
    final artists = <String, RecapRank>{};
    final albums = <String, RecapRank>{};
    final genres = <String, RecapRank>{};
    final months = <int, Duration>{};

    void count(Map<String, RecapRank> ranks, String key, RecapRank Function() create, ListenEntry entry) {
      final rank = ranks.putIfAbsent(key, create);
      rank.plays++;
      rank.listened += entry.listened;
    }

    for (final entry in entries) {
      count(tracks, entry.trackId, () => RecapRank(entry.trackId, entry.track, subtitle: entry.artist), entry);
      if (entry.artist != null) {
        count(artists, entry.artistId ?? entry.artist!, () => RecapRank(entry.artistId, entry.artist!), entry);
      }
      if (entry.album != null) {
        count(
          albums,
          entry.albumId ?? entry.album!,
          () => RecapRank(entry.albumId, entry.album!, subtitle: entry.artist),
          entry,
        );
      }
      for (final genre in entry.genres) {
        count(genres, genre.toLowerCase(), () => RecapRank(null, genre), entry);
      }
      months[entry.time.month] = (months[entry.time.month] ?? Duration.zero) + entry.listened;
    }

    List<RecapRank> top(Map<String, RecapRank> ranks) =>
        (ranks.values.toList()..sort((a, b) => b.listened.compareTo(a.listened))).take(topCount).toList();

    return YearRecap(
      year: year,
      listened: entries.fold(Duration.zero, (total, entry) => total + entry.listened),
      plays: entries.length,
      uniqueTracks: tracks.length,
      topTracks: top(tracks),
      topArtists: top(artists),
      topAlbums: top(albums),
      topGenres: top(genres),
      busiestMonth: maxBy(months.entries, (MapEntry<int, Duration> month) => month.value)?.key,
    );
  }
}

final _listeningLogProvider = FutureProvider.autoDispose((ref) => ListeningLogService.load());

/// All-time most played tracks from the server, shown while the on-device log is still empty.
final _serverTopTracksProvider = FutureProvider.autoDispose<List<BaseItemDto>>((ref) async {
  if (ref.watch(finampSettingsProvider.isOffline)) return [];
  final library = GetIt.instance<FinampUserHelper>().currentUser?.currentView;
  final tracks = await GetIt.instance<JellyfinApiHelper>().getItems(
    parentItem: library,
    includeItemTypes: BaseItemDtoType.track.jellyfinName,
    sortBy: "PlayCount,SortName",
    sortOrder: "Descending",
    filters: "IsPlayed",
    limit: 10,
  );
  return tracks ?? [];
});

class YearInMusicScreen extends ConsumerStatefulWidget {
  const YearInMusicScreen({super.key});

  static const routeName = "/yearinmusic";

  @override
  ConsumerState<YearInMusicScreen> createState() => _YearInMusicScreenState();
}

class _YearInMusicScreenState extends ConsumerState<YearInMusicScreen> {
  int _year = DateTime.now().year;

  @override
  Widget build(BuildContext context) {
    final log = ref.watch(_listeningLogProvider);
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.yearInMusic)),
      body: log.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text(error.toString())),
        data: (entries) {
          final years = {DateTime.now().year, ...entries.map((entry) => entry.time.year)}.sorted((a, b) => b - a);
          final recap = YearRecap.fromEntries(_year, entries);
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
            children: [
              if (years.length > 1)
                Wrap(
                  spacing: 8,
                  children: [
                    for (final year in years)
                      ChoiceChip(
                        label: Text("$year"),
                        selected: year == _year,
                        onSelected: (_) => setState(() => _year = year),
                      ),
                  ],
                ),
              const SizedBox(height: 8),
              if (recap.plays == 0) const _ServerTopTracks() else _RecapCards(recap: recap),
            ],
          );
        },
      ),
    );
  }
}

class _RecapCards extends StatelessWidget {
  const _RecapCards({required this.recap});

  final YearRecap recap;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final number = NumberFormat.decimalPattern(context.l10n.localeName);
    final colors = Theme.of(context).colorScheme;
    final topArtist = recap.topArtists.firstOrNull;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 12,
      children: [
        _GradientCard(
          colors: [colors.primary, colors.tertiary],
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(context.l10n.yearInMusicMinutes(recap.year.toString()), style: textTheme.titleMedium),
              Text(
                number.format(recap.listened.inMinutes),
                style: textTheme.displayLarge!.copyWith(fontWeight: FontWeight.w900),
              ),
              Text(
                context.l10n.yearInMusicPlays(number.format(recap.plays), number.format(recap.uniqueTracks)),
                style: textTheme.bodyLarge,
              ),
              if (recap.busiestMonth != null)
                Text(
                  context.l10n.yearInMusicBusiestMonth(
                    DateFormat.MMMM(context.l10n.localeName).format(DateTime(recap.year, recap.busiestMonth!)),
                  ),
                  style: textTheme.bodyLarge,
                ),
            ],
          ),
        ),
        if (topArtist != null)
          _GradientCard(
            colors: [colors.secondary, colors.primary],
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(context.l10n.yearInMusicTopArtist, style: textTheme.titleMedium),
                Text(topArtist.name, style: textTheme.headlineLarge!.copyWith(fontWeight: FontWeight.w900)),
                Text(context.l10n.yearInMusicListenedMinutes(number.format(topArtist.listened.inMinutes))),
              ],
            ),
          ),
        if (recap.topTracks.isNotEmpty) ...[
          _RankList(title: context.l10n.yearInMusicTopTracks, ranks: recap.topTracks),
          FilledButton.icon(
            onPressed: () => _playTopTracks(context, recap),
            icon: const Icon(TablerIcons.player_play),
            label: Text(context.l10n.yearInMusicPlayTopTracks),
          ),
        ],
        _RankList(title: context.l10n.yearInMusicTopArtists, ranks: recap.topArtists),
        _RankList(title: context.l10n.yearInMusicTopAlbums, ranks: recap.topAlbums),
        _RankList(title: context.l10n.yearInMusicTopGenres, ranks: recap.topGenres),
      ],
    );
  }

  Future<void> _playTopTracks(BuildContext context, YearRecap recap) async {
    try {
      final name = context.l10n.yearInMusicPlaylistName(recap.year.toString());
      final ids = [for (final track in recap.topTracks) BaseItemId(track.id!)];
      final tracks = await GetIt.instance<JellyfinApiHelper>().getItems(itemIds: ids);
      if (tracks == null || tracks.isEmpty) return;
      // Keep the recap's order rather than the server's.
      final ordered = [
        for (final id in ids) ...tracks.where((track) => track.id == id),
      ];
      await GetIt.instance<QueueService>().startPlayback(
        items: ordered,
        source: QueueItemSource.rawId(
          type: QueueItemSourceType.allTracks,
          name: QueueItemSourceName(type: QueueItemSourceNameType.preTranslated, pretranslatedName: name),
          id: "yearInMusic",
        ),
        order: FinampPlaybackOrder.linear,
      );
    } catch (e) {
      GlobalSnackbar.error(e);
    }
  }
}

class _ServerTopTracks extends ConsumerWidget {
  const _ServerTopTracks();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tracks = ref.watch(_serverTopTracksProvider).valueOrNull ?? [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 12,
      children: [
        Text(context.l10n.yearInMusicEmpty, style: Theme.of(context).textTheme.bodyLarge),
        if (tracks.isNotEmpty)
          _RankList(
            title: context.l10n.yearInMusicAllTime,
            ranks: [
              for (final track in tracks)
                RecapRank(track.id.raw, track.name ?? "", subtitle: track.albumArtist)
                  ..plays = track.userData?.playCount ?? 0,
            ],
            showPlays: true,
          ),
      ],
    );
  }
}

class _GradientCard extends StatelessWidget {
  const _GradientCard({required this.colors, required this.child});

  final List<Color> colors;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: LinearGradient(colors: colors, begin: Alignment.topLeft, end: Alignment.bottomRight),
      ),
      child: DefaultTextStyle.merge(
        style: const TextStyle(color: Colors.white),
        child: IconTheme.merge(data: const IconThemeData(color: Colors.white), child: child),
      ),
    );
  }
}

class _RankList extends StatelessWidget {
  const _RankList({required this.title, required this.ranks, this.showPlays = false});

  final String title;
  final List<RecapRank> ranks;
  final bool showPlays;

  @override
  Widget build(BuildContext context) {
    if (ranks.isEmpty) return const SizedBox.shrink();
    final textTheme = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text(title, style: textTheme.titleLarge),
            ),
            for (final (index, rank) in ranks.indexed)
              ListTile(
                leading: Text("${index + 1}", style: textTheme.headlineSmall!.copyWith(fontWeight: FontWeight.w900)),
                title: Text(rank.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: rank.subtitle == null ? null : Text(rank.subtitle!, maxLines: 1),
                trailing: Text(
                  showPlays
                      ? context.l10n.playCountValue(rank.plays)
                      : context.l10n.yearInMusicListenedMinutes(rank.listened.inMinutes.toString()),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
