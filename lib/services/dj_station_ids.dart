import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:finamp/services/dj_show_audio.dart';
import 'package:finamp/services/dj_voice_settings.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Short station IDs ("You're listening to ...") recorded once per DJ voice and kept on the phone, then played before
/// an announcement now and then, and whenever the AI writer couldn't help, so a plain song introduction still sounds
/// like radio. Each phrasing costs one voice request, once.
class DjStationIds {
  DjStationIds._();

  static final _logger = Logger('DjStationIds');
  static const _enabledKey = 'djStationIds';
  static const defaultStation = 'Finamp Plus';

  /// Percent of ordinary announcements that start with a station ID.
  static const chance = 15;

  static final _random = Random();
  static bool? _enabled;
  static Future<void>? _recording;

  @visibleForTesting
  static Future<Directory> Function() root = () async =>
      Directory('${(await getApplicationSupportDirectory()).path}/dj-station-ids');

  static Future<bool> isEnabled() async {
    try {
      return _enabled ??= await SharedPreferencesAsync().getBool(_enabledKey) ?? true;
    } catch (_) {
      return true;
    }
  }

  static Future<void> setEnabled(bool enabled) async {
    _enabled = enabled;
    await SharedPreferencesAsync().setBool(_enabledKey, enabled);
  }

  static List<String> phrasings(String station) => [
    "You're listening to $station.",
    "This is $station.",
    "$station. Keep it right here.",
  ];

  static String _key(DjVoiceCharacter character, String text) =>
      sha256.convert(utf8.encode('${character.name}|${character.openai}|${character.gemini}|$text')).toString();

  /// A saved station ID in [character]'s voice, or null when none is saved yet. Then one is recorded in the
  /// background with [record], for next time; at most one recording runs at once, and failures just try again later.
  static Future<List<int>?> pick(
    DjVoiceCharacter character,
    String station, {
    required Future<File?> Function(String text) record,
  }) async {
    if (!await isEnabled()) return null;
    final directory = await root();
    final saved = <File>[];
    String? missing;
    for (final text in phrasings(station)) {
      final file = File('${directory.path}/${_key(character, text)}.wav');
      if (await file.exists()) {
        saved.add(file);
      } else {
        missing ??= text;
      }
    }
    if (missing != null && _recording == null) {
      final text = missing;
      _recording = _save(character, text, directory, record).whenComplete(() => _recording = null);
    }
    if (saved.isEmpty) return null;
    try {
      return await saved[_random.nextInt(saved.length)].readAsBytes();
    } catch (_) {
      return null;
    }
  }

  static Future<void> _save(
    DjVoiceCharacter character,
    String text,
    Directory directory,
    Future<File?> Function(String text) record,
  ) async {
    File? recording;
    try {
      recording = await record(text);
      if (recording == null) return;
      final bytes = await recording.readAsBytes();
      final clean = await Isolate.run(() => DjShowAudio.jingle(bytes));
      await directory.create(recursive: true);
      await File('${directory.path}/${_key(character, text)}.wav').writeAsBytes(clean, flush: true);
      _logger.info('Saved a station ID for ${character.name}');
    } catch (e) {
      _logger.info("Couldn't record a station ID (${e.runtimeType})");
    } finally {
      if (recording != null) unawaited(recording.delete().then<void>((_) {}, onError: (Object _) {}));
    }
  }

  /// Removes every saved station ID, e.g. after the station is renamed. They are recorded again as needed.
  static Future<void> clear() async {
    final directory = await root();
    if (await directory.exists()) await directory.delete(recursive: true);
  }

  @visibleForTesting
  static Future<void> waitForRecording() async => _recording;

  @visibleForTesting
  static void reset() {
    _enabled = null;
    _recording = null;
  }
}
