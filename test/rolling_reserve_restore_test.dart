import 'dart:convert';
import 'dart:io';

import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/queue_reserve_cache.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:finamp/services/rolling_reserve_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// An empty queue: being replaced (the player already reads the new songs), or stopped.
class _EmptyQueue extends Fake implements QueueService {
  _EmptyQueue({required this.settling});
  @override
  final bool settling;
  @override
  FinampQueueInfo getQueue() => FinampQueueInfo(
    id: 'queue',
    previousTracks: [],
    currentTrack: null,
    nextUp: [],
    queue: [],
    source: QueueItemSource.rawId(
      type: QueueItemSourceType.unknown,
      name: const QueueItemSourceName(type: QueueItemSourceNameType.preTranslated, pretranslatedName: 'Mix'),
      id: 'mix',
    ),
    saveState: settling ? SavedQueueState.loading : SavedQueueState.pendingSave,
    sourceLibrary: BaseItemDto(id: const BaseItemId('library'), type: 'CollectionFolder'),
  );
}

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

void main() {
  const key = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  late Directory directory;
  late PathProviderPlatform oldPaths;
  late QueueReserveCache store;
  late HttpClient client;
  final wasEnabled = RollingReserveService.enabled;
  // The service keeps one reserve for the app's life, so the tests share it.
  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('finamp-reserve-restore-');
    oldPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(directory.path);
    store = await RollingReserveService.cache;
    client = HttpClient();
  });
  tearDown(() async {
    RollingReserveService.enabled = wasEnabled;
    await GetIt.instance.reset();
  });
  tearDownAll(() async {
    client.close(force: true);
    await store.close();
    PathProviderPlatform.instance = oldPaths;
    await directory.delete(recursive: true);
  });

  /// A saved song the player has started reading from the reserve.
  Future<Uri> playing() async {
    await store.root.create(recursive: true);
    await store.file(key).writeAsString('saved song');
    final uri = await store.source(key, Uri.parse('http://127.0.0.1:9/audio'), playbackId: 'restored');
    await (await (await client.getUrl(uri)).close()).drain<void>();
    return uri;
  }

  test('a queue being replaced leaves the song the player reads from the reserve in place', () async {
    GetIt.instance.registerSingleton<QueueService>(_EmptyQueue(settling: true));
    RollingReserveService.enabled = true;
    final uri = await playing();
    await RollingReserveService.fill();
    expect(await store.contains(key), true);
    final response = await (await client.getUrl(uri)).close();
    expect(response.statusCode, 200);
    expect(await utf8.decoder.bind(response).join(), 'saved song');
  });

  test('a stopped queue is cleaned up, as when the reserve is turned off with nothing playing', () async {
    GetIt.instance.registerSingleton<QueueService>(_EmptyQueue(settling: false));
    RollingReserveService.enabled = false;
    final uri = await playing();
    await RollingReserveService.fill();
    expect(await store.hasOwnedFiles, false);
    final response = await (await client.getUrl(uri)).close();
    expect(response.statusCode, 404);
    await response.drain<void>();
  });
}
