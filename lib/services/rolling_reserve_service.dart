import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:crypto/crypto.dart';
import 'package:finamp/services/ai_service.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/services/dj_recordings.dart';
import 'package:finamp/services/dj_voice_service.dart';
import 'package:finamp/services/dj_voice_studio.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:finamp/services/finamp_user_helper.dart';
import 'package:finamp/services/music_player_background_task.dart';
import 'package:finamp/services/queue_reserve_cache.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:finamp/services/radio_preferences.dart';
import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

class RollingReserveService {
  static bool enabled = false, includeDj = false, wifiOnly = true;
  static int count = 3;
  static final status = ValueNotifier<(int music, int voices, bool busy)>((0, 0, false));
  static QueueReserveCache? _cache;
  static Future<QueueReserveCache>? _opening;
  static Future<void>? _job;
  static bool _again = false;
  static int _generation = 0;
  static bool _started = false;
  static Future<void>? _initializing;
  static Future<void>? _loadingPreferences;
  static bool _cleanedDisabled = false;
  static final _retryAfter = <String, DateTime>{};
  static String key(String scope, String id) => sha256.convert(utf8.encode('$scope:$id')).toString();
  static String voiceSignature(DjVoiceProfile profile, AiSpeechSettings speech, {DjVoiceStudioSettings? studio}) {
    final rotates = profile.rotates;
    return jsonEncode({
      'commentaryPolicy': 1,
      'commentaryLocale': DjVoiceService.commentaryLocale,
      'character': rotates ? profile.settings.character.name : profile.singleCharacter.name,
      'aiVoice': profile.settings.aiVoice,
      'length': profile.length.name,
      'rotate': rotates,
      if (rotates) 'favourites': profile.rotationFavourites.map((v) => v.name).toList(),
      'speech': profile.settings.aiVoice ? speech.toJson() : {'boost': speech.boost},
      if (studio != null && !studio.isEmpty) 'studio': studio.toJson(),
    });
  }

  static void invalidatePreparation() {
    _generation++;
    refresh();
  }

  static String musicKey(String scope, String id, bool hls) {
    final settings = FinampSettingsHelper.finampSettings;
    final format = hls
        ? '${settings.transcodingStreamingFormat.name}:${settings.transcodeBitrate}:${settings.multichannelHandlingSetting.name}'
        : 'original';
    return key(scope, 'music:$id:$format');
  }

  static Future<QueueReserveCache> get cache async => _cache ??= await (_opening ??= (() async {
    final root = await getApplicationSupportDirectory();
    return QueueReserveCache(Directory('${root.path}/queue-reserve'));
  })());

  static Future<void> initialize() => _initializing ??= _initialize();
  static Future<void> loadPreferences() => _loadingPreferences ??= (() async {
    final prefs = SharedPreferencesAsync();
    enabled = await prefs.getBool('queueReserveEnabled') ?? false;
    includeDj = await prefs.getBool('queueReserveDj') ?? false;
    wifiOnly = await prefs.getBool('queueReserveWifi') ?? true;
    count = (await prefs.getInt('queueReserveCount') ?? 3).clamp(1, 3);
  })();
  static Future<void> _initialize() async {
    if (_started) return;
    await loadPreferences();
    _started = true;
    GetIt.instance<QueueService>().getQueueStream().listen((_) => refresh());
    Connectivity().onConnectivityChanged.listen((_) {
      _generation++;
      _retryAfter.clear();
      refresh();
    });
    refresh();
  }

  static Future<void> configure({bool? on, bool? voices, bool? wifi, int? songs}) async {
    enabled = on ?? enabled;
    includeDj = voices ?? includeDj;
    wifiOnly = wifi ?? wifiOnly;
    count = (songs ?? count).clamp(1, 3);
    _generation++;
    _retryAfter.clear();
    _cleanedDisabled = false;
    final prefs = SharedPreferencesAsync();
    await prefs.setBool('queueReserveEnabled', enabled);
    await prefs.setBool('queueReserveDj', includeDj);
    await prefs.setBool('queueReserveWifi', wifiOnly);
    await prefs.setInt('queueReserveCount', count);
    refresh();
  }

