import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:finamp/services/artist_spacing.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/services/scrobble_service.dart';
import 'package:finamp/services/listening_preferences.dart';
import 'package:finamp/services/skip_service.dart';
import 'package:finamp/services/stats_widget_service.dart';
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';

/// One listen of a track, as stored in the listening log.
class ListenEntry {
  ListenEntry({
    required this.time,
    required this.listened,
    required this.trackId,
    required this.track,
    this.artistId,
    this.artist,
    this.albumId,
    this.album,
    this.genres = const [],
    this.excludedFromLearning = false,
  });

  final DateTime time;
  final Duration listened;
  final String trackId;
  final String track;
  final String? artistId;
  final String? artist;
  final String? albumId;
  final String? album;
  final List<String> genres;
  final bool excludedFromLearning;

  factory ListenEntry.fromJson(Map<String, dynamic> json) => ListenEntry(
    time: DateTime.fromMillisecondsSinceEpoch(json["t"] as int),
    listened: Duration(milliseconds: json["ms"] as int),
    trackId: json["id"] as String,
    track: json["n"] as String,
    artistId: json["arId"] as String?,
    artist: json["ar"] as String?,
    albumId: json["alId"] as String?,
    album: json["al"] as String?,
    genres: (json["g"] as List?)?.cast<String>() ?? const [],
    excludedFromLearning: json['excludeLearning'] == true,
  );

  Map<String, dynamic> toJson() => {
    "t": time.millisecondsSinceEpoch,
    "ms": listened.inMilliseconds,
    "id": trackId,
    "n": track,
    if (artistId != null) "arId": artistId,
    if (artist != null) "ar": artist,
    if (albumId != null) "alId": albumId,
    if (album != null) "al": album,
    if (genres.isNotEmpty) "g": genres,
    if (excludedFromLearning) 'excludeLearning': true,
  };
}

/// Keeps a permanent on-device log of listens, which powers the year in music recap.
/// Playback history only lives for the session, so this is the only long-term record of what was played when.
class ListeningLogService {
  ListeningLogService._();

  static final _logger = Logger("ListeningLogService");

  /// Listens shorter than this are skips and aren't logged.
  static const minimumListen = Duration(seconds: 30);

  static Future<File> get _file async => File("${(await getApplicationSupportDirectory()).path}/listening_log.jsonl");

  /// Serializes writes so concurrent listens can't interleave lines.
  static Future<void> _pending = Future.value();

  /// Logs [historyItem] if it was listened to long enough.
  static void record(FinampHistoryItem historyItem) {
    final played = historyItem.playDuration;
    if (played == null) return;
    final base = historyItem.item.baseItem;
    final total = base.runTimeTicksDuration();
    final excluded = ListeningSession.excluded(historyItem);
    if (!excluded && SkipService.isSkip(played, total)) {
      unawaited(
        SkipService.recordSkip(
          trackId: base.id.raw,
          name: base.name ?? "",
          artist: base.albumArtist ?? base.artists?.firstOrNull,
          // Compilations show their album artist, but Radio tells artists apart by the track artist.
          artistKey: ArtistSpacing.artistKey(base),
        ),
      );
    }
    if (played < minimumListen) return;
    final entry = ListenEntry(
      time: historyItem.startTime,
      // Wall time includes pauses, so never count more than the track length.
      listened: total != null && played > total ? total : played,
      trackId: base.id.raw,
      track: base.name ?? "",
      artistId: base.albumArtists?.firstOrNull?.id.raw ?? base.artistItems?.firstOrNull?.id.raw,
      artist: base.albumArtist ?? base.artists?.firstOrNull,
      albumId: base.albumId?.raw,
      album: base.album,
      genres: base.genres ?? const [],
      excludedFromLearning: excluded,
    );
    ScrobbleService.onListen(entry, total);
    _pending = _pending.then((_) async {
      try {
        final file = await _file, line = "${jsonEncode(entry.toJson())}\n";
        await file.writeAsString(line, mode: FileMode.append, flush: true);
        await _appendLoaded(file, entry, utf8.encode(line).length);
        StatsWidgetService.scheduleRefresh();
      } catch (e) {
        _logger.warning("Failed to log listen of '${entry.track}'", e);
      }
    });
  }

  /// The log as last read, with the file's path, size and time then: several features read the whole log, and
  /// parsing it each time is costly. Read again when the file has changed other than by [record].
  static ({String path, int size, DateTime modified, List<ListenEntry> entries})? _loaded;

  /// All logged listens, oldest first.
  static Future<List<ListenEntry>> load({bool forLearning = false}) async {
    await _pending;
    final file = await _file;
    final stat = await file.stat();
    if (stat.type == FileSystemEntityType.notFound) {
      _loaded = null;
      return [];
    }
    var loaded = _loaded;
    if (loaded == null || loaded.path != file.path || loaded.size != stat.size || loaded.modified != stat.modified) {
      // A year of listens is tens of thousands of lines, so parse them off the UI thread.
      final entries = await Isolate.run(() {
        final entries = <ListenEntry>[];
        for (final line in file.readAsLinesSync()) {
          if (line.trim().isEmpty) continue;
          try {
            entries.add(ListenEntry.fromJson(jsonDecode(line) as Map<String, dynamic>));
          } catch (_) {
            // Skip a line cut short by the app being killed mid-write.
          }
        }
        return entries;
      });
      _loaded = loaded = (path: file.path, size: stat.size, modified: stat.modified, entries: entries);
    }
    // A list of its own, so a caller changing it doesn't change what the next one gets.
    return [
      for (final entry in loaded.entries)
        if (!forLearning || !entry.excludedFromLearning) entry,
    ];
  }

  /// Adds [entry], just written to the end of [file] in [bytes], to the log as last read when that was all the file
  /// held before; otherwise the log is read again next time.
  static Future<void> _appendLoaded(File file, ListenEntry entry, int bytes) async {
    final loaded = _loaded;
    if (loaded == null) return;
    _loaded = null;
    if (loaded.path != file.path) return;
    final stat = await file.stat();
    if (stat.size != loaded.size + bytes) return;
    _loaded = (path: file.path, size: stat.size, modified: stat.modified, entries: [...loaded.entries, entry]);
  }
}
