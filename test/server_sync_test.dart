import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/server_health_guard.dart';
import 'package:finamp/services/server_sync_merge.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> station(String id, [String name = 'Station']) => {'id': id, 'name': name};
Map<String, dynamic> state(List<Map<String, dynamic>> stations, [int? discovery]) => {
  'stations': stations,
  'preferences': discovery == null ? null : {'discovery': discovery},
};

void main() {
  test('fresh device imports remote preferences without uploading defaults', () {
    final local = state([]), remote = state([station('remote')], 80);
    final changes = serverSyncChanges(local, {});
    expect(changes, {'upsertStations': <dynamic>[], 'deleteStations': <dynamic>[]});
    expect(mergeServerSync(remote, changes), remote);
  });
  test('first sync preserves stations created on both devices', () {
    final changes = serverSyncChanges(state([station('local')]), {});
    expect((mergeServerSync(state([station('remote')]), changes)['stations'] as List).length, 2);
  });
  test('unchanged local stations follow remote deletion', () {
    final baseline = state([station('one')]);
    final changes = serverSyncChanges(baseline, baseline);
    expect(mergeServerSync(state([]), changes)['stations'], isEmpty);
  });
  test('local deletion is durable across a remote refresh', () {
    final changes = serverSyncChanges(state([]), state([station('one')]));
    expect(changes['deleteStations'], ['one']);
    expect(mergeServerSync(state([station('one'), station('other')]), changes)['stations'], [station('other')]);
  });
  test('local rename wins a conflict and preserves unrelated remote edits', () {
    final changes = serverSyncChanges(state([station('one', 'Local')]), state([station('one')]));
    expect(mergeServerSync(state([station('one', 'Remote'), station('other')]), changes)['stations'], [
      station('one', 'Local'),
      station('other'),
    ]);
  });
  test('unchanged local preferences follow the other phone', () {
    expect(mergeServerSync(state([], 80), serverSyncChanges(state([], 50), state([], 50)))['preferences'], {
      'discovery': 80,
    });
  });
  test('edited local preferences upload independently of station changes', () {
    expect(serverSyncChanges(state([], 20), state([], 50))['preferences'], {'discovery': 20});
  });
  test('edits during the request survive and remain pending next time', () {
    final before = state([station('one')], 50);
    final response = state([station('one'), station('remote')], 80);
    final edited = state([station('one', 'Edited'), station('new')], 20);
    final applied = mergeServerSync(response, serverSyncChanges(edited, before));
    expect((applied['stations'] as List).length, 3);
    final pending = serverSyncChanges(applied, response);
    expect((pending['upsertStations'] as List).map((dynamic value) => (value as Map)['id']), ['one', 'new']);
    expect(pending['preferences'], {'discovery': 20});
  });
  test('successful sync does not echo unchanged stations back', () {
    final baseline = state([station('one'), station('two')], 80);
    expect(serverSyncChanges(baseline, baseline), {'upsertStations': <dynamic>[], 'deleteStations': <dynamic>[]});
  });
  test('health guard filters by normalized ID without reordering remaining songs', () {
    final a = BaseItemDto(id: BaseItemId('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'));
    final b = BaseItemDto(id: BaseItemId('bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'));
    final c = BaseItemDto(id: BaseItemId('cccccccccccccccccccccccccccccccc'));
    expect(ServerHealthGuard.apply([a, b, c], {'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'}), [b, c]);
    expect(ServerHealthGuard.apply([a, b], {}), [a, b]);
    expect(ServerHealthGuard.apply([a], {'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'}), isEmpty);
  });
}
