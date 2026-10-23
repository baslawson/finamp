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
import 'package:get_it/get_it.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

class ServerSyncService {
  ServerSyncService({bool startImmediately = true}) {
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => unawaited(sync()));
    _playback = GetIt.instance<MusicPlayerBackgroundTask>().playbackState.listen((state) {
      if (state.playing && !_playing) _claim++;
      _playing = state.playing;
    });
    if (startImmediately) unawaited(sync());
  }
  Timer? _timer;
  StreamSubscription<dynamic>? _playback;
  bool _busy = false, _playing = false;
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
    if (_busy || FinampSettingsHelper.finampSettings.isOffline) return;
    if (!_retries.ready(RadioPreferencesStore.scope, force: force)) return;
    _busy = true;
    try {
      if (!await enabled()) return;
      final hub = await ServerHubService.connect();
      if (hub == null) return;
      if (_account != hub.scope) {
        if (_account != null) _historySince = DateTime.now();
        _account = hub.scope;
        _sentClaim = _claim; // Restoring a paused queue is not a transfer.
        _uploads.clear();
      }
      final key = 'hub.baseline.${hub.scope}';
      final baselineText = await _prefs.getString(key);
      final baseline = Map<String, dynamic>.from(jsonDecode(baselineText ?? '{}') as Map);
      final localPreferences = await _prefs.getString('radio.preferences.${hub.scope}');
      final local = <String, dynamic>{
        'stations': (await RadioPreferencesStore.stations()).map((s) => s.toJson()).toList(),
        'preferences': localPreferences == null ? null : jsonDecode(localPreferences),
      };
      final remote = Map<String, dynamic>.from(await hub.request('GET', '/api/sync') as Map);
      final changes = serverSyncChanges(local, baseline);
      final changed =
          (changes['upsertStations'] as List).isNotEmpty ||
          (changes['deleteStations'] as List).isNotEmpty ||
          changes.containsKey('preferences');
      final result = changed
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
      final nextBaseline = jsonEncode({'stations': result['stations'], 'preferences': result['preferences']});
      if (nextBaseline != baselineText) await _prefs.setString(key, nextBaseline);
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
          _retries.succeeded();
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
      _retries.succeeded();
    } catch (_) {
      _retries.failed();
      // Offline servers and older analyzer versions must never stop playback.
    } finally {
      _busy = false;
    }
  }

  Future<void> dispose() async {
    _timer?.cancel();
    await _playback?.cancel();
  }
}
