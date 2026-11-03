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

  Future<dynamic> request(
    String method,
    String path, {
    Object? body,
    String? program,
    String contentType = 'audio/wav',
    Duration timeout = const Duration(seconds: 15),
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
    const late = 'The server hub did not answer in time.';
    final waited = Stopwatch()..start();
    final turns = _turns.putIfAbsent(request.url.origin, _Turns.new);
    if (turns.underWay < mostAtOnce) {
      turns.underWay++;
    } else {
      final turn = Completer<void>();
      turns.waiting.add(turn);
      try {
        await turn.future.timeout(timeout);
      } on TimeoutException {
        // Given the turn just as time ran out: passed on, unused.
        if (!turns.waiting.remove(turn)) turns.done();
        throw TimeoutException(late, timeout);
      }
    }
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
          throw TimeoutException(late, timeout);
        },
      );
    } on http.RequestAbortedException {
      throw TimeoutException(late, timeout);
    }
    checkAccount();
    if (response.statusCode >= 300) {
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
