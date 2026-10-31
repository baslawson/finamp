import 'package:finamp/models/finamp_models.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Which of your own lists play one version of each song, as mixes always do.
enum ListDuplicatesMode { off, playlists, everyList }

/// The "One version of each song" setting: when a playlist (or, if chosen, any album, artist, genre or other list)
/// has the same song more than once, counting live takes, remasters and compilation copies as mixes do, it plays once.
/// Saved playlists don't change.
class ListDuplicates {
  ListDuplicates._();

  static final _logger = Logger("ListDuplicates");

  static const _key = "listDuplicatesMode";

  /// Bumped when the setting changes, for the settings screen.
  static final changed = ValueNotifier(0);

  static ListDuplicatesMode? _mode;
  static Future<void>? _loading;

  /// The setting, as last loaded.
  static ListDuplicatesMode get mode => _mode ?? ListDuplicatesMode.off;

  static Future<void> ensureLoaded() => _loading ??= _load();

  static Future<void> _load() async {
    try {
      final saved = await SharedPreferencesAsync().getString(_key);
      _mode ??= ListDuplicatesMode.values.firstWhere(
        (mode) => mode.name == saved,
        orElse: () => ListDuplicatesMode.off,
      );
    } catch (e) {
      _logger.warning("Couldn't read the one-version setting", e);
      _mode ??= ListDuplicatesMode.off;
    }
  }

  static Future<void> setMode(ListDuplicatesMode value) async {
    await ensureLoaded();
    _mode = value;
    changed.value++;
    await SharedPreferencesAsync().setString(_key, value.name);
  }

  static const _otherLists = {
    QueueItemSourceType.album,
    QueueItemSourceType.artist,
    QueueItemSourceType.genre,
    QueueItemSourceType.filteredList,
    QueueItemSourceType.downloads,
    QueueItemSourceType.collection,
  };

  /// Whether a list started from [source] plays one version of each song, as last loaded. Songs added by hand (Play
  /// next, Add to queue), SyncPlay groups and generated queues aren't covered here.
  static bool appliesTo(QueueItemSource source) {
    final playlist = _isPlaylist(source);
    return switch (mode) {
      ListDuplicatesMode.off => false,
      ListDuplicatesMode.playlists => playlist,
      ListDuplicatesMode.everyList => playlist || _isOtherList(source),
    };
  }

  // A home screen section plays the playlist, album or other list pinned to it; one without an item plays a library
  // tab's songs, a list too. Its latest-queues section resumes queues as they were, so it isn't one. Jellyfin
  // collections played directly come as an unknown source holding the collection.
  static bool _isPlaylist(QueueItemSource source) =>
      source.type == QueueItemSourceType.playlist || _wrapped(source) == BaseItemDtoType.playlist;

  static bool _isOtherList(QueueItemSource source) =>
      _otherLists.contains(source.type) ||
      // Any home screen section (holding nothing, the list, or a song tapped in it) plays a list.
      source.type == QueueItemSourceType.homeScreenSection ||
      _wrappedLists.contains(_wrapped(source)) ||
      // Search results played as a list.
      source.type == QueueItemSourceType.unknown && source.id == "library-search";

  static const _wrappedLists = {
    BaseItemDtoType.album,
    BaseItemDtoType.artist,
    BaseItemDtoType.genre,
    BaseItemDtoType.collection,
    BaseItemDtoType.folder,
    BaseItemDtoType.library,
  };

  /// The kind of list a home screen section or unknown source holds, if any.
  static BaseItemDtoType? _wrapped(QueueItemSource source) {
    final item = source.item;
    if (item == null ||
        !const {QueueItemSourceType.homeScreenSection, QueueItemSourceType.unknown}.contains(source.type)) {
      return null;
    }
    return BaseItemDtoType.fromItem(item);
  }

  @visibleForTesting
  static void reset() {
    _mode = null;
    _loading = null;
  }
}
