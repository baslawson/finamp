import 'dart:async';

import 'package:finamp/services/playon_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late StreamController<bool> changes;

  setUp(() {
    // Delivered at once, as a real network change would be: one sent before anyone listens is gone.
    changes = StreamController<bool>.broadcast(sync: true);
    PlayOnService.networkChanges = () => changes.stream;
    PlayOnService.networkWait = const Duration(minutes: 5);
  });

  tearDown(() => changes.close());

  test("with a network, reconnecting goes ahead without waiting", () async {
    PlayOnService.hasNetwork = () async => true;
    expect(await PlayOnService.waitForNetwork(), isFalse);
  });

  test("without a network, reconnecting waits until there is one", () async {
    PlayOnService.hasNetwork = () async => false;
    var done = false;
    final waiting = PlayOnService.waitForNetwork().then((waited) {
      done = true;
      return waited;
    });
    await pumpEventQueue();
    expect(done, isFalse);
    changes.add(false);
    await pumpEventQueue();
    expect(done, isFalse, reason: "still no network");
    changes.add(true);
    expect(await waiting, isTrue);
  });

  test("a network coming back while it is being checked isn't missed", () async {
    PlayOnService.hasNetwork = () async {
      changes.add(true);
      return false;
    };
    expect(await PlayOnService.waitForNetwork().timeout(const Duration(seconds: 2)), isTrue);
  });

  test("reporting no network doesn't stop reconnecting for good", () async {
    // A server on a home network without internet can be reachable while the system says there's no connection.
    PlayOnService.hasNetwork = () async => false;
    PlayOnService.networkWait = const Duration(milliseconds: 50);
    expect(await PlayOnService.waitForNetwork(), isFalse);
  });
}
