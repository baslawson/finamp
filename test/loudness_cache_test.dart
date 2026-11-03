import 'dart:async';
import 'dart:convert';

import 'package:audio_service/audio_service.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/loudness_cache.dart';
import 'package:finamp/services/music_player_background_task.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const measured = <String, dynamic>{
    'version': 1,
    'lufs': -20,
    'truePeak': -6,
    'albumLufs': -17,
    'albumTruePeak': -2,
    'revision': 'source-a',
    'albumRevision': 'album-a',
  };

  test('upcoming songs are fetched before the bulk queue in bounded batches', () async {
    final calls = <List<String>>[];
    final first = Completer<Map<String, Map<String, dynamic>>>();
    final cache = LoudnessCache(
      read: () async => null,
      readDownloads: () async => null,
      write: (_) async {},
      isConfigured: () async => true,
      fetch: (ids) {
        calls.add(ids);
        return calls.length == 1 ? first.future : Future.value({});
      },
    );
    final task = cache.fetchAhead('s', List.generate(140, (i) => '$i'));
    await Future<void>.delayed(Duration.zero);
    expect(calls, [List.generate(6, (i) => '$i')]);
    first.complete({});
    await task;
    expect(calls.map((ids) => ids.length), [6, 64, 64, 6]);
    expect(calls.expand((ids) => ids), List.generate(140, (i) => '$i'));
  });

  test('download retains its own revision through reconnect, replacement and restart', () async {
    String? online, downloads;
    var result = measured;
    final cache = LoudnessCache(
      read: () async => online,
      write: (value) async => online = value,
      readDownloads: () async => downloads,
      writeDownloads: (value) async => downloads = value,
      isConfigured: () async => true,
      fetch: (_) async => {'id': result},
    );
    await cache.pinDownload('s', 'id');
    expect((jsonDecode(downloads!) as Map)['s/id']['revision'], 'source-a');
    result = {...measured, 'lufs': -8, 'revision': 'replacement'};
    cache.invalidateRequests();
    await cache.fetch('s', ['id']);
    expect(cache.get('s', 'id')!.lufs, -8);
    expect(cache.get('s', 'id', downloaded: true)!.lufs, -20);
    final restarted = LoudnessCache(
      read: () async => online,
      readDownloads: () async => downloads,
      isConfigured: () async => false,
      fetch: (_) => throw StateError('offline'),
    );
    await restarted.fetch('s', ['id'], offline: true);
    expect(restarted.get('s', 'id', downloaded: true)!.lufs, -20);
    expect(restarted.get('other', 'id', downloaded: true), isNull);
  });

  test('invalidation cancels remaining background batches and a stale download pin', () async {
    final response = Completer<Map<String, Map<String, dynamic>>>();
    var calls = 0, writes = 0;
    final cache = LoudnessCache(
      read: () async => null,
      write: (_) async {},
      readDownloads: () async => null,
      writeDownloads: (_) async {
        writes++;
      },
      isConfigured: () async => true,
      fetch: (_) {
        calls++;
        return response.future;
      },
    );
    final bulk = cache.fetchAhead('s', List.generate(100, (i) => '$i'));
    final pin = cache.pinDownload('s', '0');
    await Future<void>.delayed(Duration.zero);
    cache.invalidateRequests();
    response.complete({'0': measured});
    await Future.wait([bulk, pin]);
    expect(calls, 1);
    expect(writes, 0);
  });

  test('pending download analysis fills once, and deletion cancels an in-flight pin', () async {
    var ready = false;
    final cache = LoudnessCache(
      read: () async => null,
      write: (_) async {},
      readDownloads: () async => null,
      writeDownloads: (_) async {},
      isConfigured: () async => true,
      fetch: (_) async => ready ? {'id': measured} : {},
    );
    await cache.pinDownload('s', 'id');
    expect(cache.get('s', 'id', downloaded: true), isNull);
    ready = true;
    cache.invalidateRequests();
    await cache.fetch('s', ['id']);
    expect(cache.get('s', 'id', downloaded: true)!.lufs, -20);

    final pending = Completer<Map<String, Map<String, dynamic>>>();
    String? saved;
    final other = LoudnessCache(
      read: () async => null,
      write: (_) async {},
      readDownloads: () async => null,
      writeDownloads: (value) async => saved = value,
      isConfigured: () async => true,
      fetch: (_) => pending.future,
    );
    final pin = other.pinDownload('s', 'id');
    await Future<void>.delayed(Duration.zero);
    await other.unpinDownload('s', 'id');
    pending.complete({'id': measured});
    await pin;
    expect(jsonDecode(saved!), isEmpty);
  });

  test('persisted measurements survive restart and offline playback without crossing servers', () async {
    String? saved;
    final cache = LoudnessCache(
      read: () async => saved,
      write: (json) async {
        saved = json;
      },
      isConfigured: () async => true,
      fetch: (ids) async => {'abc123': measured},
    );
    await cache.fetch('server-a', ['abc-123']);
    expect(cache.get('server-a', 'abc123')?.lufs, -20);
    final restarted = LoudnessCache(
      read: () async => saved,
      isConfigured: () async => true,
      fetch: (_) => throw StateError('Offline request must never run'),
    );
    await restarted.fetch('server-a', ['abc123'], offline: true);
    expect(restarted.get('server-a', 'abc123')?.albumLufs, -17);
    expect(restarted.get('server-b', 'abc123'), isNull);
  });

  test('network failure keeps cached gain; a successful missing result invalidates it', () async {
    final saved = jsonEncode({'s/id': measured});
    final unreachable = LoudnessCache(
      read: () async => saved,
      isConfigured: () async => true,
      fetch: (_) => throw StateError('network unavailable'),
    );
    await unreachable.fetch('s', ['id']);
    expect(unreachable.get('s', 'id')?.lufs, -20);
    final deleted = LoudnessCache(
      read: () async => saved,
      write: (_) async {},
      isConfigured: () async => true,
      fetch: (_) async => {},
    );
    await deleted.fetch('s', ['id']);
    expect(deleted.get('s', 'id'), isNull);
  });

  test('crossfade preparation waits for an existing in-flight measurement request', () async {
    final response = Completer<Map<String, Map<String, dynamic>>>();
    int calls = 0;
    final cache = LoudnessCache(
      read: () async => null,
      write: (_) async {},
      isConfigured: () async => true,
      fetch: (_) {
        calls++;
        return response.future;
      },
    );
    final first = cache.fetch('s', ['id']);
    await Future<void>.delayed(Duration.zero);
    bool ready = false;
    final next = cache.fetch('s', ['id']).then((_) {
      ready = true;
    });
    await Future<void>.delayed(Duration.zero);
    expect(ready, isFalse);
    response.complete({'id': measured});
    await Future.wait([first, next]);
    expect(calls, 1);
    expect(cache.get('s', 'id')?.truePeak, -6);
  });

  test('malformed local cache and unmeasured silence never break playback', () async {
    final cache = LoudnessCache(
      read: () async => 'broken json',
      write: (_) async {},
      isConfigured: () async => true,
      fetch: (_) async => {
        'id': {'version': 1, 'lufs': null, 'truePeak': null},
      },
    );
    await cache.fetch('s', ['id']);
    expect(cache.get('s', 'id'), isNull);
  });

  test('analyzer changes during configuration lookup cannot start a stale server request', () async {
    final configured = Completer<bool>();
    var calls = 0;
    final cache = LoudnessCache(
      read: () async => null,
      readDownloads: () async => null,
      isConfigured: () => configured.future,
      fetch: (_) async {
        calls++;
        return {};
      },
    );
    final pending = cache.fetch('old-server', ['id']);
    await Future<void>.delayed(Duration.zero);
    cache.invalidateRequests();
    configured.complete(true);
    await pending;
    expect(calls, 0);
  });

  test('an old request cannot overwrite measurements after analyzer settings change', () async {
    final old = Completer<Map<String, Map<String, dynamic>>>();
    var first = true;
    final cache = LoudnessCache(
      read: () async => null,
      write: (_) async {},
      isConfigured: () async => true,
      fetch: (_) {
        if (first) {
          first = false;
          return old.future;
        }
        return Future.value({
          'id': {...measured, 'lufs': -12},
        });
      },
    );
    final pending = cache.fetch('s', ['id']);
    await Future<void>.delayed(Duration.zero);
    cache.invalidateRequests();
    await cache.fetch('s', ['id']);
    old.complete({'id': measured});
    await pending;
    expect(cache.get('s', 'id')?.lufs, -12);
  });

  test('analyzer lookup uses the Jellyfin id, not AudioService queue or browsing ids', () {
    for (final id in ['random-queue-uuid', 'Audio/album/track']) {
      final track = MediaItem(
        id: id,
        title: 'Track',
        extras: {'itemJson': BaseItemDto(id: const BaseItemId('jellyfin-id')).toJson()},
      );
      expect(loudnessTrackId(track), 'jellyfin-id');
    }
  });
}
