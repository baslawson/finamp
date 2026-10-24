import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/services/analyzer_service.dart';
import 'package:hive_ce/hive.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Keeps a genre's songs to the ones that sound like it.
///
/// Genre tags describe an artist or an album, and a song often has several, so a band's ballad counts as "Rock" as
/// much as its loudest single. Songs whose main (first) tag is the genre are trusted more, and with the analyzer each
/// song is checked against the genre's sound: the ones that sound least like it are left out, as long as enough are
/// left.
class GenreFit {
  GenreFit._();

  static final _logger = Logger("GenreFit");
  static const _enabledKey = "genreFitEnabled";

  /// The share of analysed songs at most left out for not sounding like the genre.
  static const dropShare = 0.25;

  /// How much a main tag adds to a song's score (scores are spread around 0 with most within ±1).
  static const mainTagBonus = 0.5;

  /// How long a song's sound check for a genre is remembered.
  static const rememberFor = Duration(hours: 1);

  /// The longest genre key, as the analyzer keeps them.
  static const _longestKey = 215;

  /// The name answers about genre [name] are kept under, the same as the analyzer's: lower case (A to Z only, which
  /// both lower the same way) with single spaces, and a long name (as for many of Radio's genres together) shortened with a hash of the whole. A key is its own key,
  /// so one read back from the analyzer (as the genre editor does) is the same genre.
  static String keyOf(String name) {
    final key = name
        .split(RegExp(r"[ \t\n\r\f\v]+"))
        .where((word) => word.isNotEmpty)
        .join(" ")
        .replaceAllMapped(RegExp("[A-Z]"), (letter) => letter[0]!.toLowerCase());
    final characters = key.runes;
    if (characters.length <= _longestKey) return key;
    return "${String.fromCharCodes(characters.take(_longestKey - 65))}#${sha256.convert(utf8.encode(key))}";
  }

  /// Sound checks by genre key ([keyOf]), then song id.
  static final Map<String, Map<String, _Decision>> _decisions = {};

  /// The songs said to be each genre, looked up lately (Radio asks on every refill).
  static final Map<String, ({List<String> ids, DateTime at})> _answeredFits = {};
  static const _answeredFitsFor = Duration(minutes: 5);

  /// When each song was last answered about, by lower-case genre name then song id, so replies to requests sent
  /// before an answer don't undo it.
  static final Map<String, Map<String, DateTime>> _taughtAt = {};

  /// Counts [forget]s, so replies to requests sent before one aren't kept.
  static int _generation = 0;

  /// The switch as last read or set, so answers don't count while it's off.
  static bool? _enabled;

  /// Counts analyzer changes, so an answer saved to the previous analyzer isn't applied for the new one.
  static int _analyzer = 0;

  /// Forgets everything known from the analyzer when it changes, as the new one may know songs differently.
  static StreamSubscription<void>? _analyzerChanges;
  static void _watchAnalyzer() => _analyzerChanges ??= AnalyzerService.configurationChanges.stream.listen((_) {
    _analyzer++;
    forget();
  });

  /// Whether the app is offline, when there's nothing to ask the analyzer.
  static bool get _offline =>
      Hive.isBoxOpen("FinampSettings") &&
      (Hive.box<FinampSettings>("FinampSettings").get("FinampSettings")?.isOffline ?? false);

  /// When the analyzer last couldn't be reached, after which it isn't asked for a while, so Radio (which asks for every
  /// few songs) doesn't keep waiting for it.
  static DateTime? _failedAt;
  static const _retryAfter = Duration(minutes: 2);

  static void _failed() => _failedAt = DateTime.now();

  /// Whether the analyzer can be asked: the switch is on, an analyzer is set up, the app is online and the analyzer
  /// was reachable lately. Not when its settings can't be read, so genre mixes go by tags.
  static Future<bool> _canAsk() async {
    try {
      _watchAnalyzer();
      final failedAt = _failedAt;
      if (failedAt != null && DateTime.now().difference(failedAt) < _retryAfter) return false;
      return !_offline && await isEnabled() && await AnalyzerService.isConfigured();
    } catch (e) {
      _logger.info("Can't tell whether the analyzer is set up", e);
      return false;
    }
  }

  /// Forgets every sound check and answer looked up.
  static void forget() {
    _generation++;
    _failedAt = null;
    _decisions.clear();
    _answeredFits.clear();
    _taughtAt.clear();
  }

  /// "Match the sound": on until it's turned off.
  static Future<bool> isEnabled() async {
    try {
      return _enabled = await SharedPreferencesAsync().getBool(_enabledKey) ?? true;
    } catch (_) {
      return true;
    }
  }

