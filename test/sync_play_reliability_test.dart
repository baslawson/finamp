import 'package:finamp/services/sync_play_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a malformed SyncPlay message does not block later group updates', () async {
    addTearDown(() => SyncPlayService.group.add(null));
    for (final data in [null, 'invalid', <dynamic>[]]) {
      await SyncPlayService.handleMessage({'MessageType': 'SyncPlayGroupUpdate', 'Data': data});
    }
    await SyncPlayService.handleMessage({
      'MessageType': 'SyncPlayGroupUpdate',
      'Data': {
        'Type': 'GroupJoined',
        'Data': {
          'GroupId': 'group',
          'GroupName': 'Together',
          'Participants': ['Listener'],
          'State': 'Idle',
        },
      },
    });
    expect(SyncPlayService.group.value?.id, 'group');
    expect(SyncPlayService.group.value?.participants, ['Listener']);
    await SyncPlayService.handleMessage({
      'MessageType': 'SyncPlayGroupUpdate',
      'Data': {'Type': 'NotInGroup'},
    });
    expect(SyncPlayService.group.value, isNull);
  });
}
