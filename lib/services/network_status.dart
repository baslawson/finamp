import 'dart:async';
import 'dart:io' show HttpException, SocketException, WebSocketException;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:web_socket_channel/web_socket_channel.dart' show WebSocketChannelException;

enum NetworkWait {
  /// There was a network all along.
  online,

  /// There was none, and one came back.
  cameBack,

  /// There was none, and none came back in time.
  stillOffline,
}

/// Whether the phone has any network. Android cuts it for apps in the background, so a long request can lose it
/// when the user leaves Finamp, and gets it back when they return.
class NetworkStatus {
  NetworkStatus._();

  /// Whether [error] means the connection failed, rather than the app or the server. A certificate problem isn't one:
  /// it stays until someone fixes it.
  static bool isNetworkFailure(Object? error) =>
      error is SocketException ||
      error is http.ClientException ||
      error is HttpException ||
      error is WebSocketException ||
      error is TimeoutException ||
      (error is WebSocketChannelException && (error.inner == null || isNetworkFailure(error.inner)));

  /// Without the connectivity plugin (tests, unsupported platforms) the network counts as there.
  @visibleForTesting
  static Future<bool> Function() hasNetwork = () async {
    try {
      return _connected(await Connectivity().checkConnectivity());
    } catch (_) {
      return true;
    }
  };
  @visibleForTesting
  static Stream<bool> Function() changes = () => Connectivity().onConnectivityChanged.map(_connected);

  static bool _connected(List<ConnectivityResult> results) =>
      results.any((result) => result != ConnectivityResult.none);

  /// How often a wait checks again by itself: Android can give a returning app its network back without any change
  /// being reported, when the phone's own connection never changed.
  @visibleForTesting
  static Duration recheckEvery = const Duration(seconds: 3);

  /// Waits until the phone has a network, or [maximum] at most. [onOffline] is called once there turns out to be none.
  /// A first check slower than [checkTimeout] counts as a network, so it can't hold up whatever comes next.
  static Future<NetworkWait> waitForNetwork(
    Duration maximum, {
    Duration checkTimeout = const Duration(seconds: 5),
    void Function()? onOffline,
  }) async {
    // Listening before checking, so a network coming back during the check isn't missed.
    final online = Completer<void>();
    void check() => hasNetwork().then((connected) {
      if (connected && !online.isCompleted) online.complete();
    }, onError: (Object _) {});

    StreamSubscription<bool>? subscription;
    Timer? recheck;
    try {
      // A reported network is only a reason to check again: Android can report the phone's Wi-Fi while still
      // keeping Finamp off it in the background.
      subscription = changes().listen((connected) {
        if (connected) check();
      }, onError: (Object _) {});
    } catch (_) {}
    try {
      final now = await hasNetwork().timeout(checkTimeout, onTimeout: () => true);
      if (now) return NetworkWait.online;
      onOffline?.call();
      if (maximum <= Duration.zero) return NetworkWait.stillOffline;
      recheck = Timer.periodic(recheckEvery, (_) => check());
      await online.future.timeout(maximum);
      return NetworkWait.cameBack;
    } on TimeoutException {
      return NetworkWait.stillOffline;
    } finally {
      recheck?.cancel();
      await subscription?.cancel();
    }
  }

  /// Runs [attempt], and again while it fails for lack of a connection, for [patience] at most. Android can report a
  /// network while still keeping Finamp off it, so a reported network doesn't end the tries. Waits start at
  /// [firstPause] and double, and no try starts after [patience]. Returns null if [stop] says to give up, also when a
  /// try got through meanwhile; any other failure, or the last one, is thrown.
  static Future<T?> retryWhileOffline<T>(
    Future<T> Function() attempt, {
    Duration patience = const Duration(minutes: 1),
    Duration firstPause = const Duration(seconds: 2),
    bool Function()? stop,
  }) async {
    final elapsed = Stopwatch()..start();
    bool stopped() => stop?.call() ?? false;
    Duration left() => patience - elapsed.elapsed;
    var pause = firstPause;
    while (true) {
      try {
        final result = await attempt();
        return stopped() ? null : result;
      } catch (error) {
        if (!isNetworkFailure(error)) rethrow;
        if (stopped()) return null;
        await waitForNetwork(left());
        if (stopped()) return null;
        if (left() <= Duration.zero) rethrow;
        await Future<void>.delayed(pause < left() ? pause : left());
        pause *= 2;
        if (stopped()) return null;
        if (left() <= Duration.zero) rethrow;
      }
    }
  }
}

extension NetworkAwareLogging on Logger {
  /// Logs a failure as an error, or as a warning when only the connection failed. Errors are what the logs get uploaded
  /// for, and Android cuts the connection of a backgrounded app many times a day.
  void failure(Object? message, Object error, [StackTrace? stackTrace]) {
    if (NetworkStatus.isNetworkFailure(error)) {
      warning(message, error, stackTrace);
    } else {
      severe(message, error, stackTrace);
    }
  }
}