  static Future<void> setEnabled(bool value) async {
    _enabled = value;
    await SharedPreferencesAsync().setBool(_enabledKey, value);
    // Off goes by tags only, so the answers known so far stop counting until it's back on.
    if (!value) forget();
  }

  /// Whether [track]'s main (first) genre tag is one of [tags] (lower case). Songs without tags count, as nothing
  /// says otherwise.
  static bool hasMainTag(BaseItemDto track, Set<String> tags) {
    final first = track.genres?.firstOrNull ?? track.genreItems?.firstOrNull?.name;
    return first == null || tags.contains(first.toLowerCase());
  }

  /// [tracks] without the ones that don't fit the genre [name] with the tags [tags], in their order. Leaves out songs
  /// only tagged with the genre on the side and, with the analyzer, the ones that sound least like it, but keeps at
  /// least [keepAtLeast] songs (the best of those left out come back first) and at most [keepAtMost].
  static Future<List<BaseItemDto>> filter(
    List<BaseItemDto> tracks, {
    required String name,
    required Set<String> tags,
    required int keepAtLeast,
    int? keepAtMost,
    Duration wait = const Duration(seconds: 20),
  }) async {
    final lowerTags = {for (final tag in tags) tag.toLowerCase()};
    final main = {
      for (final track in tracks)
        if (hasMainTag(track, lowerTags)) track.id.raw,
    };
    final generation = _generation;
    // Off, offline or without the analyzer: tags only, and no earlier sound checks either.
    final soundCheck = await _canAsk();
    final now = DateTime.now();
    // Earlier sound checks of this genre stand, so a pool checked again (as Radio does on every refill) isn't cut
    // down further each time.
    final remembered = soundCheck
        ? ((_decisions[keyOf(name)] ??= {})..removeWhere((_, decision) => now.difference(decision.at) > rememberFor))
        // What the listener said still stands while the switch is on (say, while the analyzer can't be reached).
        : <String, _Decision>{
            if (_enabled ?? true)
              for (final MapEntry(:key, :value) in (_decisions[keyOf(name)] ?? const {}).entries)
                if (value.answered && now.difference(value.at) <= rememberFor) key: value,
          };
    var fresh = const <String, double>{};
    if (soundCheck && tracks.any((track) => !remembered.containsKey(track.id.raw))) {
      ({Map<String, double> scores, Map<String, bool> labels})? result;
      try {
        // The whole pool goes, as scores are relative to it, but only new songs take the new verdict.
        result = await AnalyzerService.genreFit(name, [
          for (final track in tracks) track.id.raw,
        ], main: main).timeout(wait);
        _failedAt = null;
      } catch (e) {
        _logger.info("No sound check for $name, going by tags", e);
        if (generation == _generation) _failed();
      }
      // The switch or the analyzer changed while waiting, so the reply no longer applies: start again as things are.
      if (generation != _generation) {
        return filter(tracks, name: name, tags: tags, keepAtLeast: keepAtLeast, keepAtMost: keepAtMost, wait: wait);
      }
      if (result != null) {
        fresh = result.scores;
        // What the listener said always stands, unless they've answered again since the request went out.
        final taught = _taughtAt[keyOf(name)] ?? const {};
        for (final MapEntry(key: songId, value: fits) in result.labels.entries) {
          if (taught[songId]?.isAfter(now) ?? false) continue;
          remembered[songId] = (keep: fits, score: fresh[songId] ?? 0, at: now, answered: true);
        }
      }
    }
    final scores = {...fresh, for (final MapEntry(:key, :value) in remembered.entries) key: value.score};
    final decided = {for (final MapEntry(:key, :value) in remembered.entries) key: value.keep};
    // Songs said to be the genre stay, even when the analyzer couldn't be asked this time, and over an earlier sound
    // check (the answer may have come from another device since).
    for (final track in tracks) {
      if (!(remembered[track.id.raw]?.answered ?? false) && saidToBe(name, track.id.raw)) {
        decided[track.id.raw] = true;
      }
    }
    String id(BaseItemDto track) => track.id.raw;
    bool isMain(BaseItemDto track) => main.contains(track.id.raw);
    if (fresh.isNotEmpty) {
      // New songs are judged against the whole pool as if nothing were decided, so a few newcomers to a checked
      // pool get the same verdict they would in a fresh one.
      final out = leftOut(tracks, id: id, main: isMain, scores: fresh);
      // An answer given while waiting taught the genre's sound anew, so these scores count this once but aren't kept.
      final keep = !(_taughtAt[keyOf(name)]?.values.any((at) => !at.isBefore(now)) ?? false);
      for (final track in tracks) {
        final score = fresh[track.id.raw];
        if (score != null && !remembered.containsKey(track.id.raw)) {
          if (keep) {
            remembered[track.id.raw] = (keep: !out.contains(track.id.raw), score: score, at: now, answered: false);
          }
          decided[track.id.raw] = !out.contains(track.id.raw);
        }
      }
    }
    final kept = choose(
      tracks,
      id: id,
      main: isMain,
      scores: scores,
      decided: decided,
      refused: {
        for (final MapEntry(:key, :value) in remembered.entries)
          if (value.answered && !value.keep) key,
      },
      keepAtLeast: keepAtLeast,
      keepAtMost: keepAtMost,
    );
    if (_logger.isLoggable(Level.INFO)) {
      final keptIds = {for (final track in kept) track.id.raw};
      final dropped = tracks.where((track) => !keptIds.contains(track.id.raw)).toList()
        ..sort((a, b) => (scores[a.id.raw] ?? 9).compareTo(scores[b.id.raw] ?? 9));
      String describe(BaseItemDto track) {
        final score = scores[track.id.raw];
        return "${track.albumArtist ?? track.artists?.firstOrNull ?? "?"} - ${track.name}"
            "${score == null ? "" : " (${score.toStringAsFixed(2)})"}"
            "${main.contains(track.id.raw) ? "" : " [side tag]"}";
      }

      _logger.info(
        "$name: ${tracks.length} tagged songs, ${main.length} with it as main tag, ${scores.length} sound-checked; "
        "kept ${kept.length}, left out ${dropped.length}"
        "${dropped.isEmpty ? "" : ": ${dropped.take(8).map(describe).join(", ")}"}",
      );
    }
    return kept;
  }

