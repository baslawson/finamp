import 'dart:math';

import 'package:finamp/services/dj_commentary_variety.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('all topics and openings get a turn before one is reused', () {
    final memory = DjCommentaryVariety(random: Random(7));
    const options = ['mood', 'sound', 'album', 'instrument', 'short introduction'];
    final first = List.generate(options.length, (_) => memory.pick('angle', options));
    expect(first.toSet(), options.toSet());
    expect(memory.pick('angle', options), isNot(first.last));
    expect(memory.pick('opening', options), isIn(options));
  });

  test('restart restores wording and the unused choices', () {
    final first = DjCommentaryVariety(random: Random(1));
    const options = ['title', 'artist', 'fact', 'reaction'];
    final used = [first.pick('opening', options), first.pick('opening', options)];
    first.remember('The guitars have barely settled. Here comes Queen.');
    final restored = DjCommentaryVariety(random: Random(2))
      ..restore(lines: first.lines, choices: {'opening': first.choices('opening')});
    expect(restored.lines, first.lines);
    expect(used, isNot(contains(restored.pick('opening', options))));
  });

  test('long sessions reshuffle each cycle instead of repeating one fixed order', () {
    final memory = DjCommentaryVariety(random: Random(11));
    const options = ['mood', 'sound', 'album', 'instrument', 'short introduction'];
    final orders = <String>{};
    String? previous;
    for (var cycle = 0; cycle < 6; cycle++) {
      final current = List.generate(options.length, (_) => memory.pick('angle', options));
      expect(current.toSet(), options.toSet());
      expect(current.first, isNot(previous));
      previous = current.last;
      orders.add(current.join(','));
    }
    expect(orders.length, greaterThan(1));
  });

  test('old versions and removed choices cannot prevent a new choice', () {
    final memory = DjCommentaryVariety()
      ..restore(
        lines: List.generate(100, (i) => 'line $i'),
        choices: {
          'intro': ['removed', 'only', 'only'],
        },
      );
    expect(memory.lines, hasLength(DjCommentaryVariety.memorySize));
    expect(memory.lines.last, 'line 99');
    expect(memory.pick('intro', ['only']), 'only');
    memory.remember('a new line');
    expect(memory.lines, hasLength(DjCommentaryVariety.memorySize));
    expect(memory.lines.last, 'a new line');
  });

  test('spots recycled wording even when the song details change', () {
    final memory = DjCommentaryVariety()..remember('Keeping the good times rolling. Queen brings the guitars next.');
    expect(memory.repeats('Keeping the good times rolling! Here is Muse.'), isTrue);
    memory.restore(lines: ['Here is Queen with One.'], choices: {});
    expect(memory.repeats('Here is Queen with ONE!', names: ['Queen', 'One']), isTrue);
    expect(memory.repeats('Muse takes us somewhere quieter. Let the piano settle in.'), isFalse);
  });

  test('a reply opening with a recent catchphrase is recognised', () {
    final memory = DjCommentaryVariety()..remember('Too right, mate, that bassline hits.');
    expect(memory.opensLike('Too right! Lovely groove.'), isTrue);
    expect(memory.opensLike('Yeah, too right, smooth one.'), isTrue);
    expect(memory.opensLike('That chorus though, what a lift.'), isFalse);
    expect(memory.opensLike('Love the drums, too right.'), isFalse);
  });

  test('only the last few replies count for openings', () {
    final memory = DjCommentaryVariety()..remember('Too right, mate.');
    for (var i = 0; i < 8; i++) {
      memory.remember('Reply number $i here.');
    }
    expect(memory.opensLike('Too right, again.'), isFalse);
    expect(memory.opensLike('Too right, again.', within: 9), isTrue);
  });
}
