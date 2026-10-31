import 'dart:math';

import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/services/downloads_service.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:finamp/services/server_sync_service.dart';
import 'package:finamp/services/sync_upload_cache.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a saved shuffled queue comes back in its original order, as it always did', () {
    final random = Random(7);
    for (final length in [1, 2, 5, 300]) {
      final original = [for (var i = 0; i < length; i++) 'track $i'];
      final order = [for (var i = 0; i < length; i++) i]..shuffle(random);
      // The shuffled queue as saved: the i-th one is the original order[i]-th.
      final shuffled = [for (final at in order) original[at]];
      expect(QueueService.unshuffle(shuffled, order), original);
      // The way it used to be done, one search per track.
      expect(QueueService.unshuffle(shuffled, order), [for (var x = 0; x < length; x++) shuffled[order.indexOf(x)]]);
    }
    expect(QueueService.unshuffle(<String>[], <int>[]), isEmpty);
  });

  test('hub sync polls every 30 seconds on screen, every 3 minutes playing in the background, else every 15', () {
    final now = DateTime(2026, 10, 27, 12);
    final recently = now.subtract(const Duration(seconds: 30));
    expect(ServerSyncService.pollDue(playing: true, foreground: true, lastPoll: recently, now: now), isTrue);
    expect(ServerSyncService.pollDue(playing: true, foreground: false, lastPoll: recently, now: now), isFalse);
    final almost = now.subtract(const Duration(minutes: 2, seconds: 59));
    expect(ServerSyncService.pollDue(playing: true, foreground: false, lastPoll: almost, now: now), isFalse);
    final three = now.subtract(const Duration(minutes: 3));
    expect(ServerSyncService.pollDue(playing: true, foreground: false, lastPoll: three, now: now), isTrue);
    expect(ServerSyncService.pollDue(playing: false, foreground: false, lastPoll: three, now: now), isFalse);
    expect(ServerSyncService.pollDue(playing: false, foreground: true, lastPoll: recently, now: now), isTrue);
    expect(ServerSyncService.pollDue(playing: false, foreground: false, lastPoll: recently, now: now), isFalse);
    final earlier = now.subtract(const Duration(minutes: 14, seconds: 59));
    expect(ServerSyncService.pollDue(playing: false, foreground: false, lastPoll: earlier, now: now), isFalse);
    final quarter = now.subtract(const Duration(minutes: 15));
    expect(ServerSyncService.pollDue(playing: false, foreground: false, lastPoll: quarter, now: now), isTrue);
    expect(ServerSyncService.pollDue(playing: false, foreground: false, now: now), isTrue, reason: 'never polled');
    final unsent = now.add(const Duration(minutes: 10));
    expect(
      ServerSyncService.pollDue(playing: false, foreground: false, lastPoll: recently, unsentUntil: unsent, now: now),
      isTrue,
      reason: 'a pause not yet sent',
    );
    expect(
      ServerSyncService.pollDue(playing: false, foreground: false, lastPoll: recently, unsentUntil: recently, now: now),
      isFalse,
      reason: 'given up on after 15 minutes, back to polling every 15',
    );
    final ahead = now.add(const Duration(hours: 1));
    expect(
      ServerSyncService.pollDue(playing: false, foreground: false, lastPoll: ahead, now: now),
      isTrue,
      reason: 'the clock was set back',
    );
  });

  test('hub sync asks only whether the server changed while this device is as it left it', () {
    final config = SyncConfigCache();
    expect(config.tagFor('account', 'local'), isNull, reason: 'never synced');
    config.settle('account', 'tag', 'local');
    expect(config.tagFor('account', 'local'), 'tag');
    expect(config.tagFor('account', 'edited'), isNull, reason: 'edited here since: sent in full');
    expect(config.tagFor('other account', 'local'), isNull);
    config.settle('account', null, 'local');
    expect(config.tagFor('account', 'local'), isNull, reason: 'an older server, or edits still to send');
    config.settle('account', 'tag', 'local');
    config.clear();
    expect(config.tagFor('account', 'local'), isNull, reason: 'the account changed');
  });

  test('downloads are checked with the server at most every 12 hours when the app starts', () {
    final now = DateTime(2026, 10, 27, 12);
    expect(DownloadsService.resyncDue(null, now), isTrue, reason: 'never checked');
    expect(DownloadsService.resyncDue(now.subtract(const Duration(hours: 1)), now), isFalse);
    expect(DownloadsService.resyncDue(now.subtract(const Duration(hours: 11, minutes: 59)), now), isFalse);
    expect(DownloadsService.resyncDue(now.subtract(const Duration(hours: 12)), now), isTrue);
    expect(DownloadsService.resyncDue(now.subtract(const Duration(days: 3)), now), isTrue);
    expect(
      DownloadsService.resyncDue(now.add(const Duration(hours: 2)), now),
      isTrue,
      reason: 'the clock was set back',
    );
  });

  group('a harmonic order worked out in the background', () {
    final made = (
      current: 3,
      turnedOff: 0,
      orderChanges: 0,
      requests: 0,
      playbackOrder: FinampPlaybackOrder.linear,
      items: ['a', 'b', 'c', 'd', 'e', 'f'],
      order: [0, 1, 2, 3, 4, 5],
    );

    test('is applied to the queue it was made for', () {
      expect(
        QueueService.sameQueue(made, (
          current: 3,
          turnedOff: 0,
          orderChanges: 0,
          requests: 0,
          playbackOrder: FinampPlaybackOrder.linear,
          items: ['a', 'b', 'c', 'd', 'e', 'f'],
          order: [0, 1, 2, 3, 4, 5],
        )),
        isTrue,
      );
    });

    test('is not applied once the queue has changed meanwhile, though as long and at the same place', () {
      expect(
        QueueService.sameQueue(made, (
          current: 4,
          turnedOff: 0,
          orderChanges: 0,
          requests: 0,
          playbackOrder: FinampPlaybackOrder.linear,
          items: made.items,
          order: made.order,
        )),
        isFalse,
        reason: 'moved on',
      );
      expect(
        QueueService.sameQueue(made, (
          current: 3,
          turnedOff: 1,
          orderChanges: 0,
          requests: 0,
          playbackOrder: FinampPlaybackOrder.linear,
          items: made.items,
          order: made.order,
        )),
        isFalse,
        reason: 'harmonic order turned off',
      );
      expect(
        QueueService.sameQueue(made, (
          current: 3,
          turnedOff: 0,
          orderChanges: 2,
          requests: 0,
          playbackOrder: FinampPlaybackOrder.linear,
          items: made.items,
          order: made.order,
        )),
        isFalse,
        reason: 'shuffled and back',
      );
      expect(
        QueueService.sameQueue(made, (
          current: 3,
          turnedOff: 0,
          orderChanges: 0,
          requests: 1,
          playbackOrder: FinampPlaybackOrder.linear,
          items: made.items,
          order: made.order,
        )),
        isFalse,
        reason: 'another list started',
      );
      expect(
        QueueService.sameQueue(made, (
          current: 3,
          turnedOff: 0,
          orderChanges: 0,
          requests: 0,
          playbackOrder: FinampPlaybackOrder.shuffled,
          items: made.items,
          order: made.order,
        )),
        isFalse,
        reason: 'shuffled',
      );
      expect(
        QueueService.sameQueue(made, (
          current: 3,
          turnedOff: 0,
          orderChanges: 0,
          requests: 0,
          playbackOrder: FinampPlaybackOrder.linear,
          items: ['a', 'b', 'c', 'd', 'f', 'e'],
          order: made.order,
        )),
        isFalse,
        reason: 'songs moved',
      );
      expect(
        QueueService.sameQueue(made, (
          current: 3,
          turnedOff: 0,
          orderChanges: 0,
          requests: 0,
          playbackOrder: FinampPlaybackOrder.linear,
          items: ['a', 'b', 'c', 'd', 'e', 'g'],
          order: made.order,
        )),
        isFalse,
        reason: 'replaced by another as long',
      );
      expect(
        QueueService.sameQueue(made, (
          current: 3,
          turnedOff: 0,
          orderChanges: 0,
          requests: 0,
          playbackOrder: FinampPlaybackOrder.linear,
          items: made.items,
          order: [0, 1, 2, 3, 5, 4],
        )),
        isFalse,
        reason: 'put in another order',
      );
    });
  });
}
