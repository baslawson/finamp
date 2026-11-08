import 'dart:async';
import 'dart:collection';

import 'package:chopper/chopper.dart' as chopper;
import 'package:logging/logging.dart';

/// Thins out a burst of one kind of successful request, like a resync loading hundreds of playlists one by one, so it
/// doesn't push the rest of the history out of the logs. The first [keepFirst] are logged as usual; the others are
/// counted, and [report] gets one line about them once [quietAfter] passes without another.
class RequestBurst {
  RequestBurst({required this.report, this.keepFirst = 3, this.quietAfter = const Duration(seconds: 10)});

  final void Function(String summary) report;
  final int keepFirst;
  final Duration quietAfter;

  int _seen = 0;
  int _slowestMs = 0;
  Timer? _quiet;

  /// Notes a successful request that took [elapsedMs], and returns whether to leave it out of the logs.
  bool leaveOut(int elapsedMs) {
    _seen++;
    _quiet?.cancel();
    _quiet = Timer(quietAfter, _finish);
    if (_seen <= keepFirst) return false;
    if (elapsedMs > _slowestMs) _slowestMs = elapsedMs;
    return true;
  }

  void _finish() {
    final leftOut = _seen - keepFirst;
    if (leftOut > 0) report("...and $leftOut more playlists loaded, the slowest in $_slowestMs ms");
    _seen = 0;
    _slowestMs = 0;
    _quiet = null;
  }
}

/// A logger that aggregates the request and response logs from Chopper.
/// Once a request (or response) is completed,
/// the whole request log is flushed to the delegated chopperLogger.
///
/// All other operations are delegated by default.
class ChopperAggregateLogger implements Logger {
  final Logger _delegate = chopper.chopperLogger;

  final Map<chopper.Request, StringBuffer> _requests = HashMap();

  final Map<chopper.Response<dynamic>, StringBuffer> _responses = HashMap();

  @override
  String get name => _delegate.name;

  @override
  String get fullName => _delegate.fullName;

  @override
  Logger? get parent => _delegate.parent;

  @override
  Level get level => _delegate.level;

  @override
  set level(Level? value) {
    _delegate.level = value;
  }

  @override
  Map<String, Logger> get children => _delegate.children;

  @override
  void log(Level logLevel, Object? message, [Object? error, StackTrace? stackTrace, Zone? zone]) {
    if (message is chopper.ChopperLogRecord) {
      if (message.request != null) {
        _requests[message.request]?.writeln(message.message);
        return;
      } else if (message.response != null) {
        _responses[message.response]?.writeln(message.message);
        return;
      }
    }
    _delegate.log(logLevel, message, error, stackTrace, zone);
  }

  void onStartRequest(chopper.Request request) {
    _requests[request] = StringBuffer();
  }

  void onEndRequest(chopper.Request request, {bool leaveOut = false}) {
    final log = _requests.remove(request);
    if (!leaveOut) info(log?.toString().trim());
  }

  void onStartResponse(chopper.Response<dynamic> response) {
    _responses[response] = StringBuffer();
  }

  void onEndResponse(chopper.Response<dynamic> response, {bool leaveOut = false}) {
    final log = _responses.remove(response);
    if (!leaveOut) info(log?.toString().trim());
  }

  @override
  Stream<Level?> get onLevelChanged => _delegate.onLevelChanged;

  @override
  Stream<LogRecord> get onRecord => _delegate.onRecord;

  @override
  void clearListeners() {
    _delegate.clearListeners();
  }

  @override
  bool isLoggable(Level value) {
    return _delegate.isLoggable(value);
  }

  @override
  void finest(Object? message, [Object? error, StackTrace? stackTrace]) =>
      log(Level.FINEST, message, error, stackTrace);

  @override
  void finer(Object? message, [Object? error, StackTrace? stackTrace]) => log(Level.FINER, message, error, stackTrace);

  @override
  void fine(Object? message, [Object? error, StackTrace? stackTrace]) => log(Level.FINE, message, error, stackTrace);

  @override
  void config(Object? message, [Object? error, StackTrace? stackTrace]) =>
      log(Level.CONFIG, message, error, stackTrace);

  @override
  void info(Object? message, [Object? error, StackTrace? stackTrace]) => log(Level.INFO, message, error, stackTrace);

  @override
  void warning(Object? message, [Object? error, StackTrace? stackTrace]) =>
      log(Level.WARNING, message, error, stackTrace);

  @override
  void severe(Object? message, [Object? error, StackTrace? stackTrace]) =>
      log(Level.SEVERE, message, error, stackTrace);

  @override
  void shout(Object? message, [Object? error, StackTrace? stackTrace]) => log(Level.SHOUT, message, error, stackTrace);
}
