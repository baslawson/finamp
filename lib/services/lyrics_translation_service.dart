import 'dart:convert';
import 'dart:io';

import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/ai_service.dart';
import 'package:finamp/services/current_track_metadata_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Whether the lyrics screen shows translations under each line. Remembered, so foreign songs keep getting
/// translated automatically once it's on.
final lyricsTranslationEnabledProvider = StateProvider<bool>((ref) => LyricsTranslationService.enabled);

typedef LyricsTranslationRequest = ({BaseItemId trackId, String language});

/// Translations of the current track's lyric lines, one per line. Empty when the lyrics are already in the
/// wanted language.
final lyricsTranslationProvider = FutureProvider.autoDispose.family<List<String>, LyricsTranslationRequest>((
  ref,
  request,
) async {
  final metadata = ref.read(currentTrackMetadataProvider).valueOrNull;
  final lines = metadata?.item.id == request.trackId ? metadata?.lyrics?.lyrics : null;
  if (lines == null) return [];
  final translation = await LyricsTranslationService.translateCached(
    request.trackId.raw,
    [for (final line in lines) line.text ?? ""],
    request.language,
  );
  ref.keepAlive();
  return translation;
});

class LyricsTranslationService {
  LyricsTranslationService._();

  static const _enabledKey = "lyricsTranslationEnabled";
  static bool enabled = false;

  static Future<void> initialize() async {
    enabled = await SharedPreferencesAsync().getBool(_enabledKey) ?? false;
  }

  static Future<void> setEnabled(bool value) async {
    enabled = value;
    await SharedPreferencesAsync().setBool(_enabledKey, value);
  }

  static Future<File> _cacheFile(String trackId, String language) async {
    final directory = Directory("${(await getApplicationSupportDirectory()).path}/lyrics_translations");
    await directory.create(recursive: true);
    final safeLanguage = language.replaceAll(RegExp(r"[^A-Za-z0-9]+"), "_");
    return File("${directory.path}/${trackId}_$safeLanguage.json");
  }

  /// Like [translate], but each song is only sent to the AI once per language.
  static Future<List<String>> translateCached(String trackId, List<String> lines, String language) async {
    final file = await _cacheFile(trackId, language);
    try {
      if (await file.exists()) {
        final cached = (jsonDecode(await file.readAsString()) as List<dynamic>).cast<String>();
        if (cached.isEmpty || cached.length == lines.length) return cached;
      }
    } catch (_) {
      // Unreadable cache, translate again.
    }
    final translation = await translate(lines, language);
    await file.writeAsString(jsonEncode(translation));
    return translation;
  }

  /// Translates [lines] into [language] using the configured AI provider, or returns an empty list when
  /// they're already in that language.
  static Future<List<String>> translate(List<String> lines, String language) async {
    final numbered = [for (var i = 0; i < lines.length; i++) "$i|${lines[i]}"].join("\n");
    final result = await AiService.generateJson(
      prompt:
          "Translate these song lyrics into $language. Keep the meaning and tone natural, as a "
          "singable but faithful translation. Each line is 'number|text'; return exactly one "
          "translation per line in the same order. Leave empty lines empty and keep lines already "
          "in $language unchanged. If the lyrics are already mostly in $language, set sameLanguage "
          "to true and return an empty list instead.\n\n$numbered",
      schema: {
        "type": "object",
        "properties": {
          "sameLanguage": {"type": "boolean", "description": "Whether the lyrics are already mostly in the target language"},
          "lines": {
            "type": "array",
            "description": "One translated line per input line, in order",
            "items": {"type": "string"},
          },
        },
        "required": ["sameLanguage", "lines"],
        "additionalProperties": false,
      },
      schemaName: "lyrics_translation",
    );
    if (result["sameLanguage"] == true) return [];
    final translated = (result["lines"] as List).cast<String>();
    return [for (var i = 0; i < lines.length; i++) i < translated.length ? translated[i] : ""];
  }
}
