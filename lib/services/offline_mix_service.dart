import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/dj_voice_service.dart';
import 'package:finamp/services/downloads_service.dart';
import 'package:finamp/services/finamp_user_helper.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:finamp/services/offline_dj_library.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:finamp/services/jellyfin_api_helper.dart';
import 'package:finamp/services/radio_preferences.dart';
import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';

class OfflineMixService {
  OfflineMixService._();
  static final _logger = Logger('OfflineMixService');
  static final preparing = ValueNotifier<Set<String>>({});
  static final Map<String, int> _generations = {};
  static final Map<String, Future<void>> _jobs = {};
  static Future<void>? _batchTail;

  static List<BaseItemDto> snapshot(FinampQueueInfo queue, int limit) {
    if (limit < 1 || limit > 50) throw ArgumentError.value(limit, 'limit');
    final seen = <BaseItemId>{};
    return [
      for (final entry in [if (queue.currentTrack != null) queue.currentTrack!, ...queue.nextUp, ...queue.queue])
        if (seen.add(entry.baseItem.id)) entry.baseItem,
    ].take(limit).toList();
  }

  static Future<OfflineDjMix> create({required String name, required int limit, required bool includeDj}) async {
    if (name.trim().isEmpty) throw ArgumentError.value(name, 'name');
    final scope = RadioPreferencesStore.scope;
    final queue = GetIt.instance<QueueService>().getQueue();
    final tracks = snapshot(queue, limit);
    if (tracks.isEmpty) throw StateError('No songs are available in the current queue.');
    final profile = await DjVoiceService.loadProfile(stationId: queue.source.djStationId);
    final api = GetIt.instance<JellyfinApiHelper>();
    final user = GetIt.instance<FinampUserHelper>().currentUserId;
    if (scope != RadioPreferencesStore.scope) throw StateError('The active account changed.');
    final created = await api.createNewPlaylist(
      NewPlaylist(
        name: name.trim(),
        ids: tracks.map((track) => track.id).toList(),
        userId: user,
        mediaType: 'Audio',
        isPublic: false,
      ),
    );
    if (created.id == null) throw StateError('Jellyfin did not create the playlist.');
    final playlist = await api.getItemById(created.id!);
    if (scope != RadioPreferencesStore.scope) throw StateError('The active account changed.');
    final library = await OfflineDjLibrary.current();
    final mix = OfflineDjMix(
      id: const Uuid().v4(),
      playlist: playlist,
      tracks: List.unmodifiable(tracks),
      profile: profile,
      includeDj: includeDj,
      stationId: queue.source.djStationId,
      createdAt: DateTime.now(),
    );
    await library.add(mix);
    return mix;
  }

  static void cancel(OfflineDjMix mix) {
    _generations[mix.id] = (_generations[mix.id] ?? 0) + 1;
    preparing.value = {...preparing.value}..remove(mix.id);
  }

  /// Deliberately serialized across mixes: one explicit download request cannot
  /// start dozens of concurrent paid speech calls. Missing lines are retryable.
  static Future<void> prepare(OfflineDjMix mix) {
    if (_jobs[mix.id] case final Future<void> job) {
      return preparing.value.contains(mix.id) ? job : job.then((_) => prepare(mix));
    }
    final scope = RadioPreferencesStore.scope;
    final generation = (_generations[mix.id] ?? 0) + 1;
    _generations[mix.id] = generation;
    preparing.value = {...preparing.value, mix.id};
    late final Future<void> job;
    job = (_batchTail ?? Future<void>.value())
        .catchError((Object _) {})
        .then((_) async {
          final library = await OfflineDjLibrary.current();
          bool wanted() =>
              scope == RadioPreferencesStore.scope &&
              _generations[mix.id] == generation &&
              !FinampSettingsHelper.finampSettings.isOffline &&
              library.contains(mix) &&
              mix.includeDj;
          if (!wanted()) return;
          final source = QueueItemSource.fromBaseItem(
            mix.playlist,
            type: QueueItemSourceType.playlist,
            djStationId: mix.stationId,
          );
          for (final track in mix.tracks) {
            if (!wanted()) break;
            if (await library.hasVoice(mix, track.id.raw)) continue;
            File? file;
            try {
              final item = FinampQueueItem(
                source: source,
                item: MediaItem(
                  id: track.id.raw,
                  title: track.name ?? '',
                  artist: track.artists?.join(', '),
                  extras: {'itemJson': track.toJson()},
                ),
              );
              final clip = await DjVoiceService.prepareOfflineAnnouncement(
                item,
                profile: mix.profile,
                stillWanted: wanted,
              );
              file = clip?.file;
              if (clip != null && wanted()) await library.saveVoice(mix, track.id.raw, clip);
            } catch (error) {
              _logger.info('An offline announcement could not be prepared (${error.runtimeType}); it can be retried.');
            } finally {
              if (file != null) await file.delete().catchError((_) => file!);
            }
          }
        })
        .whenComplete(() {
          if (identical(_jobs[mix.id], job)) _jobs.remove(mix.id);
          if (_generations[mix.id] == generation) preparing.value = {...preparing.value}..remove(mix.id);
          if (identical(_batchTail, job)) _batchTail = null;
        });
    _jobs[mix.id] = job;
    _batchTail = job;
    return job;
  }

  static Future<({int music, int voices, bool ready})> status(OfflineDjLibrary library, OfflineDjMix mix) async {
    final downloads = GetIt.instance<DownloadsService>();
    var music = 0, voices = 0;
    for (final track in mix.tracks) {
      if (downloads.getTrackDownload(id: track.id) != null) music++;
      if (mix.includeDj && await library.hasVoice(mix, track.id.raw)) voices++;
    }
    return (
      music: music,
      voices: voices,
      ready: music == mix.tracks.length && (!mix.includeDj || voices == mix.tracks.length),
    );
  }

  static Future<void> play(OfflineDjMix mix) async {
    final library = await OfflineDjLibrary.current();
    if (!library.contains(mix) || (await status(library, mix)).music != mix.tracks.length) {
      throw StateError('The music download is not complete yet.');
    }
    await GetIt.instance<QueueService>().startPlayback(
      items: mix.tracks,
      source: QueueItemSource.fromBaseItem(
        mix.playlist,
        type: QueueItemSourceType.playlist,
        djStationId: mix.stationId,
      ),
      order: FinampPlaybackOrder.linear,
      startingIndex: 0,
      randomizeGenerated: false,
    );
  }

  static Future<void> clearVoices(OfflineDjMix mix) async {
    cancel(mix);
    await (await OfflineDjLibrary.current()).clearVoices(mix);
  }

  static Future<void> remove(OfflineDjMix mix) async {
    cancel(mix);
    final scope = RadioPreferencesStore.scope;
    final library = await OfflineDjLibrary.current();
    if (scope != RadioPreferencesStore.scope || !library.contains(mix)) throw StateError('The active account changed.');
    await GetIt.instance<DownloadsService>().deleteDownload(
      stub: DownloadStub.fromItem(type: DownloadItemType.collection, item: mix.playlist),
    );
    if (library.contains(mix)) await library.remove(mix);
  }
}
