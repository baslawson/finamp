import 'dart:async';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:finamp/components/AlbumScreen/track_list_tile.dart';
import 'package:finamp/components/MusicScreen/item_wrapper.dart';
import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/components/now_playing_bar.dart';
import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/screens/vibe_search_screen.dart';
import 'package:finamp/menus/components/icon_button_with_semantics.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/models/music_models.dart';
import 'package:finamp/services/downloads_service.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:finamp/services/finamp_user_helper.dart';
import 'package:finamp/services/item_helper.dart';
import 'package:finamp/services/jellyfin_api_helper.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:finamp/screens/lyrics_search_screen.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _librarySearchLogger = Logger("LibrarySearch");

/// The categories shown on the library search screen, in display order.
enum LibrarySearchCategory {
  artists(BaseItemDtoType.artist, previewCount: 5),
  albums(BaseItemDtoType.album, previewCount: 6),
  tracks(BaseItemDtoType.track, previewCount: 8),
  playlists(BaseItemDtoType.playlist, previewCount: 4),
  genres(BaseItemDtoType.genre, previewCount: 4);

  const LibrarySearchCategory(this.itemType, {required this.previewCount});

  final BaseItemDtoType itemType;

  /// How many results are shown for this category in the combined "all" view.
  final int previewCount;

  String localized(BuildContext context) => switch (this) {
    LibrarySearchCategory.artists => context.l10n.artists,
    LibrarySearchCategory.albums => context.l10n.albums,
    LibrarySearchCategory.tracks => context.l10n.tracks,
    LibrarySearchCategory.playlists => context.l10n.playlists,
    LibrarySearchCategory.genres => context.l10n.genres,
  };
}

/// Number of results fetched per category. The combined view only shows the
/// first [LibrarySearchCategory.previewCount], a focused category shows all.
const _resultLimit = 100;

/// Number of tracks added for each artist or album whose name matches the query.
const _relatedTrackLimit = 10;

class LibrarySearchResults {
  const LibrarySearchResults(this.byCategory, this.topResult);

  final Map<LibrarySearchCategory, List<BaseItemDto>> byCategory;

  /// The single best match across all categories, if any result matches the query closely.
  final BaseItemDto? topResult;
}

/// A search for [query], either across all categories (null) or focused on one.
typedef LibrarySearchRequest = ({String query, LibrarySearchCategory? category});

/// Keeps a search cached for a minute after the screen stops using it, so going
/// back to a previous query or category shows its results instantly.
void _keepAliveBriefly(Ref ref) {
  final link = ref.keepAlive();
  final timer = Timer(const Duration(minutes: 1), link.close);
  ref.onDispose(timer.cancel);
}

/// Searches the current library online or in the downloads. The combined view only
/// fetches what it shows (plus one, to know whether there are more), a focused
/// category fetches up to [_resultLimit] results.
final librarySearchProvider = FutureProvider.autoDispose.family<LibrarySearchResults, LibrarySearchRequest>((
  ref,
  request,
) async {
  _keepAliveBriefly(ref);
  final isOffline = ref.watch(finampSettingsProvider.isOffline);
  final artistType = ref.watch(finampSettingsProvider.defaultArtistType);
  final library = GetIt.instance<FinampUserHelper>().currentUser?.currentView;
  final categories = request.category == null ? LibrarySearchCategory.values : [request.category!];

  Future<List<BaseItemDto>> search(LibrarySearchCategory category) async {
    final limit = request.category == null ? category.previewCount + 1 : _resultLimit;
    try {
      final items = isOffline
          ? await _searchOffline(ref, category, request.query, library?.id, artistType, limit)
          : await _searchOnline(category, request.query, library, artistType, limit);
      return _rankByRelevance(items, request.query);
    } catch (e) {
      // One failing category shouldn't hide the results of the others.
      _librarySearchLogger.warning("Searching ${category.name} failed", e);
      return [];
    }
  }

  final results = await Future.wait(categories.map(search));
  final byCategory = {for (final (index, category) in categories.indexed) category: results[index]};
  return LibrarySearchResults(byCategory, request.category == null ? _topResult(byCategory, request.query) : null);
});

