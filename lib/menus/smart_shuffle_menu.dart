import 'dart:math';

import 'package:collection/collection.dart';
import 'package:finamp/components/fun_heading.dart';
import 'package:finamp/components/AudioServiceSettingsScreen/shuffle_randomness_slider.dart';
import 'package:finamp/components/genre_fit_switch.dart';
import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/components/harmonic_mixing_switch.dart';
import 'package:finamp/components/mix_length_chips.dart';
import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/ai_dj_service.dart';
import 'package:finamp/services/ai_service.dart';
import 'package:finamp/services/analyzer_service.dart';
import 'package:finamp/services/dj_transition_service.dart';
import 'package:finamp/services/downloads_service.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:finamp/services/finamp_user_helper.dart';
import 'package:finamp/services/genre_fit.dart';
import 'package:finamp/services/genre_mix.dart';
import 'package:finamp/services/jellyfin_api_helper.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:finamp/services/radio_tuning.dart';
import 'package:finamp/services/listening_preferences.dart';
import 'package:finamp/services/server_health_guard.dart';
import 'package:finamp/services/smart_shuffle.dart';
import 'package:finamp/services/song_duplicates.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:finamp/services/skip_service.dart';
import 'package:get_it/get_it.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Decades offered by smart shuffle, newest first.
List<int> get _decades {
  final currentDecade = DateTime.now().year ~/ 10 * 10;
  return [for (var decade = currentDecade; decade >= 1950; decade -= 10) decade];
}

typedef _GenreChoice = GenreChoice;

/// The genres to choose from, tidied ones if the AI grouped them before.
final _smartShuffleGenresProvider = FutureProvider.autoDispose<({List<_GenreChoice> choices, bool tidied})>((ref) {
  ref.watch(finampSettingsProvider.isOffline);
  return loadGenreChoices();
});

Future<void> showSmartShuffleMenu({required BuildContext context}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => const _SmartShuffleMenu(),
  );
}

/// Lets the user pick a decade and/or genre and shuffles the matching tracks.
class _SmartShuffleMenu extends ConsumerStatefulWidget {
  const _SmartShuffleMenu();

  @override
  ConsumerState<_SmartShuffleMenu> createState() => _SmartShuffleMenuState();
}

String _id(BaseItemDto track) => track.id.raw;

/// The chosen length in minutes, 0 for any length.
const _lengthKey = "smartShuffleMinutes";

class _SmartShuffleMenuState extends ConsumerState<_SmartShuffleMenu> {
  int? _decade;
  _GenreChoice? _genre;

  /// Minutes of music to play, or null to play the whole shuffle.
  int? _minutes;
  bool _starting = false;
  bool _tidying = false;

  @override
  void initState() {
    super.initState();
    SharedPreferencesAsync().getInt(_lengthKey).then((minutes) {
      if (minutes != null && minutes > 0 && mounted) setState(() => _minutes = minutes);
    });
  }

  void _setMinutes(int? minutes) {
    setState(() => _minutes = minutes);
    SharedPreferencesAsync().setInt(_lengthKey, minutes ?? 0).ignore();
  }

