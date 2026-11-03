import 'dart:math';

/// Keeps the host's wording and writing instructions varied across sessions.
/// This stores commentary only, never listening history or personal details.
class DjCommentaryVariety {
  DjCommentaryVariety({Random? random}) : _random = random ?? Random();

  static const memorySize = 24;
  final Random _random;
  final List<String> _lines = [];
  final Map<String, List<String>> _choices = {};

  List<String> get lines => List.unmodifiable(_lines);
  List<String> choices(String category) => List.unmodifiable(_choices[category] ?? const []);

  void restore({required List<String> lines, required Map<String, List<String>> choices}) {
    _lines
      ..clear()
      ..addAll(lines.where((line) => line.trim().isNotEmpty).toList().reversed.take(memorySize).toList().reversed);
    _choices
      ..clear()
      ..addAll(choices.map((key, value) => MapEntry(key, List.of(value))));
  }

  void remember(String line) {
    if (line.trim().isEmpty) return;
    _lines.add(line);
    if (_lines.length > memorySize) _lines.removeAt(0);
  }

  /// Exhausts each category's options before reusing one. A single surviving
  /// option remains usable when the available choices change after an update.
  String pick(String category, List<String> options) {
    if (options.isEmpty) throw ArgumentError.value(options, 'options', 'Must not be empty');
    final history = _choices.putIfAbsent(category, () => []);
    history.removeWhere((choice) => !options.contains(choice));
    final available = options.where((option) => !history.contains(option)).toSet().toList();
    if (available.isEmpty) {
      final last = history.lastOrNull;
      history.clear();
      available.addAll(options.toSet());
      if (available.length > 1) available.remove(last);
    }
    final choice = available[_random.nextInt(available.length)];
    history.add(choice);
    return choice;
  }

  /// Whether [line] opens like one of the last [within] lines: a pair of words from its first three that one of
  /// those also opened with ("Yeah, too right" after "Too right, mate"). For short replies, where a reused
  /// catchphrase is what stands out.
  bool opensLike(String line, {int within = 8}) {
    Set<String> openings(String text) {
      final words = _words(text).take(3).toList();
      return {for (var i = 0; i + 1 < words.length; i++) '${words[i]} ${words[i + 1]}'};
    }

    final next = openings(line);
    if (next.isEmpty) return false;
    return _lines.reversed.take(within).any((recent) => openings(recent).intersection(next).isNotEmpty);
  }

  static List<String> _words(String text) => text
      .toLowerCase()
      .replaceAll('’', "'")
      .split(RegExp(r'''[\s.,!?;:"…—–“”()\[\]{}]+'''))
      .where((word) => word.isNotEmpty)
      .toList();

  /// Recognises reused openings and near-copies, ignoring the mandatory song
  /// and artist names so changing just those doesn't count as fresh commentary.
  bool repeats(String line, {Iterable<String> names = const []}) {
    List<String> words(String text) {
      var clean = text.toLowerCase().replaceAll('’', "'");
      for (final name in names.where((name) => name.trim().isNotEmpty).toList()..sort((a, b) => b.length - a.length)) {
        clean = clean.replaceAll(name.toLowerCase().replaceAll('’', "'"), ' ');
      }
      return clean.split(RegExp(r'''[\s.,!?;:"…—–“”()\[\]{}]+''')).where((word) => word.isNotEmpty).toList();
    }

    Set<String> phrases(List<String> words) => {
      for (var i = 0; i + 2 < words.length; i++) words.sublist(i, i + 3).join(' '),
    };
    final next = words(line);
    if (next.isEmpty) return false;
    final nextPhrases = phrases(next);
    for (final recent in _lines) {
      final previous = words(recent);
      if (next.join(' ') == previous.join(' ')) return true;
      if (next.length >= 4 && previous.length >= 4 && next.take(4).join(' ') == previous.take(4).join(' ')) {
        return true;
      }
      final previousPhrases = phrases(previous);
      final shared = nextPhrases.intersection(previousPhrases).length;
      if (shared >= 2 && shared / max(1, min(nextPhrases.length, previousPhrases.length)) >= 0.5) return true;
    }
    return false;
  }
}