  static Future<Uri> source(String id, String playbackId, Uri remote) async {
    if (!enabled) return remote;
    try {
      return await (await cache).source(
        musicKey(RadioPreferencesStore.scope, id, remote.path.endsWith('.m3u8')),
        remote,
        playbackId: key(RadioPreferencesStore.scope, playbackId),
      );
    } on Object {
      return remote;
    }
  }

  static Future<File?> music(String id) async {
    if (!enabled) return null;
    final store = await cache;
    for (final hls in [true, false]) {
      final name = musicKey(RadioPreferencesStore.scope, id, hls);
      if (await store.contains(name)) return store.file(name);
    }
    return null;
  }

  static Future<Uri?> offlineSource(String id, String playbackId) async {
    final cached = await music(id);
    if (cached == null) return null;
    final mime = File('${cached.path}.mime');
    if (await mime.exists() && (await mime.readAsString()).contains('mpegurl')) {
      return (await cache).source(
        musicKey(RadioPreferencesStore.scope, id, true),
        Uri.parse('file:///main.m3u8'),
        playbackId: key(RadioPreferencesStore.scope, '$playbackId:offline'),
      );
    }
    return Uri.file(cached.path);
  }

  static Future<DjAudioClip?> voice(String id, DjVoiceProfile profile) async {
    if (!enabled || !includeDj) return null;
    final signature = voiceSignature(
      profile,
      await AiService.getSpeechSettings(),
      studio: await DjVoiceStudioSettings.load(),
    );
    final store = await cache, name = key(RadioPreferencesStore.scope, '$id:$signature');
    return store.withRead(name, () async {
      final file = File('${store.root.path}/$name.voice.wav');
      final text = File('${store.root.path}/$name.voice.txt');
      if (!await file.exists() || !await text.exists()) return null;
      // The DJ replay store owns its copy and can safely remove it later.
      final copy = await file.copy('${(await getTemporaryDirectory()).path}/reserve-${const Uuid().v4()}.wav');
      return DjAudioClip(copy, await text.readAsString());
    });
  }

  static void refresh() {
    if (!_started || (!enabled && _cleanedDisabled)) return;
    _again = true;
    if (_job != null) return;
    _job =
        (() async {
              while (_again) {
                _again = false;
                await _fill();
              }
            })()
            .catchError((Object _) {
              /* A reserve failure never interrupts playback. */
            })
            .whenComplete(() {
              _job = null;
              status.value = (status.value.$1, status.value.$2, false);
              if (_again) refresh();
            });
  }

  @visibleForTesting
  static Future<void> fill() => _fill();

