import 'dart:convert';

/// Only acknowledged data is suppressed. Failed uploads and updated durations
/// remain eligible, and playing queues still send their normal heartbeats.
class SyncUploadCache {
  final _history = <String, String>{};
  String? _queue;

  List<Map<String, Object>> pendingHistory(List<Map<String, Object>> items) {
    // Retain the current history window, rather than evicting a recent item
    // when a new listen enters a newest-first list.
    final ids = items.map((item) => item['id']).toSet();
    _history.removeWhere((id, _) => !ids.contains(id));
    return [
      for (final item in items)
        if (_history[item['id']] != jsonEncode(item)) item,
    ];
  }

  void acknowledgeHistory(List<Map<String, Object>> items) {
    for (final item in items) {
      final id = item['id']! as String;
      _history.remove(id);
      _history[id] = jsonEncode(item);
    }
    while (_history.length > 200) {
      _history.remove(_history.keys.first);
    }
  }

  bool shouldSendQueue(Map<String, Object> queue) =>
      queue['playing'] == true || queue['claim'] == true || _queue != jsonEncode(queue);
  void acknowledgeQueue(Map<String, Object> queue) => _queue = jsonEncode(queue);

  void clear() {
    _history.clear();
    _queue = null;
  }
}

/// The server's tag for the stations and preferences this device last took in full, while they're still as they were
/// left then: polling with it, an unchanged server answers in a few bytes and there's nothing to merge.
class SyncConfigCache {
  String? _scope, _tag, _local;

  /// The tag to poll with, if [local] (this device's configuration now, encoded) is still as it was left.
  String? tagFor(String scope, String local) => scope == _scope && local == _local ? _tag : null;

  /// After a full sync: the server's [tag] (null from an older server, or with edits still to send) and [local] as it
  /// was left.
  void settle(String scope, String? tag, String local) {
    _scope = scope;
    _tag = tag;
    _local = tag == null ? null : local;
  }

  void clear() => _scope = _tag = _local = null;
}

/// Failed optional sync work backs off; switching accounts or an explicit user
/// action bypasses the delay. Music requests never use this schedule.
class SyncRetrySchedule {
  SyncRetrySchedule({DateTime Function()? now}) : _now = now ?? DateTime.now;
  final DateTime Function() _now;
  String? _scope;
  DateTime? _retryAfter;
  int _failures = 0;

  bool ready(String scope, {bool force = false}) {
    if (_scope != scope || force) {
      _scope = scope;
      succeeded();
    }
    return !(_retryAfter?.isAfter(_now()) ?? false);
  }

  void failed() {
    _failures = (_failures + 1).clamp(1, 3);
    _retryAfter = _now().add(Duration(seconds: 30 * (1 << (_failures - 1))));
  }

  void succeeded() {
    _failures = 0;
    _retryAfter = null;
  }
}
