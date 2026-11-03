import 'dart:async';
import 'dart:io';

import 'package:finamp/services/cover_cache.dart';
import 'package:finamp/services/network_status.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:web_socket_channel/web_socket_channel.dart' show WebSocketChannelException;

void main() {
  setUp(() {
    NetworkStatus.hasNetwork = () async => true;
    NetworkStatus.changes = () => const Stream.empty();
    Logger.root.level = Level.ALL;
  });

  group("what counts as a lost connection", () {
    test("the failures seen in the phone's logs do", () {
      for (final error in [
        const SocketException("Failed host lookup: 'server'"),
        http.ClientException("Software caused connection abort"),
        http.ClientException("Connection closed while receiving data"),
        const HttpException("Connection closed before full header was received"),
        TimeoutException("too slow"),
        const WebSocketException("Connection closed"),
      ]) {
        expect(NetworkStatus.isNetworkFailure(error), isTrue, reason: "$error");
      }
    });

    test("problems that stay until someone fixes them don't", () {
      for (final error in [
        const HandshakeException("Certificate expired"),
        const FormatException("Not JSON"),
        StateError("Bad state"),
        "A saved queue is currently loading",
        null,
      ]) {
        expect(NetworkStatus.isNetworkFailure(error), isFalse, reason: "$error");
      }
    });

    test("a live connection failing is judged by what's inside", () {
      expect(NetworkStatus.isNetworkFailure(WebSocketChannelException.from(const SocketException("Gone"))), isTrue);
      expect(NetworkStatus.isNetworkFailure(WebSocketChannelException("Closed")), isTrue);
      expect(
        NetworkStatus.isNetworkFailure(WebSocketChannelException.from(const HandshakeException("Certificate expired"))),
        isFalse,
      );
    });

    test("covers still count a certificate problem as the connection's", () {
      expect(CoverCache.isNetworkFailure(const HandshakeException("Certificate expired")), isTrue);
      expect(CoverCache.isNetworkFailure(const SocketException("Gone")), isTrue);
      expect(CoverCache.isNetworkFailure(const FileSystemException("Disk full")), isFalse);
    });
  });

  group("logging a failure", () {
    Future<List<Level>> levelsFor(Object error) async {
      final logger = Logger.detached("Test")..level = Level.ALL;
      final levels = <Level>[];
      final listening = logger.onRecord.listen((record) => levels.add(record.level));
      logger.failure("It failed", error);
      await pumpEventQueue();
      await listening.cancel();
      return levels;
    }

    test("a lost connection is a warning", () async {
      expect(await levelsFor(const SocketException("Gone")), [Level.WARNING]);
    });

    test("anything else stays an error", () async {
      expect(await levelsFor(StateError("Broken")), [Level.SEVERE]);
    });
  });

  group("trying again while offline", () {
    test("keeps trying until the connection is back", () async {
      var attempts = 0;
      final result = await NetworkStatus.retryWhileOffline(() async {
        if (++attempts < 3) throw const SocketException("Gone");
        return "loaded";
      }, firstPause: Duration.zero);
      expect(result, "loaded");
      expect(attempts, 3);
    });

    test("tries once more even though the phone reports a network", () async {
      // Android can report Wi-Fi while keeping the app off it.
      NetworkStatus.hasNetwork = () async => true;
      var attempts = 0;
      await NetworkStatus.retryWhileOffline(() async {
        if (++attempts == 1) throw const SocketException("Gone");
      }, firstPause: Duration.zero);
      expect(attempts, 2);
    });

    test("waits for a network when the phone has none", () async {
      var online = false;
      NetworkStatus.hasNetwork = () async => online;
      final changes = StreamController<bool>.broadcast(sync: true);
      addTearDown(changes.close);
      NetworkStatus.changes = () => changes.stream;
      var attempts = 0;
      final done = NetworkStatus.retryWhileOffline(() async {
        if (++attempts == 1) throw const SocketException("Gone");
      }, firstPause: Duration.zero);
      await pumpEventQueue();
      expect(attempts, 1, reason: "no point trying until a network is back");
      online = true;
      changes.add(true);
      await done;
      expect(attempts, 2);
    });

    test("doesn't retry other failures", () async {
      var attempts = 0;
      await expectLater(
        NetworkStatus.retryWhileOffline(() async {
          attempts++;
          throw StateError("Broken");
        }, firstPause: Duration.zero),
        throwsStateError,
      );
      expect(attempts, 1);
    });

    test("gives up with the last failure when patience runs out", () async {
      var attempts = 0;
      await expectLater(
        NetworkStatus.retryWhileOffline(() async {
          attempts++;
          throw const SocketException("Gone");
        }, patience: Duration.zero),
        throwsA(isA<SocketException>()),
      );
      expect(attempts, 1);
    });

    test("a wait never runs past the patience, and no try starts after it", () async {
      var attempts = 0;
      await expectLater(
        NetworkStatus.retryWhileOffline(
          () async {
            attempts++;
            throw const SocketException("Gone");
          },
          patience: const Duration(milliseconds: 30),
          firstPause: const Duration(hours: 1),
        ),
        throwsA(isA<SocketException>()),
      );
      expect(attempts, 1);
    });

    test("a wait cut short by the patience is the last one, even if its timer fires early", () async {
      final realPause = NetworkStatus.pauseFor;
      addTearDown(() => NetworkStatus.pauseFor = realPause);
      // Timers round down to whole milliseconds, so one can end just before the patience is up. Here all of them do.
      NetworkStatus.pauseFor = (_) async {};
      var attempts = 0;
      await expectLater(
        NetworkStatus.retryWhileOffline(
          () async {
            if (++attempts > 5) throw StateError("Kept trying");
            throw const SocketException("Gone");
          },
          patience: const Duration(minutes: 1),
          firstPause: const Duration(hours: 1),
        ),
        throwsA(isA<SocketException>()),
      );
      expect(attempts, 1);
    });

    test("waiting for a network counts towards the patience", () async {
      NetworkStatus.hasNetwork = () async => false;
      var attempts = 0;
      await expectLater(
        NetworkStatus.retryWhileOffline(
          () async {
            attempts++;
            throw const SocketException("Gone");
          },
          patience: const Duration(milliseconds: 30),
          firstPause: Duration.zero,
        ),
        throwsA(isA<SocketException>()),
      );
      expect(attempts, 1);
    });

    test("a stop during the last wait for a network isn't reported as a lost connection", () async {
      var stopping = false;
      // The check itself outlasts the patience, so the deadline has certainly passed when the wait ends.
      NetworkStatus.hasNetwork = () async {
        stopping = true;
        await Future<void>.delayed(const Duration(milliseconds: 60));
        return false;
      };
      final result = await NetworkStatus.retryWhileOffline<String>(
        () async => throw const SocketException("Gone"),
        patience: const Duration(milliseconds: 30),
        firstPause: Duration.zero,
        stop: () => stopping,
      );
      expect(result, isNull);
    });

    test("a stop while a later try is running discards what it got", () async {
      var attempts = 0;
      var stopping = false;
      final result = await NetworkStatus.retryWhileOffline<String>(
        () async {
          if (++attempts == 1) throw const SocketException("Gone");
          stopping = true;
          return "loaded";
        },
        firstPause: Duration.zero,
        stop: () => stopping,
      );
      expect(result, isNull);
      expect(attempts, 2);
    });

    test("a stop while the first try is running discards what it got too", () async {
      var stopping = false;
      final result = await NetworkStatus.retryWhileOffline<String>(() async {
        stopping = true;
        return "loaded";
      }, stop: () => stopping);
      expect(result, isNull);
    });

    test("without a stop, the first try's answer is the answer", () async {
      final result = await NetworkStatus.retryWhileOffline<String>(() async => "loaded", stop: () => false);
      expect(result, "loaded");
    });

    test("stops without an answer when told to", () async {
      var attempts = 0;
      final result = await NetworkStatus.retryWhileOffline<String>(
        () async {
          attempts++;
          throw const SocketException("Gone");
        },
        firstPause: Duration.zero,
        stop: () => attempts == 2,
      );
      expect(result, isNull);
      expect(attempts, 2);
    });

    test("a stop during the wait means no further try", () async {
      var attempts = 0;
      var stopping = false;
      final result = NetworkStatus.retryWhileOffline<String>(
        () async {
          attempts++;
          throw const SocketException("Gone");
        },
        firstPause: const Duration(milliseconds: 500),
        stop: () => stopping,
      );
      await pumpEventQueue();
      stopping = true;
      expect(await result, isNull);
      expect(attempts, 1);
    });
  });
}
