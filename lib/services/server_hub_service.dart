import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:finamp/services/analyzer_service.dart';
import 'package:finamp/services/finamp_user_helper.dart';
import 'package:finamp/services/radio_preferences.dart';
import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:http/http.dart' as http;

class ServerHubException implements Exception {
  const ServerHubException(this.message, [this.status]);
  final String message;
  final int? status;
  @override
  String toString() => message;
}

/// Captures the account for an operation. An account switch cancels its result.
class ServerHubService {
  ServerHubService._(this.url, this._analyzerToken, this._userToken, this.scope);
  final String url, _analyzerToken, _userToken, scope;

  /// One client for every request, so a sync's few requests share a connection instead of each opening its own.
  @visibleForTesting
  static http.Client client = http.Client();

  /// At most [mostAtOnce] requests to a server are under way, others waiting their turn (within their own time). One
  /// timed out keeps its turn until it has really ended: stuck connecting (in a secure handshake, say) it can't be
  /// stopped, so no more than these connections are ever left open to a server that won't answer. Requests to it then
  /// time out waiting, as they would anyway; those to another server, as after changing the address, go ahead.
  @visibleForTesting
  static const mostAtOnce = 4;
  static final _turns = <String, _Turns>{};

  static Future<ServerHubService?> connect() async {
    final scope = RadioPreferencesStore.scope;
    final user = GetIt.instance.isRegistered<FinampUserHelper>()
        ? GetIt.instance<FinampUserHelper>().currentUser
        : null;
    if (user == null) return null;
    final settings = await AnalyzerService.getSettings();
    if (settings.url == null || RadioPreferencesStore.scope != scope) return null;
    return ServerHubService._(settings.url!, settings.token ?? '', user.accessToken, scope);
  }

  void checkAccount() {
    if (scope != RadioPreferencesStore.scope) throw const ServerHubException('The active account changed.');
  }

  static const _late = 'The server hub did not answer in time.';

  /// Waits (within [timeout]) for a turn to send a request to [origin].
  static Future<_Turns> _turn(String origin, Duration timeout) async {
    final turns = _turns.putIfAbsent(origin, _Turns.new);
    if (turns.underWay < mostAtOnce) {
      turns.underWay++;
      return turns;
    }
    final turn = Completer<void>();
    turns.waiting.add(turn);
    try {
      await turn.future.timeout(timeout);
    } on TimeoutException {
      // Given the turn just as time ran out: passed on, unused.
      if (!turns.waiting.remove(turn)) turns.done();
      throw TimeoutException(_late, timeout);
    }
    return turns;
  }

  Future<dynamic> request(
    String method,
    String path, {
    Object? body,
    String? program,
    String contentType = 'audio/wav',
    Duration timeout = const Duration(seconds: 15),
    bool serverMessages = false,
  }) async {
    checkAccount();
    // Timed out, the request itself is stopped, not only the wait for it: the client's other connections stay.
    final abort = Completer<void>();
    final request = http.AbortableRequest(method, Uri.parse('$url/hub$path'), abortTrigger: abort.future)
      // A redirect's own connection is out of the abort's reach. The hub never redirects (and requests other than
      // GET were never followed), so one means the address is wrong.
      ..followRedirects = false;
    request.headers.addAll({'X-Api-Key': _analyzerToken, 'X-Jellyfin-Token': _userToken});
    if (body is Uint8List) {
      request.headers['Content-Type'] = contentType;
      if (program != null) request.headers['X-Program'] = program;
      request.bodyBytes = body;
    } else if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final waited = Stopwatch()..start();
    final turns = await _turn(request.url.origin, timeout);
    final answer = client.send(request).then(http.Response.fromStream);
    unawaited(answer.then((_) {}, onError: (Object _) {}).whenComplete(turns.done));
    // The wait ends on time whatever the request's doing, even still connecting (which the abort only reaches once
    // connected).
    final http.Response response;
    try {
      response = await answer.timeout(
        timeout - waited.elapsed,
        onTimeout: () {
          abort.complete();
          throw TimeoutException(_late, timeout);
        },
      );
    } on http.RequestAbortedException {
      throw TimeoutException(_late, timeout);
    }
    checkAccount();
    if (response.statusCode >= 300) {
      final detail = serverMessages ? serverMessage(response) : null;
      if (detail != null) throw ServerHubException(detail, response.statusCode);
      throw ServerHubException(switch (response.statusCode) {
        401 => 'Sign in again or check the analyzer token.',
        403 => 'Your Jellyfin administrator manages this feature.',
        404 => 'Update the Finamp server to use the server hub.',
        409 => 'The saved state changed. Refresh and try again.',
        < 400 => 'The server hub sent this elsewhere. Check the analyzer address.',
        _ => 'The server could not complete this request. Try again shortly.',
      }, response.statusCode);
    }
    return jsonDecode(utf8.decode(response.bodyBytes));
  }

