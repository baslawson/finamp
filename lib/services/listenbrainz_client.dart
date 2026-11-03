import 'dart:async';

import 'package:http/http.dart' as http;

/// The contact header and request spacing apply to discovery, scrobbling and
/// history alike. Tokens never appear in URLs or diagnostic messages.
class ListenBrainzClient {
  ListenBrainzClient({this.minimumInterval = const Duration(seconds: 1)});
  static final shared = ListenBrainzClient();
  static const userAgent = 'FinampPlus/1 (https://github.com/baslawson/finamp)';
  final Duration minimumInterval;
  DateTime _next = DateTime.fromMillisecondsSinceEpoch(0);
  Future<void>? _pending;

  Future<http.Response> get(Uri uri, {String? token}) => _request(uri, token: token);
  Future<http.Response> post(Uri uri, {required String token, required String body}) =>
      _request(uri, token: token, body: body);

  Future<http.Response> _request(Uri uri, {String? token, String? body}) {
    if (uri.scheme != 'https' || uri.host != 'api.listenbrainz.org') {
      throw ArgumentError.value(uri, 'uri', 'Expected the ListenBrainz HTTPS API');
    }
    final response = (_pending ?? Future<void>.value()).then((_) async {
      final wait = _next.difference(DateTime.now());
      if (wait > const Duration(seconds: 15)) throw http.ClientException('ListenBrainz is temporarily rate limited.');
      if (wait > Duration.zero) await Future<void>.delayed(wait);
      _next = DateTime.now().add(minimumInterval);
      final headers = <String, String>{
        'User-Agent': userAgent,
        if (token != null) 'Authorization': 'Token ${token.trim()}',
        if (body != null) 'Content-Type': 'application/json',
      };
      final result =
          await (body == null ? http.get(uri, headers: headers) : http.post(uri, headers: headers, body: body)).timeout(
            const Duration(seconds: 20),
          );
      if (result.statusCode == 429 || result.headers['x-ratelimit-remaining'] == '0') {
        final reset = int.tryParse(result.headers['x-ratelimit-reset-in'] ?? '') ?? 1;
        _next = DateTime.now().add(Duration(seconds: reset.clamp(1, 60)));
      }
      return result;
    });
    late final Future<void> done;
    done = response.then<void>((_) {}, onError: (Object _, StackTrace _) {}).whenComplete(() {
      if (identical(_pending, done)) _pending = null;
    });
    _pending = done;
    return response;
  }
}