/// Tracks of artists and albums whose name matches [query]. Loaded separately so
/// they don't hold back the main results, and shown after the title matches.
final librarySearchRelatedTracksProvider = FutureProvider.autoDispose.family<List<BaseItemDto>, String>((
  ref,
  query,
) async {
  _keepAliveBriefly(ref);
  final isOffline = ref.watch(finampSettingsProvider.isOffline);
  final artistType = ref.watch(finampSettingsProvider.defaultArtistType);
  final library = GetIt.instance<FinampUserHelper>().currentUser?.currentView;
  final results = await ref.watch(librarySearchProvider((query: query, category: null)).future);
  return _relatedTracks(results.byCategory, query, isOffline, library, artistType);
});

Future<List<BaseItemDto>> _searchOnline(
  LibrarySearchCategory category,
  String query,
  BaseItemDto? library,
  ArtistType artistType,
  int limit,
) async {
  final jellyfinApiHelper = GetIt.instance<JellyfinApiHelper>();
  final items = await jellyfinApiHelper.getItems(
    // Playlists live outside of music libraries, so search them server-wide.
    parentItem: category == LibrarySearchCategory.playlists ? null : library,
    includeItemTypes: category.itemType.jellyfinName,
    artistType: category == LibrarySearchCategory.artists ? artistType : null,
    recursive: category != LibrarySearchCategory.genres,
    searchTerm: query,
    limit: limit,
  );
  return items ?? [];
}

Future<List<BaseItemDto>> _searchOffline(
  Ref ref,
  LibrarySearchCategory category,
  String query,
  BaseItemId? libraryId,
  ArtistType artistType,
  int limit,
) async {
  final downloadsService = GetIt.instance<DownloadsService>();
  final nullableViewFilters = ref.watch(finampSettingsProvider.showDownloadsWithUnknownLibrary);
  final List<DownloadStub> stubs;
  if (category == LibrarySearchCategory.tracks) {
    stubs = await downloadsService.getAllTracks(
      nameFilter: query,
      viewFilter: libraryId,
      nullableViewFilters: nullableViewFilters,
    );
  } else {
    stubs = await downloadsService.getAllCollections(
      nameFilter: query,
      includeItemTypes: [category.itemType],
      fullyDownloaded: ref.watch(finampSettingsProvider.onlyShowFullyDownloaded),
      // Albums belong to one library, artists and genres can span several, playlists are server-wide.
      viewFilter: category == LibrarySearchCategory.albums ? libraryId : null,
      childViewFilter: category == LibrarySearchCategory.artists || category == LibrarySearchCategory.genres
          ? libraryId
          : null,
      nullableViewFilters: nullableViewFilters,
      infoForType: category == LibrarySearchCategory.artists
          ? (artistType == ArtistType.albumArtist ? BaseItemDtoType.album : BaseItemDtoType.track)
          : null,
    );
  }
  // Rank before cutting the list down, so the closest matches survive the limit.
  return _rankByRelevance(stubs.map((stub) => stub.baseItem).nonNulls.toList(), query).take(limit).toList();
}

