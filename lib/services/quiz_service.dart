import 'dart:async';
import 'dart:math';

import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/finamp_user_helper.dart';
import 'package:finamp/services/jellyfin_api_helper.dart';
import 'package:finamp/services/library_matcher.dart';
import 'package:get_it/get_it.dart';
import 'package:just_audio/just_audio.dart';

/// Which songs the quiz asks about.
sealed class QuizSource {
  const QuizSource();
}

class QuizEverything extends QuizSource {
  const QuizEverything();
}

class QuizFavorites extends QuizSource {
  const QuizFavorites();
}

class QuizDecade extends QuizSource {
  const QuizDecade(this.decade);

  /// The first year, like 1990.
  final int decade;
}

/// One question: a clip of [answer] and four titles to choose from.
typedef QuizQuestion = ({BaseItemDto answer, List<BaseItemDto> choices, Duration clipStart});

/// Guess the song: plays a few seconds from the middle of a song and offers four titles.
class QuizService {
  QuizService._();

  static const clipLength = Duration(seconds: 5);

  /// Points for a right answer: faster is better.
  static int points({required bool correct, required Duration time}) {
    if (!correct) return 0;
    if (time <= const Duration(seconds: 5)) return 3;
    if (time <= const Duration(seconds: 10)) return 2;
    return 1;
  }

  static Future<List<BaseItemDto>> _pool(QuizSource source) async {
    final api = GetIt.instance<JellyfinApiHelper>();
    return (await api.getItems(
          parentItem: GetIt.instance<FinampUserHelper>().currentUser?.currentView,
          includeItemTypes: BaseItemDtoType.track.jellyfinName,
          recursive: true,
          sortBy: "Random",
          isFavorite: source is QuizFavorites ? true : null,
          years: switch (source) {
            QuizDecade(:final decade) => [for (var year = decade; year < decade + 10; year++) year],
            _ => null,
          },
          limit: 200,
        ) ??
        []);
  }

  /// [count] questions, or fewer when the library (or the chosen part of it) is small.
  static Future<List<QuizQuestion>> questions(QuizSource source, {int count = 10, Random? random}) async {
    return build(await _pool(source), count: count, random: random);
  }

  /// Picks questions from [pool]. Long enough songs only, each title once, and wrong choices that don't look like
  /// the right one.
  static List<QuizQuestion> build(List<BaseItemDto> pool, {int count = 10, Random? random}) {
    final dice = random ?? Random();
    String key(BaseItemDto track) => LibraryMatcher.normalizeTitle(track.name ?? "");
    final unique = <String, BaseItemDto>{};
    for (final track in pool) {
      if ((track.name ?? "").isEmpty || key(track).isEmpty) continue;
      unique.putIfAbsent(key(track), () => track);
    }
    final candidates = unique.values.toList()..shuffle(dice);
    if (candidates.length < 4) return [];
    final playable = candidates
        .where((track) => (track.runTimeTicksDuration() ?? Duration.zero) >= const Duration(seconds: 40))
        .toList();
    return [
      for (final answer in playable.take(count))
        () {
          final decoys = (candidates.where((track) => key(track) != key(answer)).toList()..shuffle(dice)).take(3);
          final length = answer.runTimeTicksDuration()!;
          // Somewhere between a quarter and 60% in: past the intro, usually a recognisable part.
          final start = length * (0.25 + dice.nextDouble() * 0.35);
          return (
            answer: answer,
            choices: ([answer, ...decoys]..shuffle(dice)),
            clipStart: Duration(seconds: start.inSeconds),
          );
        }(),
    ];
  }

  /// The address the quiz player streams [track] from.
  static Uri streamUri(BaseItemDto track) {
    final user = GetIt.instance<FinampUserHelper>().currentUser!;
    final base = Uri.parse(user.baseURL);
    return base.replace(
      pathSegments: [...base.pathSegments.where((segment) => segment.isNotEmpty), "Items", track.id.raw, "File"],
      queryParameters: {...base.queryParameters, "ApiKey": user.accessToken},
    );
  }
}

/// Plays quiz clips on its own player, so the queue stays untouched.
class QuizPlayer {
  final _player = AudioPlayer(handleInterruptions: false, handleAudioSessionActivation: false);
  Timer? _stopTimer;

  /// Loads the clip for [question] without playing it yet.
  Future<void> load(QuizQuestion question) async {
    _stopTimer?.cancel();
    await _player.stop();
    await _player.setUrl(QuizService.streamUri(question.answer).toString(), initialPosition: question.clipStart);
  }

  /// Plays [length] from [from], then fades out.
  Future<void> play({required Duration from, Duration length = QuizService.clipLength}) async {
    _stopTimer?.cancel();
    await _player.seek(from);
    await _player.setVolume(1);
    unawaited(_player.play());
    _stopTimer = Timer(length, () async {
      for (var step = 1; step <= 6; step++) {
        await _player.setVolume(1 - step / 6);
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
      await _player.pause();
    });
  }

  /// Lets the right answer play on for a bit after it's revealed.
  Future<void> playOn() async {
    _stopTimer?.cancel();
    await _player.setVolume(1);
    unawaited(_player.play());
    _stopTimer = Timer(const Duration(seconds: 8), () => unawaited(_player.pause()));
  }

  Future<void> stop() async {
    _stopTimer?.cancel();
    await _player.stop();
  }

  Stream<bool> get playing => _player.playingStream;

  Future<void> dispose() async {
    _stopTimer?.cancel();
    await _player.dispose();
  }
}
