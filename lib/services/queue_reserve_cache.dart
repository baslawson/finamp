import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:uuid/uuid.dart';

/// Only complete files are playable. A source is resolved when the decoder
/// requests it, so a queue created before its download finishes still benefits.
/// Uncached sources redirect to the existing streaming URL, including HLS.
class QueueReserveCache {
  QueueReserveCache(this.root, {this.maxFileBytes = 128 * 1024 * 1024, this.maxTotalBytes = 512 * 1024 * 1024});
  final Directory root;
  final int maxFileBytes;
  final int maxTotalBytes;
  Future<int> _remainingBytes() async {
    var used = 0;
    if (await root.exists()) {
      await for (final entity in root.list(followLinks: false)) {
        if (entity is File && entity.path.contains('.audio')) used += await entity.length();
      }
    }
    return (maxTotalBytes - used).clamp(0, maxTotalBytes);
  }

  final _token = const Uuid().v4();
  final _sources = <String, ({String key, Uri remote, String playback})>{};
  final _selection = <String, bool>{};
  final _readers = <String, int>{};
  Set<String> _activePlaybacks = {};
  void activePlaybacks(Set<String> ids) {
    _activePlaybacks = ids;
  }

  bool _pinned(String key) => _sources.values.any(
    (entry) =>
        entry.key == key &&
        _activePlaybacks.contains(entry.playback) &&
        (_selection['${entry.playback}:${entry.key}'] ?? false),
  );
  Future<bool> get hasOwnedFiles async =>
      await root.exists() &&
      await root
          .list(followLinks: false)
          .any((entity) => entity is File && _valid.hasMatch(entity.uri.pathSegments.last.split('.').first));
  void retainPlaybacks(Set<String> ids) {
    _sources.removeWhere((_, entry) => !ids.contains(entry.playback) && (_readers[entry.key] ?? 0) == 0);
    final choices = {for (final entry in _sources.values) '${entry.playback}:${entry.key}'};
    _selection.removeWhere((id, _) => !choices.contains(id));
  }

  HttpServer? _server;
  Future<HttpServer>? _opening;
  static final _valid = RegExp(r'^[0-9a-f]{64}$');
  File file(String key) {
    if (!_valid.hasMatch(key)) throw ArgumentError('Invalid reserve key');
    return File('${root.path}/$key.audio');
  }

  Future<bool> contains(String key) async => await file(key).exists();
  Future<T> withRead<T>(String key, Future<T> Function() action) async {
    _readers[key] = (_readers[key] ?? 0) + 1;
    try {
      return await action();
    } finally {
      final remaining = (_readers[key] ?? 1) - 1;
      if (remaining == 0) {
        _readers.remove(key);
      } else {
        _readers[key] = remaining;
      }
    }
  }