/// Tracks by the two best matching artists and from the best matching album,
/// so searching for an artist or album name also lists its songs.
Future<List<BaseItemDto>> _relatedTracks(
  Map<LibrarySearchCategory, List<BaseItemDto>> byCategory,
  String query,
  bool isOffline,
  BaseItemDto? library,
  ArtistType artistType,
) async {
  bool isCloseMatch(BaseItemDto item) => _relevance(item, query) <= 1;
  final parents = [
    ...?byCategory[LibrarySearchCategory.artists]?.where(isCloseMatch).take(2),
    ...?byCategory[LibrarySearchCategory.albums]?.where(isCloseMatch).take(1),
  ];
  if (parents.isEmpty) return [];

  Future<List<BaseItemDto>> tracksOf(BaseItemDto parent) async {
    try {
      if (isOffline) {
        final stubs = await GetIt.instance<DownloadsService>().getAllTracks(relatedTo: parent, viewFilter: library?.id);
        return stubs.map((stub) => stub.baseItem).nonNulls.take(_relatedTrackLimit).toList();
      }
      final isArtist = BaseItemDtoType.fromItem(parent) == BaseItemDtoType.artist;
      final tracks = await GetIt.instance<JellyfinApiHelper>().getItems(
        parentItem: parent,
        libraryFilter: library?.id,
        includeItemTypes: BaseItemDtoType.track.jellyfinName,
        artistType: isArtist ? ArtistType.artist : null,
        // An artist's most played tracks first, an album's tracks in album order.
        sortBy: isArtist ? "PlayCount,SortName" : "ParentIndexNumber,IndexNumber,SortName",
        sortOrder: isArtist ? "Descending" : "Ascending",
        limit: _relatedTrackLimit,
      );
      return tracks ?? [];
    } catch (e) {
      _librarySearchLogger.warning("Loading tracks of ${parent.name} failed", e);
      return [];
    }
  }

  return (await Future.wait(parents.map(tracksOf))).flattened.toList();
}

final _whitespace = RegExp(r"\s+");

/// 0: exact match, 1: name starts with the query, 2: a word starts with it, 3: anything else.
int _relevance(BaseItemDto item, String query) {
  final needle = query.trim().toLowerCase();
  final name = (item.name ?? "").toLowerCase();
  if (name == needle) return 0;
  if (name.startsWith(needle)) return 1;
  if (name.split(_whitespace).any((word) => word.startsWith(needle))) return 2;
  return 3;
}

/// Orders results by [_relevance], keeping the original order within each group.
List<BaseItemDto> _rankByRelevance(List<BaseItemDto> items, String query) {
  // Rank each item once instead of on every comparison, offline searches can sort thousands of downloads.
  final ranked = [for (final (index, item) in items.indexed) (index, _relevance(item, query), item)]
    ..sort((a, b) {
      final byRank = a.$2.compareTo(b.$2);
      return byRank != 0 ? byRank : a.$1.compareTo(b.$1);
    });
  return ranked.map((entry) => entry.$3).toList();
}

/// The closest match across all categories. Ties go to the category listed first,
/// so an artist beats an album of the same name. Weak matches don't get a card.
BaseItemDto? _topResult(Map<LibrarySearchCategory, List<BaseItemDto>> byCategory, String query) {
  final candidates = LibrarySearchCategory.values.map((category) => byCategory[category]?.firstOrNull).nonNulls;
  final best = candidates.sortedBy<num>((item) => _relevance(item, query)).firstOrNull;
  return best != null && _relevance(best, query) <= 1 ? best : null;
}

/// Remembers the last searches so they can be repeated with one tap.
class _SearchHistory {
  static const _key = "librarySearchHistory";
  static const _maxEntries = 10;

  static Future<List<String>> load() async {
    try {
      return await SharedPreferencesAsync().getStringList(_key) ?? [];
    } catch (e) {
      _librarySearchLogger.warning("Loading search history failed", e);
      return [];
    }
  }

  static Future<List<String>> add(String query) async {
    final history = await load();
    history.removeWhere((entry) => entry.toLowerCase() == query.toLowerCase());
    history.insert(0, query);
    return _save(history.take(_maxEntries).toList());
  }

  static Future<List<String>> remove(String query) async => _save((await load())..remove(query));

  static Future<List<String>> clear() => _save([]);

  static Future<List<String>> _save(List<String> history) async {
    try {
      await SharedPreferencesAsync().setStringList(_key, history);
    } catch (e) {
      _librarySearchLogger.warning("Saving search history failed", e);
    }
    return history;
  }
}

/// Asks the system speech recognizer for a search phrase (Android only).
class _VoiceSearch {
  static const _channel = MethodChannel("com.unicornsonlsd.finamp/voice_search");

  static Future<bool> isAvailable() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>("isAvailable") ?? false;
    } on PlatformException {
      return false;
    }
  }

  static Future<String?> listen(String prompt) async {
    try {
      return await _channel.invokeMethod<String>("listen", {"prompt": prompt});
    } on PlatformException catch (e) {
      _librarySearchLogger.warning("Voice search failed", e);
      return null;
    }
  }
}

