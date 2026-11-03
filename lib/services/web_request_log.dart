import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

/// Sends a request and adds a line about it to the verbose logs: the address, how it ended, how long it took and how
/// much went each way. Never its headers, which hold API keys, or its contents, which hold prompts and library details.
Future<http.Response> loggedWebRequest(
  Logger logger,
  String method,
  Uri url,
  Future<http.Response> Function() send, {
  int sent = 0,
}) async {
  final clock = Stopwatch()..start();
  void log(String outcome) => logger.fine(
    "$method $url: $outcome after ${clock.elapsedMilliseconds} ms${sent == 0 ? "" : ", sent $sent bytes"}",
  );
  try {
    final response = await send();
    log("${response.statusCode}, received ${response.bodyBytes.length} bytes");
    return response;
  } catch (error) {
    log(error is TimeoutException ? "timed out" : "failed with ${error.runtimeType}");
    rethrow;
  }
}
