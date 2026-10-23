import 'dart:math';

import 'package:collection/collection.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:finamp/services/shuffle_randomness.dart';
import 'package:finamp/services/finamp_user_helper.dart';
import 'package:finamp/services/jellyfin_api_helper.dart';
import 'package:finamp/services/listening_log_service.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:finamp/services/radio_tuning.dart';
import 'package:finamp/services/skip_service.dart';
import 'package:get_it/get_it.dart';

/// A part of the day, for naming the mix.
enum DayPart { morning, afternoon, evening, night }

/// A mix for this moment, learned from what you usually play at this time of day: weekday mornings sound
/// different from Saturday nights. Often skipped songs are left out, and some unheard songs from the same
/// genres keep it fresh.
class RightNowService {
  RightNowService._();

  static const sourceId = "rightNow";
  static const _mixSize = 50;
  static const _freshShare = 0.25;

  /// Apply randomness before choosing the familiar songs, so higher settings
  /// vary the selection as well as the order, while keeping the fresh share.
  static List<BaseItemDto> mixTracks(
    List<BaseItemDto> familiar,
    List<BaseItemDto> fresh, {
    required int randomness,
    Random? random,
  }) {
    var familiarLeft = min(familiar.length, (_mixSize * (1 - _freshShare)).round());
    var freshLeft = _mixSize - familiarLeft;
    final familiarIds = familiar.map((track) => track.id).toSet();
    final tracks = <BaseItemDto>[];
    for (final track in ShuffleRandomness.order([...familiar, ...fresh], randomness, random: random)) {
      if (familiarIds.contains(track.id)) {
        if (familiarLeft <= 0) continue;
        familiarLeft--;
      } else {
        if (freshLeft <= 0) continue;
        freshLeft--;
      }
      tracks.add(track);
    }
    return tracks;
  }

  static DayPart dayPart(DateTime time) => switch (time.hour) {
    >= 5 && < 12 => DayPart.morning,
    >= 12 && < 17 => DayPart.afternoon,
    >= 17 && < 22 => DayPart.evening,
    _ => DayPart.night,
  };

  static bool _isWeekend(DateTime time) => time.weekday == DateTime.saturday || time.weekday == DateTime.sunday;

  /// How much a listen at [listen] says about [now]: close in time of day, same kind of day, and recent.
  static double relevance(DateTime listen, DateTime now) {
    final hours = (listen.hour + listen.minute / 60) - (now.hour + now.minute / 60);
    final distance = min(hours.abs(), 24 - hours.abs());
    final timeOfDay = exp(-distance * distance / 4.5);
    final dayKind = _isWeekend(listen) == _isWeekend(now) ? 1.0 : 0.5;
    final ageDays = now.difference(listen).inHours / 24;
    final recency = pow(0.5, ageDays / 90).toDouble();
    return timeOfDay * dayKind * recency;
  }

  /// Track ids ranked by how well they fit [now], best first.
  static List<String> rank(List<ListenEntry> listens, DateTime now) {
    final scores = <String, double>{};
    for (final listen in listens) {
      scores.update(
        listen.trackId,
        (score) => score + relevance(listen.time, now),
        ifAbsent: () => relevance(listen.time, now),
      );
    }
    return scores.entries.where((entry) => entry.value > 0.05).sortedBy<num>((entry) => -entry.value).map((entry) {
      return entry.key;
    }).toList();
  }

  /// Builds and plays the mix. Returns false when there's not enough history yet.
  static Future<bool> play({required String name}) async {
    final now = DateTime.now();
    final listens = await ListeningLogService.load(forLearning: true);
    final ranked = rank(listens, now);
    if (ranked.length < 10) return false;

    final chance = await SkipService.chanceToPlay();
    final familiar = RadioTuning.rankByWeight(
      ranked.take(_mixSize * 3).toList(),
      // Higher ranked songs are more likely, skipped ones less.
      (id) => chance(id) / (1 + ranked.indexOf(id) / _mixSize),
    );

    // A few songs from the same genres that weren't played recently.
    final genreCounts = <String, double>{};
    for (final listen in listens) {
      for (final genre in listen.genres) {
        genreCounts.update(genre, (count) => count + relevance(listen.time, now), ifAbsent: () => 0);
      }
    }
    final topGenres = genreCounts.entries.sortedBy<num>((entry) => -entry.value).take(3).map((entry) => entry.key);
    final api = GetIt.instance<JellyfinApiHelper>();
    final library = GetIt.instance<FinampUserHelper>().currentUser?.currentView;
    final recent = listens.reversed.take(500).map((listen) => listen.trackId).toSet();
    final fresh = <BaseItemDto>[];
    final genres = topGenres.isEmpty
        ? <BaseItemDto>[]
        : await api.getItems(parentItem: library, includeItemTypes: BaseItemDtoType.genre.jellyfinName) ?? [];
    final genreIds = [
      for (final genre in genres)
        if (topGenres.contains(genre.name)) genre.id,
    ];
    if (genreIds.isNotEmpty) {
      final candidates =
          await api.getItems(
            parentItem: library,
            includeItemTypes: BaseItemDtoType.track.jellyfinName,
            genreFilters: genreIds,
            sortBy: "Random",
            recursive: true,
            limit: _mixSize,
          ) ??
          [];
      fresh.addAll(
        await SkipService.thinOut(
          candidates.where((track) => !recent.contains(track.id.raw) && !familiar.contains(track.id.raw)).toList(),
          (track) => track.id.raw,
        ),
      );
    }

    final familiarTracks = await api.getItems(itemIds: [for (final id in familiar) BaseItemId(id)]) ?? [];
    final byId = {for (final track in familiarTracks) track.id.raw: track};
    final tracks = mixTracks(
      [for (final id in familiar) ?byId[id]],
      fresh,
      randomness: FinampSettingsHelper.finampSettings.shuffleRandomness,
    );
    if (tracks.isEmpty) return false;
    await GetIt.instance<QueueService>().startPlayback(
      items: tracks,
      randomizeGenerated: false,
      source: QueueItemSource.rawId(
        type: QueueItemSourceType.unknown,
        name: QueueItemSourceName(type: QueueItemSourceNameType.preTranslated, pretranslatedName: name),
        id: sourceId,
      ),
      order: FinampPlaybackOrder.linear,
    );
    return true;
  }
}