  Future<Uri> source(String key, Uri remote, {String? playbackId}) async {
    file(key); // Validate before publishing a URL.
    final id = const Uuid().v4();
    _sources[id] = (key: key, remote: remote, playback: playbackId ?? id);
    final server = _server ??= await (_opening ??= HttpServer.bind(InternetAddress.loopbackIPv4, 0).then((server) {
      server.listen((request) => unawaited(_serve(request)));
      return server;
    }));
    final suffix = remote.path.endsWith('.m3u8') ? 'main.m3u8' : 'audio';
    return Uri.parse('http://127.0.0.1:${server.port}/$_token/$id/$suffix');
  }

  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    try {
      final parts = request.uri.pathSegments;
      if (parts.length != 3 ||
          parts[0] != _token ||
          !_sources.containsKey(parts[1]) ||
          !{'GET', 'HEAD'}.contains(request.method)) {
        response.statusCode = HttpStatus.notFound;
        return;
      }
      final entry = _sources[parts[1]]!, key = entry.key;
      final asset = parts[2];
      if (asset != 'main.m3u8' && asset != 'audio' && !RegExp(r'^segment-\d+$').hasMatch(asset)) {
        response.statusCode = HttpStatus.notFound;
        return;
      }
      final cached = asset.startsWith('segment-') ? File('${file(key).path}.$asset') : file(key);
      _readers[key] = (_readers[key] ?? 0) + 1;
      try {
        final complete = await cached.exists();
        // Both crossfade decoders must hear the same rendition, even if a
        // download finishes between their requests. Pin at first decoder use.
        final useCache = _selection.putIfAbsent('${entry.playback}:${entry.key}', () => complete);
        if (!useCache || !complete) {
          response.statusCode = HttpStatus.temporaryRedirect;
          response.headers.set(HttpHeaders.locationHeader, entry.remote.toString());
          return;
        }
        final size = await cached.length();
        final range = byteRange(request.headers.value(HttpHeaders.rangeHeader), size);
        if (range == null) {
          response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$size');
          return;
        }
        final mime = File('${cached.path}.mime');
        response.headers.contentType = ContentType.parse(
          await mime.exists() ? await mime.readAsString() : 'application/octet-stream',
        );
        response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        response.contentLength = range.$2 - range.$1;
        if (request.headers.value(HttpHeaders.rangeHeader) != null) {
          response.statusCode = HttpStatus.partialContent;
          response.headers.set(HttpHeaders.contentRangeHeader, 'bytes ${range.$1}-${range.$2 - 1}/$size');
        }
        if (request.method == 'GET') await response.addStream(cached.openRead(range.$1, range.$2));
      } finally {
        _readers[key] = (_readers[key] ?? 1) - 1;
      }
    } on Object {
      // A player may cancel a request during a seek. Never log authenticated URLs.
    } finally {
      await response.close().catchError((Object _) {});
    }
  }

  /// End is exclusive, matching File.openRead. Reject malformed/multiple ranges.
  static (int, int)? byteRange(String? header, int size) {
    if (size <= 0) return null;
    if (header == null) return (0, size);
    final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(header);
    if (match == null) return null;
    final start = int.tryParse(match[1]!), end = int.tryParse(match[2]!);
    if (start == null) return end == null || end <= 0 ? null : ((size - end).clamp(0, size), size);
    if (start >= size || (end != null && end < start)) return null;
    return (start, end == null ? size : (end + 1).clamp(0, size));
  }

  Future<bool> download(String key, Uri source, {required bool Function() wanted}) async {
    if (await contains(key)) return true;
    final budget = await _remainingBytes();
    if (budget <= 0 || !wanted()) return false;
    final target = file(key), partial = File('${file(key).path}.part');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    IOSink? sink;
    try {
      await root.create(recursive: true);
      final request = await client.getUrl(source).timeout(const Duration(seconds: 15));
      final response = await request.close().timeout(const Duration(seconds: 15));
      final mime = response.headers.contentType?.mimeType ?? 'application/octet-stream';
      if (response.statusCode != 200 ||
          response.contentLength > maxFileBytes ||
          !(mime.startsWith('audio/') ||
              mime == 'application/octet-stream' ||
              mime == 'application/ogg' ||
              mime.contains('mpegurl'))) {
        return false;
      }
      if (source.path.endsWith('.m3u8') || mime.contains('mpegurl')) {
        return await _downloadHls(key, source, response, client, wanted, budget);
      }
      sink = partial.openWrite();
      var bytes = 0;
      final elapsed = Stopwatch()..start();
      await for (final block in response.timeout(const Duration(seconds: 20))) {
        bytes += block.length;
        if (!wanted() || bytes > maxFileBytes || bytes > budget || elapsed.elapsed > const Duration(minutes: 2)) {
          return false;
        }
        sink.add(block);
        // Apply backpressure: the whole file must never accumulate in memory.
        await sink.flush();
      }
      await sink.close();
      sink = null;
      if (!wanted() ||
          bytes == 0 ||
          bytes + utf8.encode(mime).length > budget ||
          (response.contentLength >= 0 && response.contentLength != bytes)) {
        return false;
      }
      await File('${target.path}.mime').writeAsString(mime, flush: true);
      await partial.rename(target.path);
      return true;
    } on Object {
      return false;
    } finally {
      client.close(force: true);
      await sink?.close().catchError((Object _) {});
      if (await partial.exists()) await partial.delete();
    }
  }

  Future<bool> _downloadHls(
    String key,
    Uri source,
    HttpClientResponse response,
    HttpClient client,
    bool Function() wanted,
    int budget,
  ) async {
    final assets = <File>[];
    var complete = false, total = 0;
    final elapsed = Stopwatch()..start();
    try {
      Future<String> playlist(HttpClientResponse input) async {
        final bytes = <int>[];
        await for (final block in input.timeout(const Duration(seconds: 20))) {
          bytes.addAll(block);
          if (!wanted() || bytes.length > 1024 * 1024) throw const FormatException('Invalid reserve playlist');
        }
        return utf8.decode(bytes);
      }

      var manifest = await playlist(response), base = source;
      for (var depth = 0; manifest.contains('#EXT-X-STREAM-INF:') && depth < 3; depth++) {
        final variant = manifest
            .split('\n')
            .map((line) => line.trim())
            .firstWhere((line) => line.isNotEmpty && !line.startsWith('#'));
        base = base.resolve(variant);
        final result = await (await client.getUrl(base)).close().timeout(const Duration(seconds: 15));
        if (result.statusCode != 200) return false;
        manifest = await playlist(result);
      }
      // Never save an incomplete/live playlist as a complete offline song.
      if (!manifest.startsWith('#EXTM3U') ||
          !manifest.contains('#EXT-X-ENDLIST') ||
          manifest.contains('#EXT-X-STREAM-INF:')) {
        return false;
      }
      final mapped = <Uri, String>{};
      Future<String> segment(String value) async {
        final uri = base.resolve(value);
        if (!{'http', 'https'}.contains(uri.scheme)) throw const FormatException('Invalid segment URI');
        if (mapped[uri] case final String existing) return existing;
        final name = 'segment-${mapped.length}';
        final output = File('${file(key).path}.$name');
        assets.add(output);
        final input = await (await client.getUrl(uri)).close().timeout(const Duration(seconds: 15));
        if (input.statusCode != 200 || input.contentLength + total > maxFileBytes) {
          throw const FormatException('Invalid segment response');
        }
        final sink = output.openWrite();
        var bytes = 0;
        try {
          await for (final block in input.timeout(const Duration(seconds: 20))) {
            total += block.length;
            bytes += block.length;
            if (!wanted() || total > maxFileBytes || total > budget || elapsed.elapsed > const Duration(minutes: 2)) {
              throw const FormatException('Reserve limit');
            }
            sink.add(block);
            await sink.flush();
          }
        } finally {
          await sink.close();
        }
        if (bytes == 0 || (input.contentLength >= 0 && bytes != input.contentLength)) {
          throw const FormatException('Incomplete segment');
        }
        mapped[uri] = name;
        return name;
      }

      final lines = <String>[];
      for (final original in manifest.split('\n')) {
        var line = original.trim();
        if (line.isNotEmpty && !line.startsWith('#')) {
          line = await segment(line);
        } else {
          final matches = RegExp('URI="([^"]+)"').allMatches(line).toList();
          for (final match in matches.reversed) {
            line = line.replaceRange(match.start, match.end, 'URI="${await segment(match[1]!)}"');
          }
        }
        lines.add(line);
      }
      if (!wanted() || mapped.isEmpty) return false;
      final body = lines.join('\n'), mime = 'application/vnd.apple.mpegurl';
      if (total + utf8.encode(body).length + mime.length > budget || total + utf8.encode(body).length > maxFileBytes) {
        return false;
      }
      final temporary = File('${file(key).path}.part');
      await temporary.writeAsString(body, flush: true);
      await File('${file(key).path}.mime').writeAsString(mime, flush: true);
      await temporary.rename(file(key).path);
      return complete = true;
    } on Object {
      return false;
    } finally {
      if (!complete) {
        for (final asset in assets) {
          if (await asset.exists()) await asset.delete();
        }
      }
    }
  }

  Future<void> trim(Set<String> keep) async {
    if (!await root.exists()) return;
    await for (final entry in root.list(followLinks: false)) {
      if (entry is! File) continue;
      final name = entry.uri.pathSegments.last;
      final key = name.split('.').first;
      if (_valid.hasMatch(key) && !keep.contains(key) && !_pinned(key) && (_readers[key] ?? 0) == 0) {
        await entry.delete();
      }
    }
  }

  Future<void> close() async {
    await _server?.close(force: true);
  }
}
