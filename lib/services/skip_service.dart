import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';

/// How often a track was skipped early, and when last.
class SkipRecord {
  SkipRecord({required this.trackId, required this.name, required this.artist, required this.count, required this.last});

  final String trackId;
  final String name;
  final String? artist;
  int count;
  DateTime last;

  factory SkipRecord.fromJson(Map<String, dynamic> json) => SkipRecord(
    trackId: json["id"] as String,
    name: json["n"] as String? ?? "",
    artist: json["ar"] as String?,
    count: json["c"] as int? ?? 1,
    last: DateTime.fromMillisecondsSinceEpoch(json["t"] as int? ?? 0),
  );

  Map<String, dynamic> toJson() => {
    "id": trackId,
    "n": name,
    if (artist != null) "ar": artist,
    "c": count,
    "t": last.millisecondsSinceEpoch,
  };
}

/// Learns which songs get skipped early, so shuffles and mixes can play them less often.
/// Skips fade out over a few months, so a song skipped once in a bad mood comes back.
class SkipService {
  SkipService._();

  static final _logger = Logger("SkipService");
  static const _halfLife = Duration(days: 60);

  static Map<String, SkipRecord>? _records;
  static Future<void> _pending = Future.value();

  static Future<File> get _file async => File("${(await getApplicationSupportDirectory()).path}/skips.json");

  static Future<Map<String, SkipRecord>> _load() async {
    if (_records != null) return _records!;
    final records = <String, SkipRecord>{};
    try {
      final file = await _file;
      if (await file.exists()) {
        for (final json in jsonDecode(await file.readAsString()) as List<dynamic>) {
          final record = SkipRecord.fromJson(json as Map<String, dynamic>);
          records[record.trackId] = record;
        }
      }
    } catch (e) {
      _logger.warning("Couldn't read skips", e);
    }
    return _records ??= records;
  }

  static Future<void> _save() async {
    final records = _records;
    if (records == null) return;
    _pending = _pending.then((_) async {
      try {
        await (await _file).writeAsString(jsonEncode([for (final record in records.values) record.toJson()]));
      } catch (e) {
        _logger.warning("Couldn't save skips", e);
      }
    });
    await _pending;
  }

  /// Whether listening for [played] of a track lasting [total] counts as skipping it.
  static bool isSkip(Duration played, Duration? total) {
    if (played < const Duration(seconds: 2)) return false; // Flicking through, or an error.
    if (total == null || total < const Duration(seconds: 45)) return false;
    final limit = Duration(milliseconds: min(30000, total.inMilliseconds * 0.4).round());
    return played < limit;
  }

  static Future<void> recordSkip({required String trackId, required String name, String? artist}) async {
    final records = await _load();
    final record = records[trackId];
    if (record == null) {
      records[trackId] = SkipRecord(trackId: trackId, name: name, artist: artist, count: 1, last: DateTime.now());
    } else {
      record
        ..count = weightOf(record, DateTime.now()).round() + 1
        ..last = DateTime.now();
    }
    await _save();
  }

  /// The skip count of [record], faded by how long ago the last skip was.
  static double weightOf(SkipRecord record, DateTime now) {
    final age = now.difference(record.last).inMilliseconds / _halfLife.inMilliseconds;
    return record.count * pow(0.5, age).toDouble();
  }

  /// How likely a mix should still pick each track, from 1 (never skipped) down to 0.15.
  static Future<double Function(String trackId)> chanceToPlay() async {
    final records = await _load();
    final now = DateTime.now();
    return (String trackId) {
      final record = records[trackId];
      if (record == null) return 1.0;
      return max(0.15, 1 / (1 + weightOf(record, now)));
    };
  }

  /// Tracks skipped in the last couple of months (a skip counts for half after [_halfLife]), most skipped first.
  static Future<List<SkipRecord>> often() async {
    final records = await _load();
    final now = DateTime.now();
    return records.values.where((record) => weightOf(record, now) >= 0.5).toList()
      ..sort((a, b) => weightOf(b, now).compareTo(weightOf(a, now)));
  }

  static Future<void> forget(String trackId) async {
    (await _load()).remove(trackId);
    await _save();
  }

  static Future<void> forgetAll() async {
    (await _load()).clear();
    await _save();
  }

  /// Drops tracks from [items] at random, in proportion to how often they get skipped.
  static Future<List<T>> thinOut<T>(List<T> items, String Function(T item) id, {Random? random}) async {
    final chance = await chanceToPlay();
    final dice = random ?? Random();
    return items.where((item) => dice.nextDouble() < chance(id(item))).toList();
  }
}
