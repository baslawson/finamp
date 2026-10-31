import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:finamp/services/music_player_background_task.dart';
import 'package:finamp/services/playback_history_service.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:finamp/services/radio_preferences.dart';
import 'package:finamp/services/server_hub_service.dart';
import 'package:finamp/services/server_sync_merge.dart';
import 'package:finamp/services/sync_upload_cache.dart';
import 'package:flutter/widgets.dart';
import 'package:get_it/get_it.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

class ServerSyncService {
  ServerSyncService({bool startImmediately = true}) {
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      final now = DateTime.now();
      if (pollDue(
        playing: _playing,
        foreground: _foreground,
        lastPoll: _lastPoll,
        unsentUntil: _unsentUntil,
        now: now,
      )) {
        unawaited(sync());
      }
    });
    _playback = GetIt.instance<MusicPlayerBackgroundTask>().playbackState.listen((state) {
      if (state.playing && !_playing) _claim++;
      // Paused: the queue's last position goes up now, before polling slows down.
      final paused = !state.playing && _playing;
      _playing = state.playing;
      if (paused) {
        _pauses++;
        _unsentUntil = DateTime.now().add(const Duration(minutes: 15));
        unawaited(sync());
      }
    });
    _foreground = (WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed) == AppLifecycleState.resumed;
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) => _foreground = state == AppLifecycleState.resumed,
      onResume: () => unawaited(sync()),
    );
    if (startImmediately) unawaited(sync());
  }
  Timer? _timer;
  StreamSubscription<dynamic>? _playback;
  AppLifecycleListener? _lifecycle;
  bool _busy = false, _playing = false, _foreground = true;
  // Asked for while a sync was already under way (a pause, "Resume here"): it runs again once that's done.
  bool _again = false, _againForced = false;
  DateTime? _lastPoll;
  // Paused, until a sync begun since has gone through: retried as soon as failures allow, not 15 minutes later.
  DateTime? _unsentUntil;
  int _pauses = 0;
  final _config = SyncConfigCache();
  @visibleForTesting
  bool get pauseUnsent => _unsentUntil != null;

  /// Every 30 seconds while playing (the queue's position goes up), open on screen, or with a pause not yet sent (for
  /// up to [unsentUntil]); otherwise every 15 minutes, for changes made on other devices.
  @visibleForTesting
  static bool pollDue({
    required bool playing,
    required bool foreground,
    DateTime? lastPoll,
    DateTime? unsentUntil,
    required DateTime now,
  }) =>
      playing ||
      foreground ||
      (unsentUntil != null && now.isBefore(unsentUntil)) ||
      lastPoll == null ||
      now.difference(lastPoll) >= const Duration(minutes: 15) ||
      now.isBefore(lastPoll);
  int _claim = 0, _sentClaim = 0;
  String? _account;
  DateTime _historySince = DateTime.now();
  final _uploads = SyncUploadCache();
  final _retries = SyncRetrySchedule();
  static final _prefs = SharedPreferencesAsync();
  static Future<bool> enabled() async => await _prefs.getBool('hub.sync.${RadioPreferencesStore.scope}') ?? true;
  static Future<void> setEnabled(bool enabled) => _prefs.setBool('hub.sync.${RadioPreferencesStore.scope}', enabled);

  Future<void> claimQueue() async {
    _claim++;
    await sync(force: true);
  }

  Future<void> sync({bool force = false}) async {
    if (_busy) {
      _again = true;
      _againForced |= force;
      return;
    }
    if (FinampSettingsHelper.finampSettings.isOffline) return;
    if (!_retries.ready(RadioPreferencesStore.scope, force: force)) return;
    _busy = true;
    _lastPoll = DateTime.now();
    final pauses = _pauses;
    try {
      if (!await enabled()) return;
      final hub = await ServerHubService.connect();
      if (hub == null) return;
      if (_account != hub.scope) {
        if (_account != null) _historySince = DateTime.now();
        _account = hub.scope;
        _sentClaim = _claim; // Restoring a paused queue is not a transfer.
        _uploads.clear();
        _config.clear();
      }
      final key = 'hub.baseline.${hub.scope}';
      final baselineText = await _prefs.getString(key);
      final baseline = Map<String, dynamic>.from(jsonDecode(baselineText ?? '{}') as Map);
      final localPreferences = await _prefs.getString('radio.preferences.${hub.scope}');
      final local = <String, dynamic>{
        'stations': (await RadioPreferencesStore.stations()).map((s) => s.toJson()).toList(),
        'preferences': localPreferences == null ? null : jsonDecode(localPreferences),
      };
      // Nothing changed here since the last full sync: ask only whether the server's changed either.
      final known = _config.tagFor(hub.scope, jsonEncode(local));
      final remote = Map<String, dynamic>.from(
        await hub.request('GET', known == null ? '/api/sync' : '/api/sync?unless=${Uri.encodeQueryComponent(known)}')
            as Map,
      );
      if (known == null || remote['unchanged'] != true) {
        final changes = serverSyncChanges(local, baseline);
        final result = _hasChanges(changes)
            ? Map<String, dynamic>.from(await hub.request('PATCH', '/api/sync', body: changes) as Map)
            : remote;
        hub.checkAccount();
        // A user may edit controls while the HTTP request is in flight. Rebase
        // those edits on the response, leaving them pending for the next sync.
        final latestPreferences = await _prefs.getString('radio.preferences.${hub.scope}');
        final latest = <String, dynamic>{
          'stations': (await RadioPreferencesStore.stations()).map((s) => s.toJson()).toList(),
          'preferences': latestPreferences == null ? null : jsonDecode(latestPreferences),
        };
        final applied = mergeServerSync(result, serverSyncChanges(latest, local));
        hub.checkAccount();
        if (jsonEncode(applied['stations']) != jsonEncode(latest['stations'])) {
          await _prefs.setString('radio.stations.${hub.scope}', jsonEncode(applied['stations']));
        }
        if (applied['preferences'] != null) {
          final encoded = jsonEncode(applied['preferences']);
          if (encoded != latestPreferences) await _prefs.setString('radio.preferences.${hub.scope}', encoded);
        }
        final next = {'stations': result['stations'], 'preferences': result['preferences']};
        final nextBaseline = jsonEncode(next);
        if (nextBaseline != baselineText) await _prefs.setString(key, nextBaseline);
        // As left now: in step with the server only with no edits of its own still to send, and its preferences taken.
        final leftPreferences = await _prefs.getString('radio.preferences.${hub.scope}');
        final left = <String, dynamic>{
          'stations': (await RadioPreferencesStore.stations()).map((s) => s.toJson()).toList(),
          'preferences': leftPreferences == null ? null : jsonDecode(leftPreferences),
        };
        final tag = result['configTag'];
        final inStep =
            !_hasChanges(serverSyncChanges(left, next)) && (leftPreferences != null || next['preferences'] == null);
        _config.settle(hub.scope, tag is String && inStep ? tag : null, jsonEncode(left));
      }
      String? device = await _prefs.getString('hub.device');
      if (device == null) {
        device = const Uuid().v4();
        await _prefs.setString('hub.device', device);
      }
      final history = _uploads.pendingHistory(
        GetIt.instance<PlaybackHistoryService>().history.reversed
            .where((play) => !play.startTime.isBefore(_historySince))
            .take(200)
            .map(
              (play) => <String, Object>{
                'id': sha256
                    .convert(
                      utf8.encode('$device:${play.item.baseItem.id.raw}:${play.startTime.millisecondsSinceEpoch}'),
                    )
                    .toString(),
                'song': play.item.baseItem.id.raw,
                'startedMs': play.startTime.millisecondsSinceEpoch,
                'playedMs': (play.playDuration?.inMilliseconds ?? 0).clamp(0, 86400000),
              },
            )
            .toList(),
      );
      if (history.isNotEmpty) {
        await hub.request('POST', '/api/sync/history', body: {'items': history});
        _uploads.acknowledgeHistory(history);
      }
      final player = GetIt.instance<MusicPlayerBackgroundTask>();
      final queue = GetIt.instance<QueueService>().getQueue();
      final tracks = queue.previousTracks
          .followedBy([if (queue.currentTrack != null) queue.currentTrack!])
          .followedBy(queue.nextUp)
          .followedBy(queue.queue)
          .take(2000)
          .toList(growable: false);
      final index = tracks.indexWhere((track) => track.id == queue.currentTrack?.id);
      if (tracks.isNotEmpty && index >= 0) {
        final claim = _claim;
        final snapshot = <String, Object>{
          'ids': tracks.map((track) => track.baseItem.id.raw).toList(),
          'index': index,
          'positionMs': player.playbackPosition.inMilliseconds.clamp(0, 86400000),
          'playing': !player.paused,
          'device': device,
          'name': 'Finamp queue',
          'claim': claim > _sentClaim,
        };
        if (!_uploads.shouldSendQueue(snapshot)) {
          _succeeded(pauses);
          return;
        }
        try {
          await hub.request('PUT', '/api/sync/queue', body: snapshot);
          _sentClaim = claim;
          _uploads.acknowledgeQueue(snapshot);
        } on ServerHubException catch (error) {
          if (error.status != 409) rethrow;
        }
      }
      _succeeded(pauses);
    } catch (_) {
      _retries.failed();
      // Offline servers and older analyzer versions must never stop playback.
    } finally {
      _busy = false;
      if (_again) {
        final forced = _againForced;
        _again = _againForced = false;
        unawaited(sync(force: forced));
      }
    }
  }

  void _succeeded(int pauses) {
    _retries.succeeded();
    if (pauses == _pauses) _unsentUntil = null;
  }

  static bool _hasChanges(Map<String, dynamic> changes) =>
      (changes['upsertStations'] as List).isNotEmpty ||
      (changes['deleteStations'] as List).isNotEmpty ||
      changes.containsKey('preferences');

  Future<void> dispose() async {
    _timer?.cancel();
    _lifecycle?.dispose();
    await _playback?.cancel();
  }
}
