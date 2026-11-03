import 'dart:async';
import 'dart:convert';

import 'package:collection/collection.dart';

import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/finamp_user_helper.dart';
import 'package:finamp/services/jellyfin_api_helper.dart';
import 'package:finamp/services/music_player_background_task.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:get_it/get_it.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:rxdart/rxdart.dart';

/// A SyncPlay group on the server.
typedef SyncPlayGroup = ({String id, String name, List<String> participants, String state});

/// Listen together with other Jellyfin clients using SyncPlay.
///
/// Group changes and playback commands arrive over the PlayOn websocket, which forwards them to [handleMessage].
/// Playback commands carry a server timestamp, so every client starts and pauses at the same moment.
class SyncPlayService {
  SyncPlayService._();

  static final _logger = Logger("SyncPlayService");

  /// The group this device is in, or null.
  static final group = BehaviorSubject<SyncPlayGroup?>.seeded(null);

  /// Short status messages about the group, like people joining.
  static final events = PublishSubject<String>();

  /// Server clock minus device clock.
  static Duration _clockOffset = Duration.zero;

  /// The server's playlist entry ids, in queue order, for next/previous commands.
  static List<String> _playlistItemIds = [];
  static int _playingIndex = 0;
  static bool _groupIsPlaying = false;
  static Timer? _scheduledCommand;

  static MusicPlayerBackgroundTask get _player => GetIt.instance<MusicPlayerBackgroundTask>();

  static Future<dynamic> _request(String method, String path, [Map<String, dynamic>? body]) async {
    final userHelper = GetIt.instance<FinampUserHelper>();
    final uri = Uri.parse("${userHelper.currentUser!.baseURL}$path");
    final headers = {"Authorization": userHelper.authorizationHeader, "Content-Type": "application/json"};
    final response = method == "GET"
        ? await http.get(uri, headers: headers)
        : await http.post(uri, headers: headers, body: jsonEncode(body ?? {}));
    if (response.statusCode >= 300) {
      throw Exception("SyncPlay request $path failed (${response.statusCode})");
    }
    return response.body.isEmpty ? null : jsonDecode(utf8.decode(response.bodyBytes));
  }

  static SyncPlayGroup _parseGroup(Map<String, dynamic> json) => (
    id: json["GroupId"] as String,
    name: json["GroupName"] as String? ?? "",
    participants: (json["Participants"] as List?)?.cast<String>() ?? const [],
    state: json["State"] as String? ?? "Idle",
  );

  /// Groups this user can join.
  static Future<List<SyncPlayGroup>> listGroups() async {
    final groups = await _request("GET", "/SyncPlay/List") as List;
    return [for (final json in groups.cast<Map<String, dynamic>>()) _parseGroup(json)];
  }

  static Future<void> createGroup(String name) async {
    await _syncClock();
    await _request("POST", "/SyncPlay/New", {"GroupName": name});
  }

  static Future<void> joinGroup(String groupId) async {
    await _syncClock();
    await _request("POST", "/SyncPlay/Join", {"GroupId": groupId});
  }

  static Future<void> leaveGroup() async {
    await _request("POST", "/SyncPlay/Leave");
    _leftGroup();
  }

  /// Makes the group play this device's current queue from the current track and position.
  static Future<void> shareCurrentQueue() async {
    final queue = GetIt.instance<QueueService>().getQueue();
    final tracks = [
      ...queue.previousTracks,
      if (queue.currentTrack != null) queue.currentTrack!,
      ...queue.nextUp,
      ...queue.queue,
    ];
    if (tracks.isEmpty) return;
    await _request("POST", "/SyncPlay/SetNewQueue", {
      "PlayingQueue": [for (final track in tracks) track.baseItemId.raw],
      "PlayingItemPosition": queue.previousTracks.length,
      "StartPositionTicks": _player.playbackPosition.inMicroseconds * 10,
    });
  }

  static Future<void> togglePlayback() => _request("POST", _groupIsPlaying ? "/SyncPlay/Pause" : "/SyncPlay/Unpause");