  Future<void> _shuffle() async {
    setState(() => _starting = true);
    try {
      // Cleaned the way the queue would (duplicates, resting songs, unplayable recordings) before ordering and cutting
      // to length, so the length counts songs that will play and the first song is one that may.
      await ListeningPreferences.ensureLoaded();
      final tracks = await _loadTracks(
        (pool) => ServerHealthGuard.filter(withoutDuplicateSongs(pool).where(ListeningPreferences.permits).toList()),
      );
      if (tracks.isEmpty) {
        GlobalSnackbar.message((context) => context.l10n.smartShuffleNoTracks);
        return;
      }
      // Ordered from the whole pool so each song has the most to choose a good next song from, then cut to length.
      final harmonic = await HarmonicMixing.menuEnabled(HarmonicMixingMenu.smartShuffle)
          ? await DjTransitionService.harmonicShuffle(tracks, strength: HarmonicMixing.strength.value)
          : null;
      if (!mounted) return;
      final name = [
        if (_decade != null) context.l10n.smartShuffleDecadeLabel(_decade.toString()),
        if (_genre != null) _genre!.name,
        if (_minutes != null) mixLengthLabel(context, _minutes!),
      ].join(" · ");
      final source = QueueItemSource.rawId(
        type: QueueItemSourceType.allTracks,
        name: QueueItemSourceName(
          type: QueueItemSourceNameType.preTranslated,
          pretranslatedName: name.isEmpty
              ? context.l10n.smartShuffleAction
              : "${context.l10n.smartShuffleAction}: $name",
        ),
        id: GenreMix.smartShuffleId,
      );
      // Remembered first, so the song menu can offer "Doesn't fit" as soon as the mix plays.
      if (_genre != null) {
        await GenreMix.started(sourceName: source.name.pretranslatedName!, genre: _genre!.name);
      }
      await GetIt.instance<QueueService>().startPlayback(
        items: prepareSmartShuffle(harmonic ?? tracks, source, minutes: _minutes, harmonic: harmonic != null),
        source: source,
        // A harmonic order plays as it is: from its first song, without the queue shuffling it again.
        order: harmonic == null ? FinampPlaybackOrder.shuffled : FinampPlaybackOrder.linear,
        startingIndex: harmonic == null ? null : 0,
        randomizeGenerated: harmonic == null,
        harmonicOrder: harmonic != null,
      );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      GlobalSnackbar.error(e);
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _tidyGenres() async {
    if (!await AiService.isConfigured()) {
      GlobalSnackbar.message((context) => context.l10n.aiNeedsApiKey);
      return;
    }
    setState(() => _tidying = true);
    try {
      await AiDjService.tidyGenres(await AiDjService.loadGenres());
      _genre = null;
      ref.invalidate(_smartShuffleGenresProvider);
    } catch (e) {
      GlobalSnackbar.message((_) => e.toString());
    } finally {
      if (mounted) setState(() => _tidying = false);
    }
  }

  Future<void> _useOriginalGenres() async {
    await AiDjService.clearGenreGroups();
    _genre = null;
    ref.invalidate(_smartShuffleGenresProvider);
  }

  /// The songs to shuffle: [clean]ed of ones that can't play first, so a genre's choice and the length are made from
  /// songs that will play.
  Future<List<BaseItemDto>> _loadTracks(Future<List<BaseItemDto>> Function(List<BaseItemDto> pool) clean) async {
    final settings = FinampSettingsHelper.finampSettings;
    final library = GetIt.instance<FinampUserHelper>().currentUser!.currentView!;
    final years = _decade == null ? null : [for (var year = _decade!; year < _decade! + 10; year++) year];
    // Enough to fill the chosen length even when some songs get thinned out or are short.
    final count = max(settings.trackShuffleItemCount, _minutes == null ? 0 : _minutes! ~/ averageTrackMinutes * 2);
    final genre = _genre;
    // A genre leaves out songs that don't fit it, so twice as many are fetched to choose from.
    final fetch = genre == null ? count : min(count * 2, AnalyzerService.genreFitLimit);
    final fetched = await _fetchTracks(settings, library, genre, years, fetch);
    if (genre == null) return SkipService.thinOut(await clean(fetched), _id);
    // Songs the listener said are the genre join in wherever they're tagged, mixed in at random like the rest.
    final answered = settings.isOffline
        ? <BaseItemDto>[]
        : await _answeredSongs(genre, years, library: library, exclude: fetched);
    final random = Random();
    final mixed = [...fetched];
    for (final song in answered) {
      mixed.insert(random.nextInt(mixed.length + 1), song);
    }
    final pool = await clean(mixed);
    final fitting = await GenreFit.filter(
      pool,
      name: genre.name,
      tags: genre.tags,
      // Enough left to fill the chosen length.
      keepAtLeast: _minutes == null ? 10 : (_minutes! / averageTrackMinutes * 1.5).ceil(),
      keepAtMost: count,
    );
    // Often skipped songs come up less.
    return SkipService.thinOut(fitting, _id);
  }

  /// Some of the songs the listener said are [genre] (in the chosen decade), apart from the ones already fetched.
  Future<List<BaseItemDto>> _answeredSongs(
    _GenreChoice genre,
    List<int>? years, {
    required BaseItemDto library,
    required List<BaseItemDto> exclude,
  }) async {
    final known = {for (final track in exclude) track.id.raw};
    final wanted = (await GenreFit.answeredFits(genre.name)).where((id) => !known.contains(id));
    // Only the ones in this library, like the rest of the mix.
    return GenreMix.answeredSongs(
      GetIt.instance<JellyfinApiHelper>(),
      wanted,
      library: library,
      count: 200,
      years: years,
      wait: const Duration(seconds: 10),
    );
  }

  Future<List<BaseItemDto>> _fetchTracks(
    FinampSettings settings,
    BaseItemDto library,
    _GenreChoice? genre,
    List<int>? years,
    int count,
  ) async {
    if (settings.isOffline) {
      final downloadsService = GetIt.instance<DownloadsService>();
      final genreIds = genre?.ids ?? <BaseItemId?>[null];
      final stubs = [
        for (final genreId in genreIds)
          ...await downloadsService.getAllTracks(
            viewFilter: library.id,
            nullableViewFilters: settings.showDownloadsWithUnknownLibrary,
            genreFilter: genreId,
          ),
      ];
      final tracks = stubs
          .map((stub) => stub.baseItem)
          .nonNulls
          .where((track) => years == null || years.contains(track.productionYear))
          .toList();
      final unique = {for (final track in tracks) track.id: track}.values.toList();
      return (unique..shuffle()).take(count).toList();
    }

    final tracks = await GetIt.instance<JellyfinApiHelper>().getItems(
      parentItem: library,
      includeItemTypes: BaseItemDtoType.track.jellyfinName,
      genreFilters: genre?.ids,
      years: years,
      sortBy: "Random",
      limit: count,
    );
    return tracks ?? [];
  }

  @override
  Widget build(BuildContext context) {
    final genres = ref.watch(_smartShuffleGenresProvider);
    final textTheme = Theme.of(context).textTheme;

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 8.0,
                  children: [
                    GradientTitle(context.l10n.smartShuffleAction, icon: TablerIcons.arrows_shuffle),
                    const ShuffleRandomnessSlider(padding: EdgeInsets.symmetric(vertical: 8)),
                    const HarmonicMixingSwitch(menu: HarmonicMixingMenu.smartShuffle),
                    Text(context.l10n.smartShuffleLength, style: textTheme.titleSmall),
                    MixLengthChips(
                      minutes: _minutes,
                      onChanged: _setMinutes,
                      anyLabel: context.l10n.smartShuffleAnyLength,
                    ),
                    const SizedBox(height: 4.0),
                    Text(context.l10n.smartShuffleDecade, style: textTheme.titleSmall),
                    Wrap(
                      spacing: 8.0,
                      runSpacing: 4.0,
                      children: [
                        ChoiceChip(
                          label: Text(context.l10n.smartShuffleAnyDecade),
                          selected: _decade == null,
                          onSelected: (_) => setState(() => _decade = null),
                        ),
                        for (final decade in _decades)
                          ChoiceChip(
                            label: Text(context.l10n.smartShuffleDecadeLabel(decade.toString())),
                            selected: _decade == decade,
                            onSelected: (selected) => setState(() => _decade = selected ? decade : null),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4.0),
                    Row(
                      children: [
                        Expanded(child: Text(context.l10n.smartShuffleGenre, style: textTheme.titleSmall)),
                        if (_tidying)
                          const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        else if (genres.valueOrNull?.tidied ?? false)
                          TextButton(onPressed: _useOriginalGenres, child: Text(context.l10n.aiOriginalGenres))
                        else
                          TextButton.icon(
                            onPressed: _tidyGenres,
                            icon: const Icon(TablerIcons.sparkles, size: 18),
                            label: Text(context.l10n.aiTidyGenres),
                          ),
                      ],
                    ),
                    // Above the genres, which can be a long list.
                    const GenreFitSwitch(),
                    genres.when(
                      loading: () => const LinearProgressIndicator(),
                      error: (_, _) => Text(context.l10n.errorLoadingItems),
                      data: (genres) => Wrap(
                        spacing: 8.0,
                        runSpacing: 4.0,
                        children: [
                          ChoiceChip(
                            label: Text(context.l10n.smartShuffleAnyGenre),
                            selected: _genre == null,
                            onSelected: (_) => setState(() => _genre = null),
                          ),
                          for (final genre in genres.choices)
                            ChoiceChip(
                              label: Text(genre.name),
                              selected:
                                  _genre != null && const ListEquality<BaseItemId>().equals(_genre!.ids, genre.ids),
                              onSelected: (selected) => setState(() => _genre = selected ? genre : null),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8.0),
                  ],
                ),
              ),
            ),
            // Kept outside the scroll view so it's reachable without scrolling past every genre.
            Padding(
              padding: const EdgeInsets.fromLTRB(16.0, 8.0, 16.0, 16.0),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _starting ? null : _shuffle,
                  icon: _starting
                      ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(TablerIcons.arrows_shuffle),
                  label: Text(context.l10n.shuffleButtonLabel),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
