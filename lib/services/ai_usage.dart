import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show ValueNotifier, visibleForTesting;
import 'package:shared_preferences/shared_preferences.dart';

import 'ai_service.dart';

/// What one provider was used for on one day.
class AiUsageCount {
  AiUsageCount({
    this.requests = 0,
    this.failures = 0,
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.speechRequests = 0,
    this.speechCharacters = 0,
    this.speechMilliseconds = 0,
  });

  int requests;
  int failures;
  int inputTokens;
  int outputTokens;
  int speechRequests;
  int speechCharacters;
  int speechMilliseconds;

  int get allRequests => requests + speechRequests;

  void add(AiUsageCount other) {
    requests += other.requests;
    failures += other.failures;
    inputTokens += other.inputTokens;
    outputTokens += other.outputTokens;
    speechRequests += other.speechRequests;
    speechCharacters += other.speechCharacters;
    speechMilliseconds += other.speechMilliseconds;
  }

  Map<String, int> toJson() => {
    'r': requests,
    'f': failures,
    'in': inputTokens,
    'out': outputTokens,
    'sr': speechRequests,
    'sc': speechCharacters,
    'sms': speechMilliseconds,
  };

  factory AiUsageCount.fromJson(Map<String, dynamic> json) {
    int read(String key) => json[key] is int ? json[key] as int : 0;
    return AiUsageCount(
      requests: read('r'),
      failures: read('f'),
      inputTokens: read('in'),
      outputTokens: read('out'),
      speechRequests: read('sr'),
      speechCharacters: read('sc'),
      speechMilliseconds: read('sms'),
    );
  }
}

/// Counts AI requests, tokens and recorded speech per provider per day, kept for a month, with an optional daily
/// request limit. Only counts are kept: never prompts, answers or keys.
class AiUsage {
  AiUsage._();

  static const _key = 'aiUsage';
  static const _limitKey = 'aiDailyRequestLimit';
  static const keptDays = 31;

  /// Offered daily limits; 0 is no limit.
  static const limits = [0, 100, 250, 500, 1000];

  static Map<String, Map<AiProvider, AiUsageCount>>? _days;
  static Future<void>? _loading;
  static int? _limit;
  static Timer? _saveTimer;

  /// Changes whenever something is counted, for the settings screen.
  static final changes = ValueNotifier<int>(0);

  @visibleForTesting
  static DateTime Function() now = DateTime.now;