  static Future<void> next() => _request("POST", "/SyncPlay/NextItem", {"PlaylistItemId": _currentPlaylistItemId});

  static Future<void> previous() =>
      _request("POST", "/SyncPlay/PreviousItem", {"PlaylistItemId": _currentPlaylistItemId});

  static String? get _currentPlaylistItemId =>
      _playingIndex < _playlistItemIds.length ? _playlistItemIds[_playingIndex] : null;

  static bool get isPlaying => _groupIsPlaying;

  /// Estimates the server clock offset from a few round trips, keeping the fastest.
  static Future<void> _syncClock() async {
    final baseUrl = GetIt.instance<FinampUserHelper>().currentUser!.baseURL;
    Duration? bestRoundTrip;
    for (var i = 0; i < 3; i++) {
      try {
        final sent = DateTime.now().toUtc();
        final response = await http.get(Uri.parse("$baseUrl/GetUtcTime"));
        final received = DateTime.now().toUtc();
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        final serverReceived = DateTime.parse(json["RequestReceptionTime"] as String);
        final serverSent = DateTime.parse(json["ResponseTransmissionTime"] as String);
        final roundTrip = received.difference(sent) - serverSent.difference(serverReceived);
        if (bestRoundTrip == null || roundTrip < bestRoundTrip) {
          bestRoundTrip = roundTrip;
          _clockOffset = (serverReceived.difference(sent) + serverSent.difference(received)) ~/ 2;
        }
      } catch (e) {
        _logger.warning("Clock sync attempt failed", e);
      }
    }
    _logger.info("SyncPlay clock offset: $_clockOffset");
  }

  static DateTime get _serverNow => DateTime.now().toUtc().add(_clockOffset);

  /// Handles a SyncPlay websocket message forwarded by the PlayOn service.
  /// Messages are handled one at a time, so a command can't overtake the queue load before it.
  static Future<void> handleMessage(Map<String, dynamic> message) => _messages = _messages
      .catchError((Object error, StackTrace stack) {
        _logger.warning('Resuming SyncPlay after a failed message', error, stack);
      })
      .then((_) => _handle(message));

  static Future<void> _messages = Future.value();

  static Future<void> _handle(Map<String, dynamic> message) async {
    final data = message["Data"];
    if (data is! Map<String, dynamic>) {
      _logger.warning('Ignoring a malformed SyncPlay message');
      return;
    }
    try {
      switch (message["MessageType"]) {
        case "SyncPlayGroupUpdate":
          await _handleGroupUpdate(data);
        case "SyncPlayCommand":
          await _handleCommand(data);
      }
    } catch (e) {
      _logger.severe("Failed to handle SyncPlay message", e);
      GlobalSnackbar.error(e);
    }
  }

  static Future<void> _handleGroupUpdate(Map<String, dynamic> update) async {
    final payload = update["Data"];
    switch (update["Type"]) {
      case "GroupJoined":
        group.add(_parseGroup(payload as Map<String, dynamic>));
      case "UserJoined":
        events.add("+ $payload");
        await _refreshGroup();
      case "UserLeft":
        events.add("− $payload");
        await _refreshGroup();
      case "GroupLeft":
      case "NotInGroup":
      case "GroupDoesNotExist":
        _leftGroup();
      case "StateUpdate":
        final state = (payload as Map<String, dynamic>)["State"] as String?;
        if (state == "Playing" || state == "Paused") _groupIsPlaying = state == "Playing";
        final current = group.value;
        if (current != null && state != null) {
          group.add((id: current.id, name: current.name, participants: current.participants, state: state));
        }
      case "PlayQueue":
        await _loadPlayQueue(payload as Map<String, dynamic>);
    }
  }

  static Future<void> _refreshGroup() async {
    final current = group.value;
    if (current == null) return;
    final groups = await listGroups();
    final updated = groups.where((other) => other.id == current.id).firstOrNull;
    if (updated != null) group.add(updated);
  }