  Uri page(String page, String token) => Uri.parse('$url/hub/$page/').replace(fragment: token);

  /// Starts downloading a file from the hub's [path], for a caller that reads it as it comes (or drains it). The path
  /// carries its own ticket, so no account details are sent. Like [request], it waits its turn and keeps it until the
  /// connection has really ended; an answer not started within [timeout], or a body the caller stops reading, stops
  /// the request itself.
  Future<http.StreamedResponse> download(String path, {Duration timeout = const Duration(seconds: 30)}) async {
    checkAccount();
    final abort = Completer<void>();
    void stop() {
      if (!abort.isCompleted) abort.complete();
    }

    final request = http.AbortableRequest('GET', Uri.parse('$url/hub$path'), abortTrigger: abort.future)
      ..followRedirects = false;
    final waited = Stopwatch()..start();
    final turns = await _turn(request.url.origin, timeout);
    var released = false;
    void release() {
      if (released) return;
      released = true;
      turns.done();
    }

    final sent = client.send(request);
    final http.StreamedResponse response;
    try {
      response = await sent.timeout(
        timeout - waited.elapsed,
        onTimeout: () {
          stop();
          throw TimeoutException(_late, timeout);
        },
      );
    } catch (error) {
      // Still connecting, it keeps its turn until it does end; an answer that comes after all is dropped.
      unawaited(sent.then((late) => late.stream.listen(null).cancel(), onError: (Object _) {}).whenComplete(release));
      if (error is http.RequestAbortedException) throw TimeoutException(_late, timeout);
      rethrow;
    }
    late StreamSubscription<List<int>> body;
    final controller = StreamController<List<int>>(sync: true);
    controller
      ..onListen = () {
        body = response.stream.listen(
          controller.add,
          onError: (Object error, StackTrace stack) {
            release();
            controller.addError(error, stack);
          },
          onDone: () {
            release();
            controller.close();
          },
        );
      }
      // The caller writing slower than the connection brings it in holds the connection back.
      ..onPause = (() => body.pause())
      ..onResume = (() => body.resume())
      ..onCancel = () {
        stop();
        release();
        return body.cancel();
      };
    return http.StreamedResponse(
      controller.stream,
      response.statusCode,
      contentLength: response.contentLength,
      request: response.request,
      headers: response.headers,
      reasonPhrase: response.reasonPhrase,
    );
  }

  /// The hub's own explanation of a refusal (its "detail"), for requests whose refusals say what to do. Not a missing
  /// route's "Not Found", which means the server is older than the app.
  @visibleForTesting
  static String? serverMessage(http.Response response) {
    try {
      final detail = (jsonDecode(utf8.decode(response.bodyBytes)) as Map)['detail'];
      if (detail is! String || detail.isEmpty || detail.length > 300 || detail == 'Not Found') return null;
      return detail;
    } catch (_) {
      return null;
    }
  }
}

/// One server's requests under way, and those waiting their turn.
class _Turns {
  int underWay = 0;
  final waiting = Queue<Completer<void>>();

  void done() {
    if (waiting.isNotEmpty) {
      waiting.removeFirst().complete(); // The turn passes straight on.
    } else {
      underWay--;
    }
  }
}