  static String _day(DateTime time) =>
      '${time.year.toString().padLeft(4, '0')}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')}';

  static Future<Map<String, Map<AiProvider, AiUsageCount>>> _load() async {
    if (_days != null) return _days!;
    await (_loading ??= () async {
      final days = <String, Map<AiProvider, AiUsageCount>>{};
      final prefs = SharedPreferencesAsync();
      try {
        final saved = await prefs.getString(_key);
        final json = saved == null ? null : jsonDecode(saved);
        if (json is Map<String, dynamic>) {
          for (final day in json.entries) {
            if (day.value is! Map<String, dynamic>) continue;
            days[day.key] = {
              for (final provider in AiProvider.values)
                if ((day.value as Map<String, dynamic>)[provider.name] is Map<String, dynamic>)
                  provider: AiUsageCount.fromJson(
                    (day.value as Map<String, dynamic>)[provider.name] as Map<String, dynamic>,
                  ),
            };
          }
        }
      } catch (_) {
        // Damaged usage data starts a fresh count.
      }
      try {
        _limit = await prefs.getInt(_limitKey) ?? 0;
      } catch (_) {
        _limit = 0;
      }
      _days = days;
    }());
    _loading = null;
    return _days!;
  }

  static void _changed() {
    changes.value++;
    _saveTimer?.cancel();
    // Several requests can finish together; one write covers them.
    _saveTimer = Timer(const Duration(seconds: 2), () => unawaited(flush()));
  }

  /// Writes pending counts now.
  static Future<void> flush() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    final days = _days;
    if (days == null) return;
    final oldest = _day(now().subtract(const Duration(days: keptDays - 1)));
    days.removeWhere((day, _) => day.compareTo(oldest) < 0);
    try {
      await SharedPreferencesAsync().setString(
        _key,
        jsonEncode({
          for (final day in days.entries) day.key: {for (final p in day.value.entries) p.key.name: p.value.toJson()},
        }),
      );
    } catch (_) {
      // Counting carries on in memory when it can't be saved.
    }
  }

  static Future<AiUsageCount> _today(AiProvider provider) async =>
      (await _load()).putIfAbsent(_day(now()), () => {}).putIfAbsent(provider, AiUsageCount.new);

  /// Counts one paid request to [provider] just before it's sent, or throws when that would go over the daily limit.
  /// A request is counted once sent, whatever happens to it, so backups, retries, extra voice takes and requests
  /// cancelled after sending all count, and requests made at the same moment can't share the last one left.
  static Future<void> reserve(AiProvider provider, {bool speech = false}) async {
    final days = await _load();
    // Nothing is awaited between the check and the count.
    final today = days.putIfAbsent(_day(now()), () => {});
    final limit = _limit ?? 0;
    if (limit > 0 && today.values.fold<int>(0, (sum, count) => sum + count.allRequests) >= limit) {
      throw AiException('Daily AI request limit of $limit reached', category: AiFailureCategory.limit);
    }
    final count = today.putIfAbsent(provider, AiUsageCount.new);
    speech ? count.speechRequests++ : count.requests++;
    _changed();
  }

  /// How a text request counted by [reserve] went.
  static Future<void> recordText(
    AiProvider provider, {
    required bool ok,
    int inputTokens = 0,
    int outputTokens = 0,
  }) async {
    final count = await _today(provider);
    if (!ok) count.failures++;
    count.inputTokens += inputTokens;
    count.outputTokens += outputTokens;
    _changed();
  }

  /// How a voice recording went; its requests are counted by [reserve].
  static Future<void> recordSpeech(AiProvider provider, {required bool ok, int characters = 0, Duration? audio}) async {
    final count = await _today(provider);
    if (!ok) count.failures++;
    count.speechCharacters += characters;
    count.speechMilliseconds += audio?.inMilliseconds ?? 0;
    _changed();
  }

  /// Totals per provider over the last [days] days, today included.
  static Future<Map<AiProvider, AiUsageCount>> total({int days = 1}) async {
    final all = await _load();
    final oldest = _day(now().subtract(Duration(days: days - 1)));
    final totals = <AiProvider, AiUsageCount>{};
    for (final day in all.entries.where((day) => day.key.compareTo(oldest) >= 0)) {
      for (final entry in day.value.entries) {
        totals.putIfAbsent(entry.key, AiUsageCount.new).add(entry.value);
      }
    }
    return totals;
  }

  static Future<int> dailyLimit() async {
    await _load();
    return _limit ?? 0;
  }

  static Future<void> setDailyLimit(int limit) async {
    await _load();
    _limit = limit < 0 ? 0 : limit;
    await SharedPreferencesAsync().setInt(_limitKey, _limit!);
    changes.value++;
  }

  /// Throws when today's requests across all providers have reached the daily limit, before any work starts. Each
  /// request is still checked by [reserve] as it's sent.
  static Future<void> checkLimit() async {
    final limit = await dailyLimit();
    if (limit <= 0) return;
    // Only today's counts, without adding up the month.
    final today = (await _load())[_day(now())] ?? const {};
    final used = today.values.fold<int>(0, (sum, count) => sum + count.allRequests);
    if (used >= limit) {
      throw AiException('Daily AI request limit of $limit reached', category: AiFailureCategory.limit);
    }
  }

  static Future<void> reset() async {
    (await _load()).clear();
    _changed();
    await flush();
  }

  @visibleForTesting
  static void forgetLoaded() {
    _saveTimer?.cancel();
    _saveTimer = null;
    _days = null;
    _loading = null;
    _limit = null;
  }
}
