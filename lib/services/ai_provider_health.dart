import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show ValueNotifier, visibleForTesting;
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ai_service.dart';

/// How a text AI has been doing lately: after repeated failures it moves behind its backups for a while, so a slow or
/// failing primary doesn't cost every DJ line its time budget. It is tried first again once the pause is over.
class AiProviderStatus {
  const AiProviderStatus({this.failures = 0, this.pausedUntil});

  /// Failures in a row since the last success.
  final int failures;
  final DateTime? pausedUntil;

  bool pausedAt(DateTime now) => pausedUntil != null && now.isBefore(pausedUntil!);

  Map<String, dynamic> toJson() => {
    'failures': failures,
    if (pausedUntil != null) 'until': pausedUntil!.toIso8601String(),
  };

  factory AiProviderStatus.fromJson(Map<String, dynamic> json) => AiProviderStatus(
    failures: json['failures'] is int ? json['failures'] as int : 0,
    pausedUntil: json['until'] is String ? DateTime.tryParse(json['until'] as String) : null,
  );
}

class AiProviderHealth {
  AiProviderHealth._();

  static const _key = 'aiTextHealth';
  static final _logger = Logger('AiProviderHealth');

  /// Failures in a row before a provider moves behind its backups.
  static const failuresBeforePause = 2;
  static const firstPause = Duration(minutes: 10);
  static const longestPause = Duration(hours: 2);

  static Map<AiProvider, AiProviderStatus>? _status;
  static Future<void>? _loading;

  /// Changes whenever a provider is paused or recovers, for the settings screen.
  static final changes = ValueNotifier<int>(0);

  @visibleForTesting
  static DateTime Function() now = DateTime.now;

  static Future<Map<AiProvider, AiProviderStatus>> _load() async {
    if (_status != null) return _status!;
    await (_loading ??= () async {
      final status = <AiProvider, AiProviderStatus>{};
      try {
        final saved = await SharedPreferencesAsync().getString(_key);
        final json = saved == null ? null : jsonDecode(saved);
        if (json is Map<String, dynamic>) {
          for (final provider in AiProvider.values) {
            final value = json[provider.name];
            if (value is Map<String, dynamic>) status[provider] = AiProviderStatus.fromJson(value);
          }
        }
      } catch (_) {
        // Damaged health data starts fresh; it only affects the order providers are tried in.
      }
      _status = status;
    }());
    _loading = null;
    return _status!;
  }

  static Future<void> _save() async {
    final status = _status;
    if (status == null) return;
    try {
      await SharedPreferencesAsync().setString(
        _key,
        jsonEncode({for (final entry in status.entries) entry.key.name: entry.value.toJson()}),
      );
    } catch (_) {
      // Health still works for this session when it can't be saved.
    }
  }

  static Future<AiProviderStatus> status(AiProvider provider) async =>
      (await _load())[provider] ?? const AiProviderStatus();

  /// [providers] in the order to try them: the configured order, with paused providers moved to the end (the one
  /// whose pause ends first leads). Nothing is dropped, so a paused provider is still the last resort.
  static Future<List<AiProvider>> order(List<AiProvider> providers) async {
    final status = await _load();
    final time = now();
    final ready = providers.where((p) => !(status[p]?.pausedAt(time) ?? false)).toList();
    final paused = providers.where((p) => status[p]?.pausedAt(time) ?? false).toList()
      ..sort((a, b) => status[a]!.pausedUntil!.compareTo(status[b]!.pausedUntil!));
    return [...ready, ...paused];
  }

  static Future<void> succeeded(AiProvider provider) async {
    final status = await _load();
    final previous = status[provider];
    if (previous == null || (previous.failures == 0 && previous.pausedUntil == null)) return;
    status.remove(provider);
    if (previous.pausedUntil != null) _logger.info('${provider.displayName} is answering again');
    changes.value++;
    await _save();
  }

  static Future<void> failed(AiProvider provider) async {
    final status = await _load();
    final failures = (status[provider]?.failures ?? 0) + 1;
    DateTime? until = status[provider]?.pausedUntil;
    if (failures >= failuresBeforePause) {
      // 10, 20, 40... minutes, up to two hours, while it keeps failing.
      final doublings = (failures - failuresBeforePause).clamp(0, 10);
      var pause = firstPause * (1 << doublings);
      if (pause > longestPause) pause = longestPause;
      until = now().add(pause);
      _logger.info(
        '${provider.displayName} failed $failures times in a row; trying backups first for ${pause.inMinutes} min',
      );
    }
    status[provider] = AiProviderStatus(failures: failures, pausedUntil: until);
    changes.value++;
    await _save();
  }

  /// Forget all recorded failures, e.g. after the user changes keys.
  static Future<void> reset([AiProvider? provider]) async {
    final status = await _load();
    provider == null ? status.clear() : status.remove(provider);
    changes.value++;
    await _save();
  }

  @visibleForTesting
  static void forgetLoaded() {
    _status = null;
    _loading = null;
  }
}