  /// Tells the analyzer the song [songId] is (or with [fits] false, isn't) the genre [name], or forgets the answer when
  /// [fits] is null. Genre mixes follow the answer straight away and learn the genre's sound from it.
  static Future<void> teach(String songId, String name, bool? fits) async {
    // Answers about the same song and genre go one at a time, so the last one given is the one that stays.
    final key = "${keyOf(name)}/$songId";
    // Meant for the analyzer set up now, so an answer still waiting its turn when that changes isn't saved to the new
    // one.
    _watchAnalyzer();
    final analyzer = _analyzer;
    final teaching = (_teaching[key] ?? Future.value())
        .catchError((_) {})
        .then((_) => _teach(songId, name, fits, analyzer));
    _teaching[key] = teaching;
    try {
      await teaching;
    } finally {
      if (identical(_teaching[key], teaching)) unawaited(_teaching.remove(key)); // already done
    }
  }

  /// Answers being saved, by lower-case genre name and song id.
  static final Map<String, Future<void>> _teaching = {};

  static Future<void> _teach(String songId, String name, bool? fits, int analyzer) async {
    if (analyzer != _analyzer) throw StateError("The analyzer changed before the answer was saved");
    await AnalyzerService.setGenreLabel(songId, name, fits);
    // Saved, so it counts from now on, unless the switch is off (which goes by tags only) or it went to an analyzer
    // that has since been replaced.
    if (_enabled == false || analyzer != _analyzer) return;
    _answeredFits.remove(keyOf(name));
    (_taughtAt[keyOf(name)] ??= {})[songId] = DateTime.now();
    final remembered = _decisions[keyOf(name)];
    // The genre's sound is learned again with this answer, so the other songs' sound checks are done again too; what
    // the listener said stays.
    remembered?.removeWhere((_, decision) => !decision.answered);
    if (fits == null) {
      remembered?.remove(songId);
    } else {
      final score = remembered?[songId]?.score ?? 0;
      (_decisions[keyOf(name)] ??= {})[songId] = (keep: fits, score: score, at: DateTime.now(), answered: true);
    }
    _logger.info(
      "Taught: ${fits == null
          ? "forgot"
          : fits
          ? "is"
          : "isn't"} $name: $songId",
    );
  }

  /// The songs the listener said are the genre [name], which genre mixes include even when their tags don't say so.
  /// Empty without the analyzer or the switch.
  static Future<List<String>> answeredFits(String name) async {
    if (!await _canAsk()) return const [];
    final key = keyOf(name);
    final cached = _answeredFits[key];
    if (cached != null && DateTime.now().difference(cached.at) < _answeredFitsFor) return cached.ids;
    final asked = DateTime.now();
    final generation = _generation;
    try {
      final labels = await AnalyzerService.genreLabelsOfGenre(name).timeout(const Duration(seconds: 5));
      if (generation != _generation) return const [];
      _failedAt = null;
      final ids = [
        for (final MapEntry(:key, :value) in labels.entries)
          if (value) key,
      ];
      // The answers looked up stand over earlier sound checks, including ones given on another device (a song said
      // not to be the genre there leaves straight away), and answers taken back there stop counting; apart from
      // answers given here since the request went out.
      final taught = _taughtAt[key] ?? const {};
      bool newer(String songId) => !(taught[songId]?.isBefore(asked) ?? true);
      final remembered = _decisions[key] ??= {};
      remembered.removeWhere((songId, decision) => decision.answered && !labels.containsKey(songId) && !newer(songId));
      for (final MapEntry(key: songId, value: fits) in labels.entries) {
        if (newer(songId)) continue;
        remembered[songId] = (keep: fits, score: remembered[songId]?.score ?? 0, at: asked, answered: true);
      }
      // A reply from before an answer was given isn't kept.
      if (!(_taughtAt[key]?.values.any((at) => !at.isBefore(asked)) ?? false)) {
        _answeredFits[key] = (ids: ids, at: asked);
      }
      return ids;
    } catch (e) {
      _logger.info("Couldn't get the songs said to be $name", e);
      if (generation == _generation) _failed();
      return const [];
    }
  }

  /// Whether the listener said [songId] is the genre [name], as far as is known without asking the analyzer: answers
  /// given here and the ones looked up lately by [answeredFits]. Such songs belong in the genre whatever their tags.
  static bool saidToBe(String name, String songId) {
    if (_enabled == false) return false;
    final key = keyOf(name);
    final decision = _decisions[key]?[songId];
    if (decision != null && decision.answered) return decision.keep;
    final looked = _answeredFits[key];
    return looked != null && looked.ids.contains(songId);
  }

  /// The choice behind [filter], for any kind of item: [items] in their order without the ones [leftOut] picks.
  /// Apart from the ones the listener [refused], those come back, side-tag songs first and then the best fits, to reach [keepAtLeast]; then the list is cut to
  /// [keepAtMost].
  static List<T> choose<T>(
    List<T> items, {
    required String Function(T item) id,
    required bool Function(T item) main,
    Map<String, double> scores = const {},
    Map<String, bool> decided = const {},
    Set<String> refused = const {},
    required int keepAtLeast,
    int? keepAtMost,
  }) {
    final out = leftOut(items, id: id, main: main, scores: scores, decided: decided);
    final kept = [
      for (final item in items)
        if (!out.contains(id(item))) item,
    ];
    double rank(T item) => scores[id(item)] == null ? double.infinity : _fit(scores[id(item)]!, main(item));
    final comeback = items.where((item) => out.contains(id(item)) && !refused.contains(id(item))).toList()
      ..sort((a, b) => rank(b).compareTo(rank(a)));
    kept.addAll(comeback.take(max(0, keepAtLeast - kept.length)));
    return keepAtMost == null || kept.length <= keepAtMost ? kept : kept.sublist(0, keepAtMost);
  }

  /// The ids of [items] that don't fit: the ones [decided] earlier as not fitting; side-tag songs (not [main]) with no
  /// score and no decision; and, of the undecided songs with [scores], the lowest [dropShare] (with the main tag
  /// counted) when they score below average. Earlier decisions stand, so checking a pool again doesn't keep cutting it.
  static Set<String> leftOut<T>(
    List<T> items, {
    required String Function(T item) id,
    required bool Function(T item) main,
    Map<String, double> scores = const {},
    Map<String, bool> decided = const {},
  }) {
    final undecided = [
      for (final item in items)
        if (!decided.containsKey(id(item))) item,
    ];
    final scored = [
      for (final item in undecided)
        if (scores[id(item)] != null) item,
    ]..sort((a, b) => _fit(scores[id(a)]!, main(a)).compareTo(_fit(scores[id(b)]!, main(b))));
    return {
      for (final item in items)
        if (decided[id(item)] == false) id(item),
      for (final item in undecided)
        if (scores[id(item)] == null && !main(item)) id(item),
      for (final item in scored.take((scored.length * dropShare).floor()))
        if (_fit(scores[id(item)]!, main(item)) < 0) id(item),
    };
  }

  static double _fit(double score, bool main) => score + (main ? mainTagBonus : 0);
}

/// Whether a song fit a genre when its sound was checked, with its score then, or what the listener [answered].
typedef _Decision = ({bool keep, double score, DateTime at, bool answered});
