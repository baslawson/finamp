import 'package:finamp/services/playback_navigation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('navigation invalidates voice synchronously before a transport command can finish', () async {
    final navigation = PlaybackNavigation.shared;
    PlaybackNavigationCommand? observed;
    final subscription = navigation.commands.listen((command) => observed = command);
    final command = navigation.begin(PlaybackNavigationKind.seekBackward, queueId: 'queue');
    expect(observed, same(command));
    expect(command.pending, isTrue);
    expect(command.kind, PlaybackNavigationKind.seekBackward);
    command.complete(targetItemId: 'current');
    expect(command.pending, isFalse);
    expect(command.targetItemId, 'current');
    await subscription.cancel();
  });

  test('rapid navigation retains the newest command when an older seek completes late', () {
    final navigation = PlaybackNavigation.shared;
    final old = navigation.begin(PlaybackNavigationKind.next, queueId: 'queue');
    final latest = navigation.begin(PlaybackNavigationKind.previous, queueId: 'queue');
    old.complete(targetItemId: 'outdated');
    expect(navigation.last, same(latest));
    expect(latest.pending, isTrue);
    latest.complete(targetItemId: 'chosen');
    old.complete(targetItemId: 'another-outdated-result');
    expect(latest.targetItemId, 'chosen');
    expect(old.targetItemId, 'outdated');
    expect(latest.revision, greaterThan(old.revision));
  });
}