/// A Jellyfin-style search across the whole library: artists, albums, tracks,
/// playlists and genres are searched together and shown grouped by type.
class LibrarySearchScreen extends ConsumerStatefulWidget {
  const LibrarySearchScreen({super.key});

  static const routeName = "/music/search";

  @override
  ConsumerState<LibrarySearchScreen> createState() => _LibrarySearchScreenState();
}

class _LibrarySearchScreenState extends ConsumerState<LibrarySearchScreen> {
  final _textEditingController = TextEditingController();
  final _focusNode = FocusNode();
  Timer? _debounce;
  String _query = "";
  List<String> _history = [];
  bool _voiceAvailable = false;

  /// The category the results are narrowed down to, or null to show all of them.
  LibrarySearchCategory? _category;

  @override
  void initState() {
    super.initState();
    _SearchHistory.load().then((history) {
      if (mounted) setState(() => _history = history);
    });
    _VoiceSearch.isAvailable().then((available) {
      if (mounted) setState(() => _voiceAvailable = available);
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _textEditingController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _updateQuery(String value) {
    _debounce?.cancel();
    setState(() => _query = value.trim());
  }

  /// Runs [query] right away, e.g. from the history or voice search.
  void _search(String query) {
    _textEditingController.text = query;
    _focusNode.unfocus();
    _updateQuery(query);
    _rememberQuery();
  }

  /// Saves the current query once the user acts on it, so half-typed searches don't end up in the history.
  void _rememberQuery() {
    if (_query.isEmpty) return;
    _SearchHistory.add(_query).then((history) {
      if (mounted) setState(() => _history = history);
    });
  }

  Future<void> _startVoiceSearch() async {
    final phrase = await _VoiceSearch.listen(context.l10n.search);
    if (phrase != null && phrase.trim().isNotEmpty && mounted) {
      _search(phrase.trim());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBody: true,
      appBar: AppBar(
        titleSpacing: 0,
        title: TextField(
          controller: _textEditingController,
          focusNode: _focusNode,
          autofocus: true,
          autocorrect: false,
          keyboardType: TextInputType.text,
          textInputAction: TextInputAction.search,
          onChanged: (value) {
            _debounce?.cancel();
            _debounce = Timer(const Duration(milliseconds: 250), () => _updateQuery(value));
            // Rebuild so the clear button appears and disappears with the text.
            setState(() {});
          },
          onSubmitted: (value) {
            _updateQuery(value);
            _rememberQuery();
          },
          decoration: InputDecoration(
            border: InputBorder.none,
            hintText: MaterialLocalizations.of(context).searchFieldLabel,
          ),
        ),
        actions: [
          if (_textEditingController.text.isNotEmpty)
            IconButtonWithSemantics(
              icon: TablerIcons.x,
              label: context.l10n.clear,
              onPressed: () {
                _textEditingController.clear();
                _updateQuery("");
                _focusNode.requestFocus();
              },
            )
          else if (_voiceAvailable)
            IconButtonWithSemantics(
              icon: TablerIcons.microphone,
              label: context.l10n.voiceSearch,
              onPressed: _startVoiceSearch,
            ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(52),
          child: _CategoryChips(selected: _category, onSelected: (category) => setState(() => _category = category)),
        ),
      ),
      bottomNavigationBar: const NowPlayingBar(),
      body: _query.isEmpty ? _buildHistory(context) : _buildResults(context),
    );
  }

  Widget _buildHistory(BuildContext context) {
    if (_history.isEmpty) {
      return Column(
        children: [
          const AnalyzerSearchTiles(),
          const Expanded(child: _SearchHint()),
        ],
      );
    }
    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom + 96),
      children: [
        const AnalyzerSearchTiles(),
        Padding(
          padding: const EdgeInsets.only(left: 16.0, right: 4.0, top: 8.0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  context.l10n.recentSearches,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              TextButton(
                onPressed: () => _SearchHistory.clear().then((history) => setState(() => _history = history)),
                child: Text(context.l10n.clear),
              ),
            ],
          ),
        ),
        for (final entry in _history)
          ListTile(
            leading: const Icon(TablerIcons.history),
            title: Text(entry, maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: IconButtonWithSemantics(
              icon: TablerIcons.x,
              label: context.l10n.removeFromRecentSearches,
              onPressed: () => _SearchHistory.remove(entry).then((history) => setState(() => _history = history)),
            ),
            onTap: () => _search(entry),
          ),
      ],
    );
  }

  /// The last results that finished loading, shown while the next query is still loading.
  (LibrarySearchRequest, LibrarySearchResults)? _previousResults;

  Widget _buildResults(BuildContext context) {
    final request = (query: _query, category: _category);
    final current = ref.watch(librarySearchProvider(request));
    final relatedTracks = ref.watch(librarySearchRelatedTracksProvider(_query)).valueOrNull ?? [];

    if (current.hasValue) {
      _previousResults = (request, current.requireValue);
    } else if (current.hasError) {
      return Center(child: Text(context.l10n.errorLoadingItems));
    }
    final shown = _previousResults;
    if (shown == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final (shownRequest, results) = shown;
    final isStale = shownRequest != request;

    final byCategory = {...results.byCategory};
    final tracks = byCategory[LibrarySearchCategory.tracks];
    if (tracks != null && !isStale && relatedTracks.isNotEmpty) {
      final trackIds = tracks.map((track) => track.id).toSet();
      byCategory[LibrarySearchCategory.tracks] = [...tracks, ...relatedTracks.where((track) => trackIds.add(track.id))];
    }

    final categories = shownRequest.category == null ? LibrarySearchCategory.values : [shownRequest.category!];
    final sections = [
      for (final category in categories)
        if (byCategory[category]?.isNotEmpty ?? false)
          ..._buildSection(context, category, byCategory[category]!, showAll: shownRequest.category != null),
    ];
    final topResult = shownRequest.category == null ? results.topResult : null;

    return Stack(
      children: [
        if (sections.isEmpty && !isStale)
          Column(
            children: [
              if (_LyricsSearchTile.fits(shownRequest.query)) _LyricsSearchTile(query: shownRequest.query),
              Expanded(child: Center(child: Text(context.l10n.noSearchResults))),
            ],
          )
        else
          // Remember the search once the user interacts with a result.
          Listener(
            onPointerUp: (_) => _rememberQuery(),
            child: CustomScrollView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              slivers: [
                if (_LyricsSearchTile.fits(shownRequest.query))
                  SliverToBoxAdapter(child: _LyricsSearchTile(query: shownRequest.query)),
                if (topResult != null)
                  SliverToBoxAdapter(
                    // Keyed so a new top result gets a fresh card, ItemWrapper keeps the item it was created with.
                    child: _TopResultCard(key: ValueKey(topResult.id), item: topResult, source: _source),
                  ),
                ...sections,
                // Keep the last results clear of the now playing bar.
                SliverPadding(padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom + 96)),
              ],
            ),
          ),
        // A thin bar instead of a full screen spinner, so the previous results stay readable.
        if (isStale) const Positioned(top: 0, left: 0, right: 0, child: LinearProgressIndicator(minHeight: 2)),
      ],
    );
  }

  QueueItemSource get _source => QueueItemSource.rawId(
    type: QueueItemSourceType.unknown,
    name: QueueItemSourceName(
      type: QueueItemSourceNameType.preTranslated,
      pretranslatedName: "${context.l10n.search}: $_query",
    ),
    id: "library-search",
  );

  List<Widget> _buildSection(
    BuildContext context,
    LibrarySearchCategory category,
    List<BaseItemDto> items, {
    required bool showAll,
  }) {
    final shown = showAll ? items : items.take(category.previewCount).toList();
    final source = _source;

    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.only(left: 16.0, right: 4.0, top: 16.0, bottom: 4.0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  category.localized(context),
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              if (!showAll && items.length > shown.length)
                TextButton(onPressed: () => setState(() => _category = category), child: Text(context.l10n.showAll)),
            ],
          ),
        ),
      ),
      SliverList.builder(
        itemCount: shown.length,
        itemBuilder: (context, index) {
          final item = shown[index];
          if (category == LibrarySearchCategory.tracks) {
            return TrackListTile(
              key: ValueKey(item.id),
              item: item,
              index: index,
              allowDismiss: false,
              parentPlayable: PrecalculatedPlayable(source: source, tracks: shown),
            );
          }
          return ItemWrapper(key: ValueKey(item.id), item: item, source: source);
        },
      ),
    ];
  }
}

