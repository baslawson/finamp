import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:finamp/services/ai_service.dart';
import 'package:finamp/services/dj_show_audio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A sound that comes with the app, for the news chime or a station jingle: made from the sounds folder by
/// tool/import_sounds.mjs, and listed in assets/sounds/sounds.json.
typedef DjSound = ({String id, String name});

/// The sounds that come with the app.
class DjSounds {
  DjSounds._();

  static final _logger = Logger('DjSounds');
  static Future<List<DjSound>>? _list;
  static final Map<String, Future<List<int>?>> _recordings = {};

  /// Every sound, in the order listed.
  static Future<List<DjSound>> all() => _list ??= _read();

  static Future<List<DjSound>> _read() async {
    try {
      final list = jsonDecode(await rootBundle.loadString('assets/sounds/sounds.json')) as List<dynamic>;
      return [
        for (final sound in list.cast<Map<String, dynamic>>())
          // Never one of the news chime's own choices.
          if (![DjNewsSting.bells, DjNewsSting.own, DjNewsSting.none].contains(sound['id']))
            (id: sound['id'] as String, name: sound['name'] as String? ?? sound['id'] as String),
      ];
    } on Object catch (e) {
      _logger.info("Couldn't read the list of sounds (${e.runtimeType})");
      return const [];
    }
  }

  /// The recording of the sound [id], a WAV at the DJ's voice rate; null when there's none.
  static Future<List<int>?> recording(String id) async {
    if (!(await all()).any((sound) => sound.id == id)) return null;
    return _recordings[id] ??= () async {
      try {
        final data = await rootBundle.load('assets/sounds/$id.wav');
        final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
        DjShowAudio.pcm(bytes, maxSeconds: 12);
        return bytes;
      } on Object catch (e) {
        _logger.info("Couldn't read the sound $id (${e.runtimeType})");
        return null;
      }
    }();
  }

  @visibleForTesting
  static void reset() {
    _list = null;
    _recordings.clear();
  }
}

/// The short chime before the news: the one the listener chose, which is [bells] (three rising bell notes, made here),
/// one of the [DjSounds] by its id, or [own] (one they imported); the bells if that can't be played. A secondary
/// chime, if chosen, takes turns with it.
class DjNewsSting {
  DjNewsSting._();

  /// The choices besides the [DjSounds]; [none] only for the secondary chime.
  static const bells = 'bells', own = 'own', none = '';

  static final _logger = Logger('DjNewsSting');
  static const _choiceKey = 'djNewsChime', _secondKey = 'djNewsChime2', _secondChanceKey = 'djNewsChime2Chance';
  static const _talkKey = 'djNewsChimeTalkOver', _underKey = 'djNewsChimeUnder';

  @visibleForTesting
  static Random random = Random();

  /// The secondary chime chosen and how often it plays (a percentage), once read.
  static Future<({String chime, int chance})>? _second;

  static Future<({String chime, int chance})> _readSecond() async {
    try {
      final prefs = SharedPreferencesAsync();
      final chime = await prefs.getString(_secondKey) ?? none;
      final chance = (await prefs.getInt(_secondChanceKey) ?? 30).clamp(0, 100);
      return (chime: chime != none && await _playable(chime) ? chime : none, chance: chance);
    } on Object {
      return (chime: none, chance: 30);
    }
  }

  /// The secondary chime, taking turns with the primary one: [none], or a choice like [chosen]'s, and the percentage of
  /// news breaks it plays at.
  static Future<({String chime, int chance})> secondary() => _second ??= _readSecond();

  /// Takes [chime] as the secondary chime ([none] for none), if it's there to be played.
  static Future<void> chooseSecondary(String chime) async {
    if (chime != none && !await _playable(chime)) return;
    final chance = (await secondary()).chance;
    _second = Future.value((chime: chime, chance: chance));
    await SharedPreferencesAsync().setString(_secondKey, chime);
  }

  /// Plays the secondary chime at [chance]% of news breaks.
  static Future<void> setSecondaryChance(int chance) async {
    final chime = (await secondary()).chime, clamped = chance.clamp(0, 100);
    _second = Future.value((chime: chime, chance: clamped));
    await SharedPreferencesAsync().setInt(_secondChanceKey, clamped);
  }

  /// How often the voice talks over the chime and the chime's volume under it, once read.
  static Future<({int chance, int under})>? _talk;

  static Future<({int chance, int under})> _readTalk() async {
    try {
      final prefs = SharedPreferencesAsync();
      return (
        chance: (await prefs.getInt(_talkKey) ?? 50).clamp(0, 100),
        under: (await prefs.getInt(_underKey) ?? 25).clamp(5, 50),
      );
    } on Object {
      return (chance: 50, under: 25);
    }
  }

  /// How often (a percentage) the news is read over the chime rather than after it, and the chime's volume under it (a
  /// percentage, 5 to 50).
  static Future<({int chance, int under})> talkOver() => _talk ??= _readTalk();

  /// Changes how often the news is read over the chime, or the chime's volume under it.
  static Future<void> setTalkOver({int? chance, int? under}) async {
    final now = await talkOver();
    final next = (chance: (chance ?? now.chance).clamp(0, 100), under: (under ?? now.under).clamp(5, 50));
    _talk = Future.value(next);
    final prefs = SharedPreferencesAsync();
    await prefs.setInt(_talkKey, next.chance);
    await prefs.setInt(_underKey, next.under);
  }

