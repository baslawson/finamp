import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// A bounded fast path for recently used artwork. Files remain in the disk
/// cache; only their metadata is evicted here. Concurrent requests share work.
class ArtworkFileCache {
  ArtworkFileCache({required this.read, required this.download, this.maximumEntries = 128, DateTime Function()? now})
    : assert(maximumEntries > 0),
      _now = now ?? DateTime.now;

  final Future<FileInfo?> Function(String key) read;
  final Future<FileInfo> Function(String url, String key) download;
  final int maximumEntries;
  final DateTime Function() _now;
  final _files = <String, FileInfo>{};
  final _pending = <String, Future<FileInfo>>{};
  final _pendingReads = <String, Future<FileInfo?>>{};

  int get length => _files.length;

  bool _valid(FileInfo file) => file.validTill.isAfter(_now()) && file.file.existsSync();

  FileInfo? peek(String key) {
    final file = _files.remove(key);
    if (file == null || !_valid(file)) return null;
    _remember(key, file);
    return file;
  }

  void _remember(String key, FileInfo file) {
    _files.remove(key);
    _files[key] = file;
    while (_files.length > maximumEntries) {
      _files.remove(_files.keys.first);
    }
  }

  /// Disk-only lookup also works after a cold offline launch. It must never
  /// start a network request or require warming the complete cache at startup.
  Future<FileInfo?> readCached(String key) => _pendingReads.putIfAbsent(key, () {
    return (() async {
      final memory = peek(key);
      if (memory != null) return memory;
      final disk = await read(key);
      if (disk == null || !_valid(disk)) return null;
      _remember(key, disk);
      return disk;
    })().whenComplete(() {
      _pendingReads.remove(key);
    });
  });

  Future<FileInfo> load(String key, String url) => _pending.putIfAbsent(key, () {
    return (() async {
      final cached = await readCached(key);
      final file = cached ?? await download(url, key);
      _remember(key, file);
      return file;
    })().whenComplete(() {
      _pending.remove(key);
    });
  });
}
