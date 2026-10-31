import 'dart:io';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/artist_spacing.dart';
import 'package:finamp/services/music_player_background_task.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:hive_ce/hive.dart';
import 'package:just_audio/just_audio.dart';
import 'package:logging/logging.dart';

const _source = QueueItemSource.rawId(
  type: QueueItemSourceType.allTracks,
  name: QueueItemSourceName(type: QueueItemSourceNameType.preTranslated, pretranslatedName: "Smart Shuffle"),
  id: "smartShuffle",
);

class _Player extends Fake implements MusicPlayerBackgroundTask {
  _Player(this.state);
  SequenceState state;
  @override
  SequenceState get sequenceState => state;
}

class _Queue extends Fake implements QueueService {
  @override
  Logger get queueServiceLogger => Logger("ShuffleTest");
}

/// The pre-change disk format, without the artist-request exemption field.
class _OldSourceAdapter extends TypeAdapter<QueueItemSource> {
  @override
  int get typeId => 54;
  @override
  QueueItemSource read(BinaryReader reader) => throw UnimplementedError();
  @override
  void write(BinaryWriter writer, QueueItemSource source) {
    writer
      ..writeByte(5)
      ..writeByte(0)
      ..write(source.type)
      ..writeByte(1)
      ..write(source.name)
      ..writeByte(2)
      ..write(source.id)
      ..writeByte(4)
      ..write(source.contextNormalizationGain)
      ..writeByte(5)
      ..write(source.library);
  }
}

void main() {
  for (final randomness in [0, 25, 50, 100]) {
    test("repeated native reshuffles use the original sequence at $randomness%", () async {
      final artists = ["A", "B", "C", "A", "B", "C"];
      final tracks = [
        for (final (index, artist) in artists.indexed)
          FinampQueueItem(
            item: MediaItem(
              id: "$index",
              title: "Song $index",
              artist: artist,
              extras: {
                "itemJson": BaseItemDto(
                  id: BaseItemId("$index"),
                  name: "Song $index",
                  artists: [artist],
                  type: "Audio",
                ).toJson(),
              },
            ),
            source: _source,
            type: index == 2
                ? QueueItemQueueType.currentTrack
                : index == 3
                ? QueueItemQueueType.nextUp
                : QueueItemQueueType.queue,
          ),
      ];
      final player = _Player(
        SequenceState(
          sequence: [
            for (final (index, track) in tracks.indexed)
              AudioSource.uri(Uri.parse("file:///song-$index.mp3"), tag: track),
          ],
          currentIndex: 2,
          shuffleIndices: [2, 4, 0, 5, 1, 3],
          shuffleModeEnabled: true,
          loopMode: LoopMode.off,
        ),
      );
      GetIt.instance.registerSingleton<MusicPlayerBackgroundTask>(player);
      addTearDown(() => GetIt.instance.reset());
      final results = <String>{};
      for (var seed = 0; seed < 40; seed++) {
        final order = NextUpShuffleOrder(random: Random(seed), queueService: _Queue(), randomness: randomness)
          ..indices = List.generate(6, (i) => i);
        order.shuffle(initialIndex: 2);
        expect(order.indices.take(2), [2, 3]);
        expect(order.indices, unorderedEquals(List.generate(6, (i) => i)));
        for (var i = 1; i < order.indices.length; i++) {
          expect(
            artists[order.indices[i]],
            isNot(artists[order.indices[i - 1]]),
            reason: "seed $seed: ${order.indices}",
          );
        }
        results.add(order.indices.join(","));
        player.state = player.state.copyWith(shuffleIndices: order.indices);
      }
      if (randomness == 0) expect(results.length, 1);
      if (randomness == 100) expect(results.length, greaterThan(2));
    });
  }

  test("a bare-majority artist starts a fresh shuffle without changing the original playlist", () {
    final input = ["b1", "a1", "a2", "a3", "b2"];
    for (var seed = 0; seed < 20; seed++) {
      final random = Random(seed);
      final start = ArtistSpacing.startingIndex(input, (track) => track[0], random);
      final shuffled = List.generate(input.length, (i) => i)..shuffle(random);
      final indices = ArtistSpacing.shuffleIndices(shuffled, input, (track) => track[0], initialIndex: start);
      for (var i = 1; i < indices.length; i++) {
        expect(input[indices[i]][0], isNot(input[indices[i - 1]][0]));
      }
    }
    expect(input, ["b1", "a1", "a2", "a3", "b2"]);
  });

  test("explicit artist requests allow consecutive artists even after reshuffling", () {
    const requested = QueueItemSource.rawId(
      type: QueueItemSourceType.unknown,
      name: QueueItemSourceName(type: QueueItemSourceNameType.preTranslated, pretranslatedName: "Queen only"),
      id: "aiDj",
      allowArtistRepeats: true,
    );
    expect(ArtistSpacing.allowsRepeats(requested), isTrue);
    expect(
      ArtistSpacing.shuffleIndices(
        [0, 1, 2],
        ["a", "a", "b"],
        (artist) => artist,
        initialIndex: 0,
        allowArtistRepeats: true,
      ),
      [0, 1, 2],
    );
    expect(requested.withItem(BaseItemDto(id: const BaseItemId("aiDj"))).allowArtistRepeats, isTrue);
  });

  test("artist-request exemptions survive saving, and older queues default to spacing", () async {
    final directory = await Directory.systemTemp.createTemp("finamp-artist-queue-");
    Hive.init(directory.path);
    Hive.registerAdapter(QueueItemSourceTypeAdapter());
    Hive.registerAdapter(QueueItemSourceNameTypeAdapter());
    Hive.registerAdapter(QueueItemSourceNameAdapter());
    Hive.registerAdapter(_OldSourceAdapter());
    addTearDown(() async {
      await Hive.close();
      for (final file in await directory.list().toList()) {
        if (file is File) await file.delete();
      }
      await directory.delete();
    });
    var box = await Hive.openBox<QueueItemSource>("legacy");
    await box.put("source", _source);
    await box.close();
    Hive.registerAdapter(QueueItemSourceAdapter(), override: true);
    box = await Hive.openBox<QueueItemSource>("legacy");
    expect(box.get("source")!.allowArtistRepeats, isFalse);
    expect(box.get("source")!.id, _source.id);
    expect(ArtistSpacing.appliesTo(box.get("source")!), isTrue);
    const requested = QueueItemSource.rawId(
      type: QueueItemSourceType.unknown,
      name: QueueItemSourceName(type: QueueItemSourceNameType.preTranslated, pretranslatedName: "Queen only"),
      id: "aiDj",
      allowArtistRepeats: true,
    );
    await box.put("source", requested);
    await box.close();
    box = await Hive.openBox<QueueItemSource>("legacy");
    expect(box.get("source"), requested);
    expect(box.get("source")!.allowArtistRepeats, isTrue);
    expect(ArtistSpacing.appliesTo(box.get("source")!, shuffled: true), isFalse);
    expect(requested, isNot(QueueItemSource.rawId(type: requested.type, name: requested.name, id: requested.id)));
  });
}