  /// The listener's own chime, once looked for: null when there's none.
  static Future<List<int>?>? _own;

  /// The chime chosen, once read, and whether that's the bells only because the one chosen is gone.
  static Future<({String value, bool fellBack})>? _choice;

  static Future<({String value, bool fellBack})> _readChoice() async {
    try {
      final choice = await SharedPreferencesAsync().getString(_choiceKey) ?? bells;
      return await _playable(choice) ? (value: choice, fellBack: false) : (value: bells, fellBack: true);
    } on Object {
      return (value: bells, fellBack: false);
    }
  }

  /// Whether [choice] is there to be played: their own chime once imported, a sound still in the app.
  static Future<bool> _playable(String choice) async => switch (choice) {
    bells => true,
    own => await isOwn(),
    _ => (await DjSounds.all()).any((sound) => sound.id == choice),
  };

  /// The chime chosen to play before the news.
  static Future<String> chosen() async => (await (_choice ??= _readChoice())).value;

  /// Plays [choice] before the news from now on, if it's there to be played.
  static Future<void> choose(String choice) async {
    if (!await _playable(choice)) return;
    _choice = Future.value((value: choice, fellBack: false));
    await SharedPreferencesAsync().setString(_choiceKey, choice);
  }

  /// [choice]'s recording, or null when it can't be played.
  static Future<List<int>?> sound(String choice) async => switch (choice) {
    bells => wav,
    own => await (_own ??= _read()),
    _ => await DjSounds.recording(choice),
  };

  static Future<File> _file() async => File('${(await getApplicationSupportDirectory()).path}/dj-news-chime.wav');

  static Future<List<int>?> _read() async {
    try {
      final file = await _file();
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      DjShowAudio.pcm(bytes, maxSeconds: 12);
      return bytes;
    } on Object catch (e) {
      _logger.info("Couldn't read the news chime you imported (${e.runtimeType}); using the bells");
      return null;
    }
  }

  /// The chime played before the news this time: the secondary one at its share of breaks, else the primary; the
  /// other when the one picked can't be played, and the built-in [wav] when neither can.
  static Future<List<int>> chime() async {
    final primary = await (_choice ??= _readChoice()), second = await secondary();
    final secondFirst = second.chime != none && random.nextInt(100) < second.chance;
    final order = [
      if (secondFirst) second.chime,
      // Bells standing in for a primary chime that's gone give way to a secondary one that's there.
      if (!primary.fellBack) primary.value,
      if (!secondFirst && second.chime != none) second.chime,
    ];
    for (final choice in order) {
      if (await sound(choice) case final recording?) return recording;
    }
    return wav;
  }

  /// Whether the listener imported a chime of their own.
  static Future<bool> isOwn() async => await (_own ??= _read()) != null;

  /// Keeps [bytes] (a WAV recording, up to 12 seconds and [DjJingleStore.maxImport]) as the listener's own chime, at
  /// the DJ's voice rate, and chooses it.
  static Future<void> import(List<int> bytes) async {
    if (bytes.length > DjJingleStore.maxImport) throw const FormatException('The chime must be 5 MB or smaller');
    final clean = await Isolate.run(() => DjShowAudio.jingle(bytes));
    final file = await _file();
    await file.parent.create(recursive: true);
    await file.writeAsBytes(clean, flush: true);
    _own = Future.value(clean);
    await choose(own);
  }

  /// Removes the listener's own chime; where it was chosen, the bells play instead (or no secondary chime).
  static Future<void> remove() async {
    final file = await _file();
    if (await file.exists()) await file.delete();
    _own = Future.value(null);
    if (await chosen() == own) await choose(bells);
    if ((await secondary()).chime == own) await chooseSecondary(none);
  }

  @visibleForTesting
  static void reset() {
    _own = null;
    _choice = null;
    _second = null;
    _talk = null;
    random = Random();
    DjSounds.reset();
  }

  /// The notes (E5, G5, C6) and when each starts.
  static const _notes = [(659.25, 0.0), (783.99, 0.16), (1046.5, 0.32)];
  static const _length = Duration(milliseconds: 1100);

  /// The chime as a 16-bit mono WAV at the DJ's voice rate, made once.
  static final List<int> wav = _make();

  static List<int> _make() {
    const rate = DjShowAudio.sampleRate;
    final frames = rate * _length.inMilliseconds ~/ 1000;
    final pcm = ByteData(frames * 2);
    for (var frame = 0; frame < frames; frame++) {
      final t = frame / rate;
      var value = 0.0;
      for (final (frequency, start) in _notes) {
        final at = t - start;
        if (at < 0) continue;
        // A bell: a quick 5 ms attack, then a gentle fade, with a little of its overtones.
        final envelope = min(1.0, at / 0.005) * exp(-at * 4.5);
        value +=
            envelope *
            (sin(2 * pi * frequency * at) +
                0.3 * sin(2 * pi * frequency * 2 * at) +
                0.1 * sin(2 * pi * frequency * 3 * at));
      }
      // Faded out over the last 50 ms, so it ends without a click.
      final tail = min(1.0, (frames - frame) / (rate * 0.05));
      pcm.setInt16(frame * 2, (value * tail * 0.22 * 32767).round().clamp(-32768, 32767), Endian.little);
    }
    return AiService.wav(pcm.buffer.asUint8List(), sampleRate: rate);
  }
}
