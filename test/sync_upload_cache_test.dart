import 'package:finamp/services/sync_upload_cache.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Map<String, Object> play(String id, [int played = 1000]) => {
    'id': id,
    'song': 'song-$id',
    'startedMs': 1,
    'playedMs': played,
  };
  Map<String, Object> queue({bool playing = false, int position = 1000, bool claim = false}) => {
    'ids': ['a', 'b'],
    'index': 0,
    'positionMs': position,
    'playing': playing,
    'device': 'phone',
    'claim': claim,
  };

  test('unchanged paused snapshots and history upload once across 60 sync ticks', () {
    final uploads = SyncUploadCache();
    var histories = 0, queues = 0;
    for (var tick = 0; tick < 60; tick++) {
      final pending = uploads.pendingHistory([play('a'), play('b')]);
      if (pending.isNotEmpty) {
        histories++;
        uploads.acknowledgeHistory(pending);
      }
      final snapshot = queue();
      if (uploads.shouldSendQueue(snapshot)) {
        queues++;
        uploads.acknowledgeQueue(snapshot);
      }
    }
    expect(histories, 1);
    expect(queues, 1);
  });

  test('failed requests remain retryable and later duration updates are never lost', () {
    final uploads = SyncUploadCache();
    final first = uploads.pendingHistory([play('a')]);
    expect(uploads.pendingHistory([play('a')]), first);
    uploads.acknowledgeHistory(first);
    expect(uploads.pendingHistory([play('a')]), isEmpty);
    expect(uploads.pendingHistory([play('a', 2000)]), [play('a', 2000)]);
    expect(uploads.shouldSendQueue(queue()), isTrue);
    expect(uploads.shouldSendQueue(queue()), isTrue);
  });

  test('a rolling newest-first history window uploads only each new listen', () {
    final uploads = SyncUploadCache();
    var window = List.generate(200, (index) => play('${199 - index}'));
    uploads.acknowledgeHistory(uploads.pendingHistory(window));
    for (var next = 200; next < 700; next++) {
      window = [play('$next'), ...window.take(199)];
      final pending = uploads.pendingHistory(window);
      expect(pending, [play('$next')]);
      uploads.acknowledgeHistory(pending);
      expect(uploads.pendingHistory(window), isEmpty);
    }
  });

  test('playing heartbeats, seeks, queue ownership claims and account changes still upload', () {
    final uploads = SyncUploadCache();
    uploads.acknowledgeQueue(queue());
    expect(uploads.shouldSendQueue(queue()), isFalse);
    expect(uploads.shouldSendQueue(queue(position: 2000)), isTrue);
    expect(uploads.shouldSendQueue(queue(claim: true)), isTrue);
    uploads.acknowledgeQueue(queue(claim: true));
    expect(uploads.shouldSendQueue(queue(claim: true)), isTrue, reason: 'Every explicit claim must reach the server');
    final playing = queue(playing: true);
    uploads.acknowledgeQueue(playing);
    expect(uploads.shouldSendQueue(playing), isTrue);
    uploads.acknowledgeHistory([play('a')]);
    uploads.clear();
    expect(uploads.pendingHistory([play('a')]), hasLength(1));
    expect(uploads.shouldSendQueue(queue()), isTrue);
  });

  test('failed optional sync backs off but user actions and new accounts retry immediately', () {
    var now = DateTime(2026, 10, 21);
    final retries = SyncRetrySchedule(now: () => now);
    expect(retries.ready('account-a'), isTrue);
    retries.failed();
    now = now.add(const Duration(seconds: 29));
    expect(retries.ready('account-a'), isFalse);
    now = now.add(const Duration(seconds: 1));
    expect(retries.ready('account-a'), isTrue);
    retries.failed();
    now = now.add(const Duration(seconds: 30));
    expect(retries.ready('account-a'), isFalse);
    expect(retries.ready('account-a', force: true), isTrue);
    retries.failed();
    expect(retries.ready('account-b'), isTrue);
    retries.failed();
    retries.succeeded();
    expect(retries.ready('account-b'), isTrue);
  });
}
