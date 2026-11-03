import 'dart:async';
import 'dart:io' show FileSystemException, HttpException, TlsException;

import 'package:finamp/services/network_status.dart';
import 'package:flutter/foundation.dart' show Uint8List, ValueNotifier, visibleForTesting;
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'artwork_file_cache.dart';

/// Covers drawn at a size (lists, grids, the home screen) saved on the phone, so they show at once after a restart and
/// offline instead of being fetched from the server every time Finamp opens. Kept apart from the player's covers, so
/// these many small ones don't push those out. Can be turned off in the download settings.
class CoverCache {
  CoverCache._();

  static const _key = 'saveCoversOnPhone';
  static final _logger = Logger('CoverCache');

  /// Whether covers are kept, for the settings switch: a settings reset changes it too.
  static final changes = ValueNotifier<bool>(true);

  /// Read synchronously as covers load; loaded at startup and kept up to date by [setEnabled].
  static bool get enabled => changes.value;
  static set enabled(bool value) => changes.value = value;

  // The library only limits how many files are kept, not their size: 2000 list and grid covers, mostly a few tens of
  // kilobytes each. It's not a hard cap: on phones covers seen in the last day are never removed, and at most 100 go
  // per cleanup, so it can briefly hold more.
  static CacheManager? _manager;
  static CacheManager get _cache => _manager ??= CacheManager(
    Config('finampCovers', stalePeriod: const Duration(days: 365), maxNrOfCacheObjects: 2000),
  );

  @visibleForTesting
  static ArtworkFileCache files = ArtworkFileCache(
    read: (key) => _cache.getFileFromCache(key),
    download: (url, key) => _cache.downloadFile(url, key: key),
    maximumEntries: 512,
  );

  /// A cover found by its blurhash can't change without its key changing, so it's kept a year instead of the
  /// server's default week.
  @visibleForTesting
  static Future<void> Function(String key) keepForAYear = (key) async {
    final saved = await _cache.store.retrieveCacheData(key);
    if (saved == null) return;
    await _cache.store.putFile(saved.copyWith(validTill: DateTime.now().add(const Duration(days: 365))));
  };

  @visibleForTesting
  static Future<void> Function() empty = () => _cache.emptyCache();

  /// The cover at [url] straight from the server, not kept: for when the phone's storage fails.
  static Future<Uint8List> fetch(String url) => fetcher(url);

  /// Whether [error] came from the server or the connection rather than the phone's storage: asking again directly
  /// would only fail the same way, and double the requests.
  static bool isNetworkFailure(Object error) => error is TlsException || NetworkStatus.isNetworkFailure(error);

  @visibleForTesting
  static Future<Uint8List> Function(String url) fetcher = (url) async {
    final response = await http.get(Uri.parse(url));
    if (response.statusCode != 200) throw HttpException('Cover request answered ${response.statusCode}');
    return response.bodyBytes;
  };

  @visibleForTesting
  static Future<void> Function(String key) forget = (key) => _cache.removeFile(key);

  static Future<bool> load() async {
    try {
      enabled = await SharedPreferencesAsync().getBool(_key) ?? true;
    } catch (_) {}
    // Turned off, covers a download was still saving as it was turned off go too.
    if (!enabled) unawaited(_empty());
    return enabled;
  }

  /// Turning it off also deletes the saved covers, freeing their space.
  static Future<void> setEnabled(bool value) async {
    enabled = value;
    try {
      await SharedPreferencesAsync().setBool(_key, value);
    } finally {
      // Even when the setting can't be saved (a full phone), turning it off still frees the covers' space.
      if (!value) await _empty();
    }
  }

  static Future<void> _empty() async {
    try {
      await empty();
    } catch (e) {
      _logger.warning('Saved covers could not be deleted', e);
    }
  }

  /// A saved cover that turned out not to be an image (a server or proxy answering with something else) is deleted,
  /// so the next load asks the server again instead of failing on it at every start.
  static Future<void> discard(String key) async {
    files.drop(key);
    try {
      await forget(key);
    } catch (e) {
      _logger.fine('Could not delete a broken cover', e);
    }
  }

  /// How long a look in the saved covers may take. The cache library can wait forever on a damaged covers database,
  /// which would leave covers blank although the server could send them.
  @visibleForTesting
  static Duration lookupLimit = const Duration(seconds: 3);

  /// Set once the saved covers didn't answer in time; until Finamp restarts, covers come straight from the server
  /// rather than each waiting out [lookupLimit].
  static bool _storageStuck = false;

  @visibleForTesting
  static void forgetStuckStorage() => _storageStuck = false;

  /// The saved cover for [key], even an old one, without going to the server: for offline.
  static Future<FileInfo?> saved(String key) async {
    if (_storageStuck) return null;
    return files
        .readStale(key)
        .timeout(
          lookupLimit,
          onTimeout: () {
            _storageStuck = true;
            return null;
          },
        );
  }

  /// The cover at [url]: the one saved on the phone, or downloaded and saved now. Throws a [FileSystemException] when
  /// the saved covers can't be used, so the caller can fetch the cover directly.
  static Future<Uint8List> bytes(String url, String key, {bool stable = false}) async {
    if (_storageStuck) throw const FileSystemException("The saved covers didn't answer earlier");
    try {
      await files.readCached(key).timeout(lookupLimit);
    } on TimeoutException {
      _storageStuck = true;
      _logger.warning("The saved covers didn't answer, fetching covers directly until Finamp restarts");
      throw const FileSystemException("The saved covers didn't answer");
    }
    // Found by then, or known not to be there: this gets it from memory or downloads it.
    final info = await files.load(key, url);
    final bytes = await info.file.readAsBytes();
    // Neither of these is needed to show the cover, so a slow covers database doesn't hold it up.
    if (!enabled) {
      // Turned off while it downloaded: it's still shown, but not kept.
      unawaited(_quietly(forget(key), 'Could not delete a cover'));
    } else if (stable && info.source == FileSource.Online) {
      unawaited(_quietly(keepForAYear(key), 'Could not keep a cover for a year'));
    }
    return bytes;
  }

  static Future<void> _quietly(Future<void> work, String failure) async {
    try {
      await work;
    } catch (e) {
      _logger.fine(failure, e);
    }
  }
}
