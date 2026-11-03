import 'dart:async';

import 'package:finamp/services/network_status.dart';
import 'package:finamp/services/playon_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late StreamController<bool> changes;
  var online = false;

  setUp(() {
    // Delivered at once, as a real network change would be: one sent before anyone listens is gone.
    changes = StreamController<bool>.broadcast(sync: true);
    NetworkStatus.changes = () => changes.stream;
    online = false;
    NetworkStatus.hasNetwork = () async => online;
    PlayOnService.networkWait = const Duration(minutes: 5);
  });

  tearDown(() => changes.close());

  test("with a network, reconnecting goes ahead without waiting", () async {
    online = true;
    expect(await PlayOnService.waitForNetwork(), isFalse);
  });

  test("without a network, reconnecting waits until there is one", () async {
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
    online = true;
    changes.add(true);
    expect(await waiting, isTrue);
  });

  test("a network coming back while it is being checked isn't missed", () async {
    NetworkStatus.hasNetwork = () async {
      if (online) return true;
      online = true;
      changes.add(true);
      return false;
    };
    expect(await PlayOnService.waitForNetwork().timeout(const Duration(seconds: 2)), isTrue);
  });

  test("a network Finamp isn't let onto yet doesn't end the wait", () async {
    // Android can report the phone's Wi-Fi while keeping an app in the background off it.
    var done = false;
    unawaited(PlayOnService.waitForNetwork().then((_) => done = true));
    await pumpEventQueue();
    changes.add(true);
    await pumpEventQueue();
    expect(done, isFalse);
    online = true;
    changes.add(true);
    await pumpEventQueue();
    expect(done, isTrue);
  });

  test("reporting no network doesn't stop reconnecting for good", () async {
    // A server on a home network without internet can be reachable while the system says there's no connection.
    PlayOnService.networkWait = const Duration(milliseconds: 50);
    expect(await PlayOnService.waitForNetwork(), isFalse);
  });
}