  static Future<void> _fill() async {
    final store = await cache;
    final scope = RadioPreferencesStore.scope, generation = _generation;
    final queueService = GetIt.instance<QueueService>();
    final queue = queueService.getQueue();
    // A queue being replaced (as at startup) is briefly empty while the player already reads its new songs from here:
    // leave the reserve as it is until the new queue is in place. Its end refreshes the reserve.
    if (queue.currentTrack == null && queueService.settling) return;
    Set<String> playbackKeys(Iterable<FinampQueueItem> items) => {
      for (final item in items) ...[key(scope, item.id), key(scope, '${item.id}:offline')],
    };
    store.activePlaybacks(
      playbackKeys([
        if (queue.currentTrack != null) queue.currentTrack!,
        if (queue.nextUp.isNotEmpty) queue.nextUp.first else if (queue.queue.isNotEmpty) queue.queue.first,
      ]),
    );
    store.retainPlaybacks(
      playbackKeys([
        ...queue.previousTracks,
        if (queue.currentTrack != null) queue.currentTrack!,
        ...queue.nextUp,
        ...queue.queue,
      ]),
    );
    if (!enabled) {
      await store.trim({});
      _cleanedDisabled = !await store.hasOwnedFiles;
      status.value = (0, 0, false);
      return;
    }
    final items = <FinampQueueItem>[];
    final seen = <String>{};
    for (final item in [if (queue.currentTrack != null) queue.currentTrack!, ...queue.nextUp, ...queue.queue]) {
      if (seen.add(item.baseItemId.raw)) items.add(item);
      if (items.length >= count + 1) break;
    }
    final profile = DjVoiceService.effectiveProfile;
    final signature = includeDj
        ? voiceSignature(profile, await AiService.getSpeechSettings(), studio: await DjVoiceStudioSettings.load())
        : '';
    final keep = {
      for (final item in items) musicKey(scope, item.baseItemId.raw, item.item.extras?['shouldTranscode'] == true),
      if (includeDj)
        for (final item in items) key(scope, '${item.baseItemId.raw}:$signature'),
    };
    await store.trim(keep);
    final network = await Connectivity().checkConnectivity();
    final canDownload =
        !FinampSettingsHelper.finampSettings.isOffline &&
        (wifiOnly
            ? network.any((v) => v == ConnectivityResult.wifi || v == ConnectivityResult.ethernet)
            : network.any((v) => v != ConnectivityResult.none));
    bool wanted(FinampQueueItem item) {
      if (!enabled || generation != _generation || scope != RadioPreferencesStore.scope) return false;
      final latest = GetIt.instance<QueueService>().getQueue();
      return latest.currentTrack?.id == item.id ||
          latest.nextUp.any((v) => v.id == item.id) ||
          latest.queue.any((v) => v.id == item.id);
    }

    bool mayPrepare(FinampQueueItem item) => wanted(item) && !FinampSettingsHelper.finampSettings.isOffline;
    var musicReady = 0, voiceReady = 0;
    status.value = (0, 0, canDownload);
    // Upcoming songs have priority over re-downloading the playing song. Finish
    // the music batch before spending time preparing any paid voice lines.
    final priority = [
      for (final item in items)
        if (item.id != queue.currentTrack?.id) item,
      if (items.any((v) => v.id == queue.currentTrack?.id)) queue.currentTrack!,
    ];
    for (final item in priority) {
      if (!wanted(item)) continue;
      final name = musicKey(scope, item.baseItemId.raw, item.item.extras?['shouldTranscode'] == true);
      if (item.item.extras?['downloadedTrackPath'] != null || await store.contains(name)) {
        musicReady++;
      } else if (canDownload && !(_retryAfter[name]?.isAfter(DateTime.now()) ?? false)) {
        final user = GetIt.instance<FinampUserHelper>().currentUser;
        if (user == null) break;
        final uri = await GetIt.instance<MusicPlayerBackgroundTask>().streamUriFor(
          item,
          playSessionId: const Uuid().v4(),
        );
        if (await store.download(name, uri, wanted: () => mayPrepare(item))) {
          musicReady++;
        } else {
          _retryAfter[name] = DateTime.now().add(const Duration(seconds: 30));
        }
      }
      status.value = (musicReady, voiceReady, canDownload);
    }
    for (final item in priority) {
      if (includeDj && profile.settings.mode != DjVoiceMode.off && wanted(item)) {
        final voiceKey = key(scope, '${item.baseItemId.raw}:$signature');
        final file = File('${store.root.path}/$voiceKey.voice.wav');
        final text = File('${store.root.path}/$voiceKey.voice.txt');
        if (await file.exists() && await text.exists()) {
          voiceReady++;
        } else if (canDownload && !(_retryAfter[voiceKey]?.isAfter(DateTime.now()) ?? false)) {
          final clip = await DjVoiceService.prepareOfflineAnnouncement(
            item,
            profile: profile,
            stillWanted: () => mayPrepare(item),
          );
          if (clip != null) {
            try {
              if (wanted(item) && await clip.file.length() >= 44 && await clip.file.length() <= 6 * 1024 * 1024) {
                await store.root.create(recursive: true);
                final temporary = await clip.file.copy('${file.path}.part');
                await text.writeAsString(clip.text, flush: true);
                if (wanted(item)) {
                  await temporary.rename(file.path);
                  voiceReady++;
                } else {
                  await temporary.delete();
                  await text.delete();
                }
              }
            } finally {
              if (await clip.file.exists()) await clip.file.delete();
            }
          } else {
            _retryAfter[voiceKey] = DateTime.now().add(const Duration(minutes: 30));
          }
        }
      }
      status.value = (musicReady, voiceReady, canDownload);
    }
    _retryAfter.removeWhere((key, time) => !keep.contains(key) || !time.isAfter(DateTime.now()));
    status.value = (musicReady, voiceReady, false);
  }
}