  static void _leftGroup() {
    _scheduledCommand?.cancel();
    _playlistItemIds = [];
    _groupIsPlaying = false;
    group.add(null);
  }

  static Future<void> _loadPlayQueue(Map<String, dynamic> queue) async {
    final playlist = (queue["Playlist"] as List).cast<Map<String, dynamic>>();
    final ids = [for (final entry in playlist) BaseItemId(entry["ItemId"] as String)];
    final previousIds = _playlistItemIds;
    _playlistItemIds = [for (final entry in playlist) entry["PlaylistItemId"] as String];
    _playingIndex = queue["PlayingItemIndex"] as int? ?? 0;
    _groupIsPlaying = queue["IsPlaying"] as bool? ?? false;
    if (ids.isEmpty) return;
    final position = Duration(microseconds: (queue["StartPositionTicks"] as int? ?? 0) ~/ 10);
    final queueService = GetIt.instance<QueueService>();

    final sameQueue = const ListEquality<String>().equals(previousIds, _playlistItemIds);
    if (sameQueue) {
      // Only the playing item changed (next/previous), so skip within the existing queue.
      final currentIndex = queueService.getQueue().previousTracks.length;
      if (_playingIndex > currentIndex) {
        for (var i = currentIndex; i < _playingIndex; i++) {
          await _player.skipToNext();
        }
      } else {
        for (var i = currentIndex; i > _playingIndex; i--) {
          await _player.skipToPrevious(forceSkip: true);
        }
      }
    } else {
      final items = await GetIt.instance<JellyfinApiHelper>().getItems(itemIds: ids) ?? [];
      final byId = {for (final item in items) item.id: item};
      final ordered = [for (final id in ids) ?byId[id]];
      if (ordered.isEmpty) return;
      await queueService.startPlayback(
        items: ordered,
        source: QueueItemSource.rawId(
          type: QueueItemSourceType.remoteClient,
          name: QueueItemSourceName(
            type: QueueItemSourceNameType.preTranslated,
            pretranslatedName: group.value?.name ?? "SyncPlay",
          ),
          id: "syncPlay",
        ),
        order: FinampPlaybackOrder.linear,
        startingIndex: _playingIndex.clamp(0, ordered.length - 1),
        beginPlaying: false,
      );
    }
    await _player.pause(disableFade: true);
    await _player.seek(position);
    await _reportReady(position);
  }

  static Future<void> _reportReady(Duration position) => _request("POST", "/SyncPlay/Ready", {
    "When": _serverNow.toIso8601String(),
    "PositionTicks": position.inMicroseconds * 10,
    "IsPlaying": _groupIsPlaying,
    "PlaylistItemId": _currentPlaylistItemId,
  });

  static Future<void> _handleCommand(Map<String, dynamic> command) async {
    final when = DateTime.parse(command["When"] as String);
    final position = Duration(microseconds: (command["PositionTicks"] as int? ?? 0) ~/ 10);
    final delay = when.difference(_serverNow);
    _scheduledCommand?.cancel();

    switch (command["Command"]) {
      case "Unpause":
        _groupIsPlaying = true;
        if (delay > Duration.zero) {
          await _player.seek(position, userInitiated: false);
          _scheduledCommand = Timer(delay, () => _player.play(disableFade: true));
        } else {
          // We're late, so jump ahead by however late we are.
          await _player.seek(position - delay, userInitiated: false);
          await _player.play(disableFade: true);
        }
      case "Pause":
        _groupIsPlaying = false;
        _scheduledCommand = Timer(delay.isNegative ? Duration.zero : delay, () async {
          await _player.pause(disableFade: true);
          await _player.seek(position, userInitiated: false);
        });
      case "Seek":
        await _player.pause(disableFade: true);
        await _player.seek(position);
        await _reportReady(position);
      case "Stop":
        _groupIsPlaying = false;
        await _player.stop();
    }
    group.add(group.value);
  }
}
