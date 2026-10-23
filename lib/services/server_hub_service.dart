import 'dart:convert';
import 'dart:typed_data';

import 'package:finamp/services/analyzer_service.dart';
import 'package:finamp/services/finamp_user_helper.dart';
import 'package:finamp/services/radio_preferences.dart';
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
    Duration timeout = const Duration(seconds: 15),
  }) async {
    checkAccount();
    final request = http.Request(method, Uri.parse('$url/hub$path'));
    request.headers.addAll({'X-Api-Key': _analyzerToken, 'X-Jellyfin-Token': _userToken});
    if (body is Uint8List) {
      request.headers['Content-Type'] = 'audio/wav';
      request.headers['X-Program'] = program ?? '';
      request.bodyBytes = body;
    } else if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final client = http.Client();
    try {
      final response = await client.send(request).then(http.Response.fromStream).timeout(timeout);
      checkAccount();
      if (response.statusCode >= 300) {
        throw ServerHubException(switch (response.statusCode) {
          401 => 'Sign in again or check the analyzer token.',
          403 => 'Your Jellyfin administrator manages this feature.',
          404 => 'Update the Finamp server to use the server hub.',
          409 => 'The saved state changed. Refresh and try again.',
          _ => 'The server could not complete this request. Try again shortly.',
        }, response.statusCode);
      }
      return jsonDecode(utf8.decode(response.bodyBytes));
    } finally {
      client.close();
    }
  }

  Uri page(String page, String token) => Uri.parse('$url/hub/$page/').replace(fragment: token);
}
