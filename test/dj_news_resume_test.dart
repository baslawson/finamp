import 'dart:async';

import 'package:finamp/services/dj_voice_service.dart';
import 'package:finamp/services/music_player_background_task.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rxdart/rxdart.dart';

/// A player whose play, like the real one, waits a moment before the player itself starts.
class _Player extends Fake implements MusicPlayerBackgroundTask {
  _Player({this.starts = true});

  final bool starts;
  final playing = BehaviorSubject.seeded(false);
  var plays = 0;

  @override
  Stream<bool> get playerPlaying => playing.stream;

  @override
  Future<void> play({bool disableFade = false}) async {
    plays++;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    if (starts) playing.add(true);
  }
}

void main() {
  test("the news hold lasts until the player really plays again", () async {
    final player = _Player();
    var done = false;
    final resuming = DjVoiceService.resumeAfterNews(player).then((_) => done = true);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    // Asked to play, not playing yet: the music still counts as held, never shown stopped.
    expect(player.plays, 1);
    expect(done, isFalse);
    await resuming.timeout(const Duration(seconds: 1));
    expect(player.playing.value, isTrue);
  });

  test("music that doesn't start again ends the hold after a while", () async {
    final player = _Player(starts: false);
    var done = false;
    final resuming = DjVoiceService.resumeAfterNews(
      player,
      wait: const Duration(milliseconds: 300),
    ).then((_) => done = true);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(done, isFalse);
    await resuming.timeout(const Duration(seconds: 1));
  });

  test("music already playing again (the listener pressed play) ends the hold at once", () async {
    final player = _Player()..playing.add(true);
    await DjVoiceService.resumeAfterNews(player).timeout(const Duration(milliseconds: 80));
  });
}
