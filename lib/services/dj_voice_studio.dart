import 'dart:convert';

import 'package:finamp/services/ai_service.dart';
import 'package:finamp/services/dj_voice_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DjVoiceRoute {
  const DjVoiceRoute(this.primary, {this.backup});
  final AiProvider primary;
  final AiProvider? backup;
  AiSpeechSettings apply(AiSpeechSettings defaults) =>
      AiSpeechSettings(primary: primary, fallbacks: [?backup], boost: defaults.boost);
  Map<String, dynamic> toJson() => {'primary': primary.name, 'backup': backup?.name};
}

class DjPronunciation {
  const DjPronunciation(this.name, this.spoken);
  final String name, spoken;
  Map<String, dynamic> toJson() => {'name': name, 'spoken': spoken};
}

/// Device-wide character routes and pronunciation preferences, without secrets.
class DjVoiceStudioSettings {
  const DjVoiceStudioSettings({this.routes = const {}, this.pronunciations = const []});
  final Map<DjVoiceCharacter, DjVoiceRoute> routes;
  final List<DjPronunciation> pronunciations;
  bool get isEmpty => routes.isEmpty && pronunciations.isEmpty;
  DjVoiceStudioSettings withRoute(DjVoiceCharacter character, DjVoiceRoute? route) => DjVoiceStudioSettings(
    routes: Map.unmodifiable(
      {...routes}
        ..remove(character)
        ..addAll(route == null ? const <DjVoiceCharacter, DjVoiceRoute>{} : {character: route}),
    ),
    pronunciations: pronunciations,
  );
  DjVoiceStudioSettings withPronunciations(List<DjPronunciation> values) =>
      DjVoiceStudioSettings(routes: routes, pronunciations: List.unmodifiable(values));

  /// One replacement pass, longest names first. Replacements are literal and
  /// never feed back into the dictionary; on-screen titles retain their spelling.
  String spokenText(String text) {
    final entries = pronunciations.where((v) => v.name.trim().isNotEmpty && v.spoken.trim().isNotEmpty).toList()
      ..sort((a, b) => b.name.length.compareTo(a.name.length));
    if (entries.isEmpty) return text;
    final lookup = {for (final entry in entries) entry.name.toLowerCase(): entry.spoken};
    final pattern = RegExp(entries.map((v) => RegExp.escape(v.name)).join('|'), caseSensitive: false, unicode: true);
    bool word(String s) => RegExp(r'[\p{L}\p{N}_]', unicode: true).hasMatch(s);
    return text.replaceAllMapped(pattern, (match) {
      final original = match[0]!;
      if (match.start > 0 && word(original[0]) && word(text[match.start - 1])) return original;
      if (match.end < text.length && word(original[original.length - 1]) && word(text[match.end])) return original;
      return lookup[original.toLowerCase()] ?? original;
    });
  }

  Map<String, dynamic> toJson() => {
    'routes': {for (final entry in routes.entries) entry.key.name: entry.value.toJson()},
    'pronunciations': pronunciations.map((v) => v.toJson()).toList(),
  };
  factory DjVoiceStudioSettings.fromJson(Map<String, dynamic> json) {
    final routes = <DjVoiceCharacter, DjVoiceRoute>{};
    for (final entry in (json['routes'] is Map ? json['routes'] as Map : const <String, dynamic>{}).entries) {
      final character = DjVoiceCharacter.values.where((v) => v.name == entry.key).firstOrNull;
      if (character == null || entry.value is! Map) continue;
      final value = entry.value as Map;
      final primary = AiSpeechSettings.supported.where((v) => v.name == value['primary']).firstOrNull;
      final backup = AiSpeechSettings.supported.where((v) => v.name == value['backup'] && v != primary).firstOrNull;
      if (primary != null) routes[character] = DjVoiceRoute(primary, backup: backup);
    }
    final pronunciations = <DjPronunciation>[];
    final seen = <String>{};
    for (final value in json['pronunciations'] is List ? json['pronunciations'] as List : const []) {
      if (value is! Map || value['name'] is! String || value['spoken'] is! String) continue;
      final name = (value['name'] as String).trim(), spoken = (value['spoken'] as String).trim();
      if (name.isEmpty || name.length > 80 || spoken.isEmpty || spoken.length > 120 || !seen.add(name.toLowerCase())) {
        continue;
      }
      pronunciations.add(DjPronunciation(name, spoken));
      if (pronunciations.length == 100) break;
    }
    return DjVoiceStudioSettings(routes: Map.unmodifiable(routes), pronunciations: List.unmodifiable(pronunciations));
  }
  static Future<DjVoiceStudioSettings> load() async {
    try {
      return DjVoiceStudioSettings.fromJson(
        Map<String, dynamic>.from(jsonDecode(await SharedPreferencesAsync().getString('djVoiceStudio') ?? '{}') as Map),
      );
    } catch (_) {
      return const DjVoiceStudioSettings();
    }
  }

  Future<void> save() => SharedPreferencesAsync().setString('djVoiceStudio', jsonEncode(toJson()));
}