/// Offers a lyrics search when the query looks like a line from a song.
class _LyricsSearchTile extends StatelessWidget {
  const _LyricsSearchTile({required this.query});

  final String query;

  static bool fits(String query) => query.trim().split(RegExp(r"\s+")).length >= 3;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(TablerIcons.quote),
      title: Text(context.l10n.lyricsSearchFor(query.trim())),
      subtitle: Text(context.l10n.lyricsSearchTileSubtitle),
      onTap: () => Navigator.of(context).pushNamed(LyricsSearchScreen.routeName, arguments: query.trim()),
    );
  }
}

/// Highlights the best match with buttons to play or shuffle it right away.
class _TopResultCard extends StatelessWidget {
  const _TopResultCard({super.key, required this.item, required this.source});

  final BaseItemDto item;
  final QueueItemSource source;

  Future<void> _play(FinampPlaybackOrder order) async {
    try {
      final tracks = await loadChildTracksFromBaseItem(
        item: item,
        sortConfig: SortAndFilterConfiguration.defaultForItem(item),
      );
      final isTrack = BaseItemDtoType.fromItem(item) == BaseItemDtoType.track;
      await GetIt.instance<QueueService>().startPlayback(
        items: tracks,
        source: isTrack ? source : QueueItemSource.fromBaseItem(item),
        order: order,
      );
    } catch (e) {
      GlobalSnackbar.error(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isTrack = BaseItemDtoType.fromItem(item) == BaseItemDtoType.track;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12.0, 12.0, 12.0, 0.0),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.only(top: 8.0, bottom: 4.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 16.0, bottom: 4.0),
                child: Text(
                  "${context.l10n.topResult} · ${BaseItemDtoType.fromItem(item).localized(context.l10n)}",
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
              ItemWrapper(item: item, source: source),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12.0),
                child: Row(
                  spacing: 8.0,
                  children: [
                    FilledButton.icon(
                      onPressed: () => _play(FinampPlaybackOrder.linear),
                      icon: const Icon(TablerIcons.player_play),
                      label: Text(context.l10n.playButtonLabel),
                    ),
                    if (!isTrack)
                      FilledButton.tonalIcon(
                        onPressed: () => _play(FinampPlaybackOrder.shuffled),
                        icon: const Icon(TablerIcons.arrows_shuffle),
                        label: Text(context.l10n.shuffleButtonLabel),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CategoryChips extends StatelessWidget {
  const _CategoryChips({required this.selected, required this.onSelected});

  final LibrarySearchCategory? selected;
  final ValueChanged<LibrarySearchCategory?> onSelected;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8.0),
            child: ChoiceChip(
              label: Text(context.l10n.searchCategoryAll),
              selected: selected == null,
              onSelected: (_) => onSelected(null),
            ),
          ),
          for (final category in LibrarySearchCategory.values)
            Padding(
              padding: const EdgeInsets.only(right: 8.0),
              child: ChoiceChip(
                label: Text(category.localized(context)),
                selected: selected == category,
                onSelected: (isSelected) => onSelected(isSelected ? category : null),
              ),
            ),
        ],
      ),
    );
  }
}

class _SearchHint extends StatelessWidget {
  const _SearchHint();

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        spacing: 12.0,
        children: [
          Icon(TablerIcons.search, size: 56, color: color),
          Text(
            "${context.l10n.artists}, ${context.l10n.albums}, ${context.l10n.tracks}, "
            "${context.l10n.playlists}, ${context.l10n.genres}",
            textAlign: TextAlign.center,
            style: TextStyle(color: color),
          ),
        ],
      ),
    );
  }
}
