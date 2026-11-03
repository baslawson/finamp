import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:finamp/services/server_hub_service.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:logging/logging.dart';

/// A guest's request, as the party's own web page would have made it. Past its [deadline] the guest was already told
/// it failed, so it changes nothing.
typedef PartyGuestRequest = ({
  String method,
  String path,
  Map<String, String> query,
  List<int> body,
  String guest,
  DateTime? deadline,
});

/// How the party answered a guest.
typedef PartyAnswer = ({int status, String body});

/// Why guests can't join from anywhere: no server hub is set up, or it couldn't be reached.
enum PartyRelayProblem { noServer, unreachable }

/// Party mode for guests away from the host's Wi-Fi: the server hub, at the server's public address, hands their
/// requests to this phone and carries its answers back. The party itself (voting, approvals, limits) stays here.
class PartyRelay {
  PartyRelay._(this._hub, this.id, this.url, this._respond);

  static final _logger = Logger("PartyRelay");

  /// How the relay reaches the server hub; tests use their own.
  @visibleForTesting
  static Future<ServerHubService?> Function() connect = ServerHubService.connect;

  final ServerHubService _hub;
  final String id;

  /// The link guests open, at the server's public address.
  final String url;
  final Future<PartyAnswer> Function(PartyGuestRequest request) _respond;
  bool _closed = false;

  /// How long a guest's request may take here before they're told to try again.
  @visibleForTesting
  static Duration answerTime = const Duration(seconds: 6);

  /// Opens the party on the server hub and starts answering its guests, or returns null without a server hub.
  static Future<PartyRelay?> open(Future<PartyAnswer> Function(PartyGuestRequest request) respond) async {
    final hub = await connect();
    if (hub == null) return null;
    final result = await hub.request("POST", "/api/parties", body: <String, Object>{}) as Map<String, dynamic>;
    // The hub knows its public address when it's set (PUBLIC_URL); otherwise the address this phone uses for it.
    final base = (result["publicUrl"] as String?) ?? hub.url;
    final relay = PartyRelay._(
      hub,
      result["id"] as String,
      "$base/hub/party/#${Uri.encodeComponent(result["token"] as String)}",
      respond,
    );
    unawaited(relay._run());
    return relay;
  }

  /// Ends the party on the hub, so guests' links stop working.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _end();
  }

  Future<void> _end() async {
    try {
      await _hub.request("DELETE", "/api/parties/$id", timeout: const Duration(seconds: 5));
    } catch (error) {
      _logger.info("Couldn't end the party on the server hub", error);
    }
  }

  Future<void> _run() async {
    var failures = 0;
    while (!_closed) {
      try {
        final messages =
            await _hub.request("GET", "/api/parties/$id/inbox?wait=25", timeout: const Duration(seconds: 40)) as List;
        failures = 0;
        if (_closed) return;
        // Each is answered as soon as it's ready, and the next guests' requests are fetched meanwhile: one slow
        // search doesn't hold up the rest.
        for (final message in messages.cast<Map<String, dynamic>>()) {
          unawaited(_answerAndSend(message));
        }
      } on ServerHubException catch (error) {
        // The hub restarted, or forgot the party while this phone was away: open it again under the same id, so the
        // links guests have keep working.
        if (error.status == 404 && !_closed) {
          try {
            await _hub.request("POST", "/api/parties", body: {"id": id});
            // Ended meanwhile: don't leave it open there with no one answering.
            if (_closed) await _end();
            continue;
          } catch (_) {}
        }
        await _pause(++failures);
      } catch (error) {
        _logger.info("Party relay interrupted", error);
        await _pause(++failures);
      }
    }
  }

  Future<void> _answerAndSend(Map<String, dynamic> message) async {
    final answer = await _answer(message);
    if (_closed) return;
    try {
      await _hub.request(
        "POST",
        "/api/parties/$id/answers",
        body: {
          "answers": [answer],
        },
      );
    } catch (error) {
      _logger.info("Couldn't send a party guest their answer", error);
    }
  }

  Future<void> _pause(int failures) => Future<void>.delayed(Duration(seconds: min(30, 1 << min(failures, 5))));

  Future<Map<String, Object>> _answer(Map<String, dynamic> message) async {
    // Within the time the hub still waits for it, which the guest may have spent already waiting for this phone.
    final budget = message["budget"];
    var time = answerTime;
    if (budget is num) {
      final left = Duration(milliseconds: (budget * 1000).round()) - const Duration(milliseconds: 500);
      if (left < time) time = left.isNegative ? Duration.zero : left;
    }
    try {
      // The hub stops waiting for an answer after a few seconds anyway.
      final answer = await _respond((
        method: message["method"] as String,
        path: message["path"] as String,
        query: {
          for (final entry in ((message["query"] as Map?) ?? const {}).entries)
            if (entry.key is String && entry.value is String) entry.key as String: entry.value as String,
        },
        body: utf8.encode((message["body"] as String?) ?? ""),
        guest: message["guest"] as String,
        deadline: DateTime.now().add(time),
      )).timeout(time);
      return {"id": message["id"] as Object, "status": answer.status, "body": answer.body};
    } on TimeoutException {
      // Still under way here: an addition may yet go through, so the guest checks before asking again.
      final detail = message["method"] == "POST"
          ? "The host's phone was slow to answer. Check Up next before asking again."
          : "The party is busy. Try again in a moment.";
      return {
        "id": message["id"] as Object,
        "status": 503,
        "body": jsonEncode({"detail": detail}),
      };
    } catch (error) {
      _logger.warning("Couldn't answer a party guest", error);
      return {"id": message["id"] as Object, "status": 500, "body": "{}"};
    }
  }
}
