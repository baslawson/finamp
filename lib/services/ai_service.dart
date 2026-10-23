import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart' show ValueNotifier, VoidCallback, visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'ai_provider_health.dart';
import 'ai_usage.dart';
import 'operation_deadline.dart';

/// The AI services the AI DJ can use. Each needs its own API key.
enum AiProvider {
  gemini("Gemini", "https://aistudio.google.com/apikey"),
  openai("OpenAI", "https://platform.openai.com/api-keys"),
  claude("Claude", "https://console.anthropic.com/settings/keys");

  const AiProvider(this.displayName, this.keyUrl);

  final String displayName;

  /// Where the user can create an API key.
  final String keyUrl;
}

/// Text requests and mix creation share this route, separately from speech.
class AiTextSettings {
  factory AiTextSettings({
    AiProvider primary = AiProvider.gemini,
    Iterable<AiProvider> fallbacks = const [AiProvider.openai],
  }) => AiTextSettings._(primary, List.unmodifiable(fallbacks.where((value) => value != primary).toSet()));

  const AiTextSettings._(this.primary, this.fallbacks);
  final AiProvider primary;
  final List<AiProvider> fallbacks;
  List<AiProvider> get order => [primary, ...fallbacks];

  AiTextSettings selectPrimary(AiProvider provider) => AiTextSettings(
    primary: provider,
    fallbacks: [if (fallbacks.contains(provider)) primary, ...fallbacks.where((value) => value != provider)],
  );

  Map<String, dynamic> toJson() => {'primary': primary.name, 'fallbacks': fallbacks.map((v) => v.name).toList()};
  factory AiTextSettings.fromJson(Map<String, dynamic> json) => AiTextSettings(
    primary: AiProvider.values.firstWhereOrNull((value) => value.name == json['primary']) ?? AiProvider.gemini,
    fallbacks: json['fallbacks'] is List
        ? (json['fallbacks'] as List)
              .map((name) => AiProvider.values.firstWhereOrNull((value) => value.name == name))
              .whereType<AiProvider>()
        : const [AiProvider.openai],
  );
}

/// Voice routing is independent of the AI that writes DJ lines and creates mixes.
class AiSpeechSettings {
  factory AiSpeechSettings({
    required AiProvider primary,
    Iterable<AiProvider> fallbacks = const [],
    bool boost = true,
  }) {
    final selected = supported.contains(primary) ? primary : AiProvider.gemini;
    return AiSpeechSettings._(
      selected,
      List.unmodifiable(fallbacks.where((provider) => supported.contains(provider) && provider != selected).toSet()),
      boost,
    );
  }

  const AiSpeechSettings._(this.primary, this.fallbacks, this.boost);
  static const supported = [AiProvider.gemini, AiProvider.openai];
  final AiProvider primary;
  final List<AiProvider> fallbacks;
  final bool boost;
  List<AiProvider> get order => [primary, ...fallbacks];

  AiSpeechSettings selectPrimary(AiProvider provider) => AiSpeechSettings(
    primary: provider,
    fallbacks: [if (fallbacks.contains(provider)) primary, ...fallbacks.where((value) => value != provider)],
    boost: boost,
  );

  Map<String, dynamic> toJson() => {
    'primary': primary.name,
    'fallbacks': fallbacks.map((value) => value.name).toList(),
    'boost': boost,
  };

  factory AiSpeechSettings.fromJson(Map<String, dynamic> json) => AiSpeechSettings(
    primary: supported.firstWhereOrNull((value) => value.name == json['primary']) ?? AiProvider.gemini,
    fallbacks: json['fallbacks'] is List
        ? (json['fallbacks'] as List<dynamic>)
              .map((name) => supported.firstWhereOrNull((value) => value.name == name))
              .whereType<AiProvider>()
        : const [],
    boost: json['boost'] != false,
  );
}

/// Safe failure categories for diagnostics without provider response contents.
enum AiFailureCategory { provider, network, invalidResponse, noAnswer, limit }

class AiException implements Exception {
  AiException(this.message, {this.statusCode, this.timedOut = false, this.category = AiFailureCategory.provider});

  final String message;

  /// The HTTP status the provider answered with, when it answered.
  final int? statusCode;
  final bool timedOut;
  final AiFailureCategory category;

  @override
  String toString() => message;
}

class _TextRequestAttempt {
  _TextRequestAttempt(Duration budget) : deadline = OperationDeadline(budget);

  final OperationDeadline deadline;
  final clock = Stopwatch()..start();
  String? model;
  int inputTokens = 0;
  int outputTokens = 0;
}

/// Sends a prompt to the chosen [AiProvider] and returns structured JSON.
///
/// Schemas are written as plain JSON Schema (lowercase types, every property required,
/// no additional properties), which is converted where a provider expects another dialect.
class AiService {
  AiService._();

  static const _legacyProviderKey = "aiProvider";
  static const _textSettingsKey = "aiTextSettings";
  static String _apiKeyKey(AiProvider provider) => "aiApiKey_${provider.name}";

  static const _claudeModel = "claude-sonnet-5-5";
  static const _geminiFallbackModel = "models/gemini-2.5-flash";
  static const _openAiFallbackModel = "gpt-5-mini";

  static final _logger = Logger("AiService");
  static final Map<AiProvider, String> _models = {};
  static Future<void>? _textSettingsQueue;
  static Future<void>? _speechSettingsQueue;
  static int _speechRevision = 0;
  static final _speechInvalidated = <VoidCallback>{};
  static void _invalidateSpeech() {
    _speechRevision++;
    for (final cancel in _speechInvalidated.toList()) {
      cancel();
    }
  }

  static final Map<AiProvider, DateTime> _speechRetryAfter = {};
  static int get speechRevision => _speechRevision;
  @visibleForTesting
  static bool get hasSpeechPreparations => _speechInvalidated.isNotEmpty;

  /// Cancel prepared speech after local voice preferences change.
  static void invalidateSpeechPreparation() => _invalidateSpeech();
  static final lastSpeechProvider = ValueNotifier<AiProvider?>(null);

  static Future<T> _withSpeechSettings<T>(Future<T> Function() action) {
    late final Future<void> pending;
    final result = (_speechSettingsQueue ?? Future<void>.value()).then((_) => action()).whenComplete(() {
      if (identical(_speechSettingsQueue, pending)) _speechSettingsQueue = null;
    });
    pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    _speechSettingsQueue = pending;
    return result;
  }

  static Future<AiSpeechSettings> getSpeechSettings() => _withSpeechSettings(() async {
    final prefs = SharedPreferencesAsync();
    final saved = await prefs.getString('aiSpeechSettings');
    if (saved != null) {
      try {
        final json = jsonDecode(saved);
        if (json is Map<String, dynamic>) return AiSpeechSettings.fromJson(json);
      } on FormatException {
        // A damaged preference mustn't stop music or voice setup.
      }
    }
    // Preserve the voice API used before this setting existed, then keep it
    // independent of subsequent changes to the text AI.
    final legacyName = await prefs.getString(_legacyProviderKey);
    final chosen = AiProvider.values.firstWhereOrNull((value) => value.name == legacyName) ?? await getProvider();
    AiProvider? primary;
    for (final provider in {chosen, AiProvider.openai, AiProvider.gemini}) {
      if (AiSpeechSettings.supported.contains(provider) && await getApiKey(provider) != null) {
        primary = provider;
        break;
      }
    }
    final settings = AiSpeechSettings(
      primary: primary ?? (chosen == AiProvider.openai ? AiProvider.openai : AiProvider.gemini),
      fallbacks: AiSpeechSettings.supported,
    );
    await prefs.setString('aiSpeechSettings', jsonEncode(settings.toJson()));
    return settings;
  });

  static Future<void> setSpeechSettings(AiSpeechSettings settings) => _withSpeechSettings(() async {
    await SharedPreferencesAsync().setString('aiSpeechSettings', jsonEncode(settings.toJson()));
    _invalidateSpeech();
    _speechRetryAfter.clear();
    lastSpeechProvider.value = null;
  });

  static Future<T> _withTextSettings<T>(Future<T> Function() action) {
    late final Future<void> pending;
    final result = (_textSettingsQueue ?? Future<void>.value()).then((_) => action()).whenComplete(() {
      if (identical(_textSettingsQueue, pending)) _textSettingsQueue = null;
    });
    pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    _textSettingsQueue = pending;
    return result;
  }

  static Future<AiTextSettings> _loadTextSettings() async {
    final saved = await SharedPreferencesAsync().getString(_textSettingsKey);
    if (saved != null) {
      try {
        final json = jsonDecode(saved);
        if (json is Map<String, dynamic>) return AiTextSettings.fromJson(json);
      } on FormatException {
        // A damaged preference uses the normal request defaults.
      }
    }
    // Give requests and mixes their own Gemini -> OpenAI default, including
    // upgrades with a legacy Claude selection. Existing voice choices stay separate.
    return AiTextSettings();
  }

  static Future<AiTextSettings> getTextSettings() => _withTextSettings(_loadTextSettings);
  static Future<void> setTextSettings(AiTextSettings settings) =>
      _withTextSettings(() => SharedPreferencesAsync().setString(_textSettingsKey, jsonEncode(settings.toJson())));
  static Future<AiProvider> getProvider() async => (await getTextSettings()).primary;
  static Future<void> setProvider(AiProvider provider) => _withTextSettings(() async {
    final settings = (await _loadTextSettings()).selectPrimary(provider);
    await SharedPreferencesAsync().setString(_textSettingsKey, jsonEncode(settings.toJson()));
  });

  static Future<String?> getApiKey(AiProvider provider) async {
    final key = await SharedPreferencesAsync().getString(_apiKeyKey(provider));
    return (key == null || key.isEmpty) ? null : key;
  }

  static Future<void> setApiKey(AiProvider provider, String? key) async {
    final prefs = SharedPreferencesAsync();
    if (key == null || key.trim().isEmpty) {
      await prefs.remove(_apiKeyKey(provider));
    } else {
      await prefs.setString(_apiKeyKey(provider), key.trim());
    }
    _models.remove(provider);
    if (provider == AiProvider.gemini) _geminiSpeechModelIds = null;
    if (AiSpeechSettings.supported.contains(provider)) _invalidateSpeech();
    _speechRetryAfter.remove(provider);
    // A new key deserves a fresh start rather than the old key's failures.
    await AiProviderHealth.reset(provider);
  }

  /// Whether a primary or enabled backup has a key, i.e. the AI features can be used.
  static Future<bool> isConfigured() async {
    for (final provider in (await getTextSettings()).order) {
      if (await getApiKey(provider) != null) return true;
    }
    return false;
  }

  static Future<Map<String, dynamic>> generateJson({
    required String prompt,
    required Map<String, dynamic> schema,
    required String schemaName,
    Duration? timeout,
    bool quick = false,
  }) async {
    final deadline = OperationDeadline(timeout ?? const Duration(minutes: 3));
    final settings = await getTextSettings();
    final keys = <AiProvider, String>{};
    for (final provider in settings.order) {
      final key = await getApiKey(provider);
      if (key != null) keys[provider] = key;
    }
    if (keys.isEmpty) throw AiException("No API key set for the selected request AI or its backups");
    await AiUsage.checkLimit();
    // A provider that keeps failing waits behind its backups for a while.
    final providers = await AiProviderHealth.order(keys.keys.toList());
    for (var index = 0; index < providers.length; index++) {
      if (deadline.expired) throw AiException('AI request timed out', timedOut: true);
      final provider = providers[index];
      // Discovery and generation share an attempt's budget. Reserve time for
      // configured backups so a stalled primary cannot consume the whole request,
      // but give the first provider the larger share (two thirds of two): it
      // usually answers, and a slow answer is better than a backup cut short.
      final left = providers.length - index;
      final attempt = _TextRequestAttempt(
        index == 0 && left > 1 ? deadline.remaining * 2 ~/ (left + 1) : deadline.remaining ~/ left,
      );
      try {
        _logger.info('AI request using ${provider.displayName}${provider == settings.primary ? '' : ' backup'}');
        final result = await _generateWithProvider(
          provider,
          keys[provider]!,
          prompt,
          schema,
          schemaName,
          attempt,
          quick: quick,
        );
        unawaited(AiProviderHealth.succeeded(provider));
        unawaited(
          AiUsage.recordText(provider, ok: true, inputTokens: attempt.inputTokens, outputTokens: attempt.outputTokens),
        );
        return result;
      } on AiException catch (e) {
        // The daily limit isn't the provider's fault, and a backup would only go over it.
        if (e.category == AiFailureCategory.limit) rethrow;
        unawaited(AiProviderHealth.failed(provider));
        unawaited(AiUsage.recordText(provider, ok: false));
        if (index == providers.length - 1 || deadline.expired) rethrow;
        // Do not log provider bodies, API keys, or library/prompt contents.
        final reason = e.timedOut ? 'timeout' : (e.statusCode != null ? 'http' : e.category.name);
        _logger.warning(
          '${provider.displayName} request failed '
          '(reason=$reason, status=${e.statusCode ?? 'none'}, timedOut=${e.timedOut}, '
          'elapsedMs=${attempt.clock.elapsedMilliseconds}, budgetMs=${attempt.deadline.timeout.inMilliseconds}, '
          'stage=${attempt.model == null ? 'model_discovery' : 'generation'}, model=${attempt.model ?? 'not_selected'}); '
          'trying ${providers[index + 1].displayName} backup',
        );
      }
    }
    throw AiException('No request AI is available');
  }

  static Future<Map<String, dynamic>> _generateWithProvider(
    AiProvider provider,
    String key,
    String prompt,
    Map<String, dynamic> schema,
    String schemaName,
    _TextRequestAttempt attempt, {
    bool quick = false,
  }) async {
    final deadline = attempt.deadline;
    try {
      final model = attempt.model = switch (provider) {
        AiProvider.gemini => await _geminiModel(key, deadline: deadline),
        AiProvider.openai => _models[AiProvider.openai] ??= await _discoverModel(
          AiProvider.openai,
          Uri.parse("https://api.openai.com/v1/models"),
          {"Authorization": "Bearer $key"},
          listField: "data",
          idField: "id",
          pattern: RegExp(r"^gpt-(\d+(?:\.\d+)?)-mini$"),
          fallback: _openAiFallbackModel,
          deadline: deadline,
        ),
        AiProvider.claude => _claudeModel,
      };
      return switch (provider) {
        AiProvider.gemini => await _gemini(
          key,
          prompt,
          schema,
          model,
          deadline: deadline,
          quick: quick,
          usage: attempt,
        ),
        AiProvider.openai => await _openAi(
          key,
          prompt,
          schema,
          schemaName,
          model,
          deadline: deadline,
          quick: quick,
          usage: attempt,
        ),
        AiProvider.claude => await _claude(key, prompt, schema, model, deadline: deadline, usage: attempt),
      };
    } on AiException {
      rethrow;
    } on FormatException catch (e) {
      throw AiException(
        "${provider.displayName} sent an answer that couldn't be read: ${e.message}",
        category: AiFailureCategory.invalidResponse,
      );
    } on TypeError {
      // An answer of the wrong shape (e.g. a list where an object belongs) is a bad answer, so a backup can take over.
      throw AiException(
        "${provider.displayName} sent an answer in an unexpected shape",
        category: AiFailureCategory.invalidResponse,
      );
    } on TimeoutException {
      throw AiException('${provider.displayName} request timed out', timedOut: true);
    }
  }

  /// A caller's budget includes model discovery; a late discovery cannot start an unwanted generation request.
  static Duration _timeLeft(OperationDeadline? deadline, {Duration maximum = const Duration(minutes: 3)}) {
    if (deadline == null) return maximum;
    final left = deadline.remaining;
    if (left <= Duration.zero) throw TimeoutException('AI request timed out');
    return left < maximum ? left : maximum;
  }

  // Gemini

  static const _geminiBaseUrl = "https://generativelanguage.googleapis.com/v1beta";

  static Future<Map<String, dynamic>> _gemini(
    String key,
    String prompt,
    Map<String, dynamic> schema,
    String model, {
    OperationDeadline? deadline,
    bool quick = false,
    _TextRequestAttempt? usage,
  }) async {
    final thinking = quick ? _quickThinking(model) : null;
    Future<Map<String, dynamic>> send(Map<String, dynamic>? thinkingConfig) async => _post(
      await _reserve(AiProvider.gemini),
      Uri.parse("$_geminiBaseUrl/$model:generateContent"),
      {"x-goog-api-key": key},
      {
        "contents": [
          {
            "role": "user",
            "parts": [
              {"text": prompt},
            ],
          },
        ],
        "generationConfig": {
          "responseMimeType": "application/json",
          "responseSchema": _toGeminiSchema(schema),
          "thinkingConfig": ?thinkingConfig,
        },
      },
      timeout: _timeLeft(deadline),
    );
    Map<String, dynamic> response;
    try {
      response = await send(thinking);
    } on AiException catch (e) {
      // A model that doesn't take this thinking setting answers 400; it's asked once more without it.
      if (thinking == null || e.statusCode != 400) rethrow;
      _quickUnsupported.add(model);
      response = await send(null);
    }
    final metadata = response["usageMetadata"];
    if (usage != null && metadata is Map<String, dynamic>) {
      usage.inputTokens += _int(metadata["promptTokenCount"]);
      usage.outputTokens += _int(metadata["candidatesTokenCount"]) + _int(metadata["thoughtsTokenCount"]);
    }
    final candidate = (response["candidates"] as List<dynamic>?)?.firstOrNull as Map<String, dynamic>?;
    final parts = (candidate?["content"] as Map<String, dynamic>?)?["parts"] as List<dynamic>?;
    final text = parts?.map((part) => (part as Map<String, dynamic>)["text"] ?? "").join() ?? "";
    if (text.isEmpty) {
      throw AiException(
        "Gemini returned no answer (${candidate?["finishReason"] ?? "unknown reason"})",
        category: AiFailureCategory.noAnswer,
      );
    }
    return _jsonObject(text, AiProvider.gemini);
  }

  /// Models that rejected a quick-answer setting; they're asked without it from then on.
  static final Set<String> _quickUnsupported = {};

  static int _int(Object? value) => value is int ? value : 0;

  /// Counts a paid request against the daily limit as it is sent (see [AiUsage.reserve]); returns [provider].
  static Future<AiProvider> _reserve(AiProvider provider, {bool speech = false}) async {
    await AiUsage.reserve(provider, speech: speech);
    return provider;
  }

  /// Less thinking for short, time-limited requests like a DJ line: Gemini 3 and later think a lot by default, which
  /// can take longer than the line's whole budget. Null when the model has no such setting or rejected it before.
  static Map<String, dynamic>? _quickThinking(String model) {
    if (_quickUnsupported.contains(model)) return null;
    final version = RegExp(r"gemini-(\d+)(?:\.(\d+))?").firstMatch(model);
    if (version == null) return null;
    final major = int.parse(version.group(1)!);
    final minor = int.tryParse(version.group(2) ?? "") ?? 0;
    if (major >= 3) return {"thinkingLevel": "low"};
    if (major == 2 && minor >= 5 && model.contains("flash")) return {"thinkingBudget": 0};
    return null;
  }

  /// The OpenAI equivalent, for its reasoning models.
  static String? _quickReasoning(String model) =>
      !_quickUnsupported.contains(model) && RegExp(r"^(gpt-[5-9]|o\d)").hasMatch(model) ? "low" : null;

  /// The newest stable "flash" model the key can use, falling back to a known one.
  static Future<String> _geminiModel(String key, {OperationDeadline? deadline}) async {
    return _models[AiProvider.gemini] ??= await _discoverModel(
      AiProvider.gemini,
      Uri.parse("$_geminiBaseUrl/models?pageSize=200"),
      {"x-goog-api-key": key},
      listField: "models",
      idField: "name",
      pattern: RegExp(r"^models/gemini-(\d+(?:\.\d+)?)-flash$"),
      fallback: _geminiFallbackModel,
      deadline: deadline,
    );
  }

  /// Gemini's schema dialect uses uppercase types and doesn't know "additionalProperties".
  static Map<String, dynamic> _toGeminiSchema(Map<String, dynamic> schema) => {
    for (final entry in schema.entries)
      if (entry.key != "additionalProperties")
        entry.key: switch (entry.key) {
          "type" => (entry.value as String).toUpperCase(),
          "properties" => {
            for (final property in (entry.value as Map<String, dynamic>).entries)
              property.key: _toGeminiSchema(property.value as Map<String, dynamic>),
          },
          "items" => _toGeminiSchema(entry.value as Map<String, dynamic>),
          _ => entry.value,
        },
  };

  // OpenAI

  static Future<Map<String, dynamic>> _openAi(
    String key,
    String prompt,
    Map<String, dynamic> schema,
    String schemaName,
    String model, {
    OperationDeadline? deadline,
    bool quick = false,
    _TextRequestAttempt? usage,
  }) async {
    final reasoning = quick ? _quickReasoning(model) : null;
    Future<Map<String, dynamic>> send(String? reasoningEffort) async => _post(
      await _reserve(AiProvider.openai),
      Uri.parse("https://api.openai.com/v1/chat/completions"),
      {"Authorization": "Bearer $key"},
      {
        "model": model,
        "messages": [
          {"role": "user", "content": prompt},
        ],
        "response_format": {
          "type": "json_schema",
          "json_schema": {"name": schemaName, "strict": true, "schema": schema},
        },
        "reasoning_effort": ?reasoningEffort,
      },
      timeout: _timeLeft(deadline),
    );
    Map<String, dynamic> response;
    try {
      response = await send(reasoning);
    } on AiException catch (e) {
      if (reasoning == null || e.statusCode != 400) rethrow;
      _quickUnsupported.add(model);
      response = await send(null);
    }
    final tokens = response["usage"];
    if (usage != null && tokens is Map<String, dynamic>) {
      usage.inputTokens += _int(tokens["prompt_tokens"]);
      usage.outputTokens += _int(tokens["completion_tokens"]);
    }
    final choice = (response["choices"] as List<dynamic>?)?.firstOrNull as Map<String, dynamic>?;
    final message = choice?["message"] as Map<String, dynamic>?;
    final text = message?["content"] as String?;
    if (text == null || text.isEmpty) {
      throw AiException(
        "OpenAI returned no answer (${message?["refusal"] ?? choice?["finish_reason"] ?? "unknown"})",
        category: AiFailureCategory.noAnswer,
      );
    }
    return _jsonObject(text, AiProvider.openai);
  }

  // Claude

  static Future<Map<String, dynamic>> _claude(
    String key,
    String prompt,
    Map<String, dynamic> schema,
    String model, {
    OperationDeadline? deadline,
    _TextRequestAttempt? usage,
  }) async {
    // Sonnet 5.5 rejects forced tool calls. Structured outputs return the same
    // schema-constrained result directly in a text block.
    final response = await _post(
      await _reserve(AiProvider.claude),
      Uri.parse("https://api.anthropic.com/v1/messages"),
      {"x-api-key": key, "anthropic-version": "2023-06-01"},
      {
        "model": model,
        "max_tokens": 8192,
        "output_config": {
          "format": {"type": "json_schema", "schema": schema},
        },
        "messages": [
          {"role": "user", "content": prompt},
        ],
      },
      timeout: _timeLeft(deadline),
    );
    final tokens = response['usage'];
    if (usage != null && tokens is Map<String, dynamic>) {
      usage.inputTokens += _int(tokens['input_tokens']);
      usage.outputTokens += _int(tokens['output_tokens']);
    }
    if (response['stop_reason'] == 'max_tokens') {
      throw AiException('Claude response was cut off; try a smaller request', category: AiFailureCategory.noAnswer);
    }
    if (response['stop_reason'] == 'refusal') {
      throw AiException(
        'Claude declined this request; try describing it differently',
        category: AiFailureCategory.noAnswer,
      );
    }
    final text = (response['content'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .where((block) => block['type'] == 'text')
        .map((block) => block['text'] as String? ?? '')
        .join();
    if (text.trim().isEmpty) {
      throw AiException(
        "Claude returned no answer (${response["stop_reason"] ?? "unknown"})",
        category: AiFailureCategory.noAnswer,
      );
    }
    return _jsonObject(text, AiProvider.claude);
  }

  // Speech

  /// The first enabled voice provider with a saved key, before any network request.
  static Future<AiProvider?> speechProvider() async {
    for (final provider in (await getSpeechSettings()).order) {
      if (await getApiKey(provider) != null) return provider;
    }
    return null;
  }

  /// The prompt for Gemini's speech model. In plain text in front of the words, the style instructions were sometimes
  /// read out too ("smiling as you speak, warm, upbeat…"); Google's prompt format keeps them apart from the transcript.
  static String geminiSpeechPrompt(String style, String text) =>
      "### DIRECTOR'S NOTES\n$style\n\n#### TRANSCRIPT\n$text";

  /// Newer TTS models read text verbatim; delivery instructions belong in metadata.
  /// Older preview models still need the director's-notes prompt.
  static Map<String, dynamic> geminiSpeechRequest(
    String model,
    String text, {
    required String style,
    required String voice,
    String? languageCode,
  }) {
    final match = _speechModelPattern.firstMatch(model);
    final metadata = match != null && double.parse(match.group(1)!) >= 3.8;
    return {
      "contents": [
        {
          "role": "user",
          "parts": [
            {
              "text": metadata ? text : geminiSpeechPrompt(style, text),
              if (metadata) "speechMetadata": {"style": style},
            },
          ],
        },
      ],
      "generationConfig": {
        "responseModalities": ["AUDIO"],
        if (metadata)
          "responseFormat": {
            "audio": {"mimeType": "AUDIO_L16", "sampleRate": 24000},
          },
        "speechConfig": {
          "languageCode": ?languageCode,
          "voiceConfig": {
            "prebuiltVoiceConfig": {"voiceName": voice},
          },
        },
      },
    };
  }

  /// [text] read aloud by an AI voice as audio file bytes (MP3 or WAV), or null when no key can speak.
  /// [style] describes how it should sound, [voice] picks the OpenAI and Gemini voice.
  static Future<({List<int> bytes, String extension})?> speech(
    String text, {
    required String style,
    required ({String openai, String gemini}) voice,
    double minimumWordsPerSecond = 2.2,
    bool Function()? stillWanted,
    Duration timeout = const Duration(seconds: 60),
    Future<void>? cancelled,
    AiSpeechSettings? routing,
    String? languageCode,
  }) async {
    final revision = _speechRevision;
    final deadline = OperationDeadline(timeout);
    final cancellation = Completer<void>();
    var wasCancelled = false;
    void cancel() {
      wasCancelled = true;
      if (!cancellation.isCompleted) cancellation.complete();
    }

    _speechInvalidated.add(cancel);
    if (cancelled != null) unawaited(cancelled.then((_) => cancel()));
    try {
      bool wanted() => !wasCancelled && revision == _speechRevision && (stillWanted?.call() ?? true);
      final settings = routing ?? await getSpeechSettings();
      Object? failure;
      final keys = <AiProvider, String>{};
      for (final provider in settings.order) {
        final key = await getApiKey(provider);
        if (key != null) keys[provider] = key;
      }
      if (keys.isNotEmpty) await AiUsage.checkLimit();
      final order = keys.keys.toList();
      final healthy = order.where((provider) => _speechRetryAfter[provider]?.isAfter(DateTime.now()) != true).toList();
      final providers = healthy.isEmpty ? order : healthy;
      for (var index = 0; index < providers.length; index++) {
        final provider = providers[index];
        if (!wanted()) return null;
        if (deadline.expired) throw AiException('Voice preparation timed out', timedOut: true);
        final key = keys[provider];
        if (!wanted()) return null;
        if (key == null) continue;
        try {
          final audio = await Future.any([
            _speechWithProvider(
              provider,
              key,
              text,
              style: style,
              languageCode: languageCode,
              voice: voice,
              minimumWordsPerSecond: minimumWordsPerSecond,
              stillWanted: wanted,
              boost: settings.boost,
              deadline: OperationDeadline(deadline.remaining ~/ (providers.length - index)),
              cancelled: cancellation.future,
            ),
            cancellation.future.then((_) => null),
          ]);
          if (!wanted()) return null;
          if (deadline.expired) throw AiException('Voice preparation timed out', timedOut: true);
          if (audio == null) return null;
          lastSpeechProvider.value = provider;
          _speechRetryAfter.remove(provider);
          unawaited(AiUsage.recordSpeech(provider, ok: true, characters: text.length, audio: wavLength(audio.bytes)));
          return audio;
        } catch (error) {
          if (!wanted()) return null;
          if (error is AiException && error.category == AiFailureCategory.limit) rethrow;
          failure = error;
          unawaited(AiUsage.recordSpeech(provider, ok: false));
          if (error is TimeoutException ||
              error is AiException && (error.timedOut || error.statusCode == 429 || (error.statusCode ?? 0) >= 500)) {
            _speechRetryAfter[provider] = DateTime.now().add(const Duration(seconds: 60));
          }
          // Don't log response bodies, headers or API keys here.
          _logger.warning(
            '${provider.displayName} voice failed (${error.runtimeType}); checking enabled fallback APIs',
          );
        }
      }
      if (deadline.expired || failure is TimeoutException) {
        throw AiException('Voice preparation timed out', timedOut: true);
      }
      if (failure is AiException) throw failure;
      if (failure != null) throw AiException("The enabled voice APIs couldn't finish the announcement");
      return null;
    } finally {
      // A pending global Future retained every completed recording until voice
      // preferences changed. Only live preparations now listen for invalidation.
      _speechInvalidated.remove(cancel);
      cancel();
    }
  }

  static Future<({List<int> bytes, String extension})?> _speechWithProvider(
    AiProvider provider,
    String key,
    String text, {
    required String style,
    String? languageCode,
    required ({String openai, String gemini}) voice,
    required double minimumWordsPerSecond,
    required bool Function() stillWanted,
    required bool boost,
    required OperationDeadline deadline,
    required Future<void> cancelled,
  }) async {
    if (provider == AiProvider.openai) {
      for (final model in ["gpt-4o-mini-tts", "tts-1"]) {
        if (!stillWanted()) return null;
        if (deadline.expired) throw TimeoutException('Voice provider deadline reached');
        await _reserve(AiProvider.openai, speech: true);
        final client = http.Client();
        unawaited(cancelled.then((_) => client.close()));
        final http.Response response;
        try {
          response = await client
              .post(
                Uri.parse("https://api.openai.com/v1/audio/speech"),
                headers: {"Content-Type": "application/json", "Authorization": "Bearer $key"},
                body: jsonEncode({
                  "model": model,
                  "voice": voice.openai,
                  "input": text,
                  if (model != "tts-1") "instructions": style,
                  // Raw PCM (24 kHz, 16-bit mono) rather than MP3, so the noise after the voice can be cut off.
                  "response_format": "pcm",
                }),
              )
              .timeout(deadline.cap(const Duration(seconds: 30)));
        } finally {
          client.close();
        }
        if (!stillWanted()) return null;
        if (response.statusCode == 200) {
          final pcm = response.bodyBytes;
          if (pcm.isEmpty || pcm.length.isOdd || pcm.length > 24000 * 2 * 45) {
            throw AiException('OpenAI returned invalid speech PCM');
          }
          final bytes = await _cleanOpenAiSpeech(pcm, boost);
          return (bytes: bytes, extension: "wav");
        }
        if (response.statusCode != 404 && response.statusCode != 400) {
          throw AiException(_describeError(provider, response), statusCode: response.statusCode);
        }
      }
      throw AiException("OpenAI has no speech model available for this key");
    }

    // Gemini's voices now and then read the transcript twice (or ramble on after it): such a take is far longer than
    // the words need, so it's recorded once more, and if that's no better the DJ skips the line.
    for (var attempt = 1; attempt <= 2; attempt++) {
      if (!stillWanted()) return null;
      if (deadline.expired) throw TimeoutException('Voice provider deadline reached');
      final take = await _geminiSpeech(
        key,
        text,
        style: style,
        languageCode: languageCode,
        voice: voice.gemini,
        stillWanted: stillWanted,
        boost: boost,
        deadline: deadline,
        cancelled: cancelled,
      );
      if (take == null || !stillWanted()) return null;
      final length = Duration(microseconds: take.pcm.length ~/ 2 * Duration.microsecondsPerSecond ~/ take.sampleRate);
      if (!tooLongFor(text, length, minimumWordsPerSecond: minimumWordsPerSecond)) {
        _logger.info("Gemini's voice took ${length.inMilliseconds} ms for ${_wordCount(text)} words");
        return (bytes: wav(take.pcm, sampleRate: take.sampleRate), extension: "wav");
      }
      _logger.warning(
        "Gemini's voice took ${length.inMilliseconds} ms for ${_wordCount(text)} words, likely repeating itself "
        "(take $attempt)",
      );
    }
    throw AiException("Gemini's voice kept repeating the line");
  }

  static Future<List<int>> _cleanOpenAiSpeech(List<int> pcm, bool boost) =>
      Isolate.run(() => wav(cleanSpeech(pcm, sampleRate: 24000, boost: boost), sampleRate: 24000));

  static Future<({List<int> pcm, int sampleRate})> _decodeGeminiSpeech(Map<String, dynamic> response, bool boost) =>
      Isolate.run(() => geminiSpeechAudio(response, boost: boost));

  /// How long a PCM WAV recording plays, from its header; null when it isn't one.
  @visibleForTesting
  static Duration? wavLength(List<int> bytes) {
    if (bytes.length < 44 || String.fromCharCodes(bytes.sublist(0, 4)) != "RIFF") return null;
    final byteRate = bytes[28] | bytes[29] << 8 | bytes[30] << 16 | bytes[31] << 24;
    if (byteRate <= 0) return null;
    return Duration(microseconds: (bytes.length - 44) * Duration.microsecondsPerSecond ~/ byteRate);
  }

  static int _wordCount(String text) => text.split(RegExp(r"\s+")).where((word) => word.isNotEmpty).length;

  /// Whether speech of [length] is much longer than [text] takes to say, even slowly: about twice as long means the
  /// voice read it twice. The DJ's voices say about 3 words a second (32 words in 10.9 s on a user's phone, while
  /// doubled takes ran 12 words in 10.3 s and 33 in 19.6 s); this allows 2.2, plus a moment for pauses.
  static bool tooLongFor(String text, Duration length, {double minimumWordsPerSecond = 2.2}) {
    final rate = minimumWordsPerSecond.isFinite ? minimumWordsPerSecond.clamp(1.0, 3.0) : 2.2;
    return length > const Duration(seconds: 45) ||
        length - endPause > Duration(milliseconds: (_wordCount(text) / rate * 1000).round() + 1500);
  }

  static Future<({List<int> pcm, int sampleRate})?> _geminiSpeech(
    String key,
    String text, {
    required String style,
    String? languageCode,
    required String voice,
    required bool Function() stillWanted,
    required bool boost,
    required OperationDeadline deadline,
    required Future<void> cancelled,
  }) async {
    // Each speech model has its own usage limit, so when one is used up the next one speaks instead.
    if (deadline.expired) throw TimeoutException('Voice provider deadline reached');
    final models = await _geminiSpeechModels(key, deadline: deadline, cancelled: cancelled);
    if (!stillWanted()) return null;
    final now = DateTime.now();
    final usable = models.where((model) => _speechModelUsedUp[model]?.isAfter(now) != true).toList();
    Map<String, dynamic>? response;
    AiException? limit;
    for (final model in usable.isEmpty ? models : usable) {
      if (!stillWanted()) return null;
      if (deadline.expired) throw TimeoutException('Voice provider deadline reached');
      try {
        response = await _post(
          await _reserve(AiProvider.gemini, speech: true),
          Uri.parse("$_geminiBaseUrl/$model:generateContent"),
          {"x-goog-api-key": key},
          geminiSpeechRequest(model, text, style: style, voice: voice, languageCode: languageCode),
          timeout: deadline.cap(const Duration(seconds: 45)),
          backgroundDecode: true,
          cancelled: cancelled,
        );
        _logger.info("Gemini speech recorded with $model (voice $voice, language ${languageCode ?? 'automatic'})");
        break;
      } on AiException catch (e) {
        if (!stillWanted()) return null;
        if (e.statusCode != 429) rethrow;
        limit = e;
        _speechModelUsedUp[model] = DateTime.now().add(_usedUpFor);
        _logger.warning("Gemini's speech model $model is at its usage limit: ${e.message}");
      }
    }
    if (response == null) throw limit ?? AiException("Gemini has no speech model available for this key");
    if (!stillWanted()) return null;
    final complete = response;
    return _decodeGeminiSpeech(complete, boost);
  }

  /// Reads every audio part in order, accepting raw PCM and the newer WAV output.
  /// A partial response must never be played as if it were a complete sentence.
  static ({List<int> pcm, int sampleRate}) geminiSpeechAudio(Map<String, dynamic> response, {bool boost = true}) {
    final candidate = (response["candidates"] as List<dynamic>?)?.firstOrNull as Map<String, dynamic>?;
    final reason = candidate?["finishReason"] as String?;
    if (reason != null && reason != "STOP") throw AiException("Gemini returned incomplete speech ($reason)");
    final parts = (candidate?["content"] as Map<String, dynamic>?)?["parts"] as List<dynamic>? ?? [];
    final pcm = <int>[];
    int? sampleRate;
    for (final part in parts.cast<Map<String, dynamic>>()) {
      if (part["thought"] == true) continue;
      final audio = part["inlineData"] as Map<String, dynamic>?;
      if (audio == null) continue;
      final mime = (audio["mimeType"] as String? ?? "audio/l16").toLowerCase();
      if (!mime.startsWith("audio/")) continue;
      final bytes = base64Decode(audio["data"] as String);
      final ({List<int> pcm, int sampleRate}) decoded;
      if (mime.split(";").first.trim() == "audio/wav" || mime.startsWith("audio/x-wav")) {
        final wav = _readSpeechWav(bytes);
        if (wav == null) throw AiException("Gemini returned an unsupported speech WAV");
        decoded = wav;
      } else if (mime.startsWith("audio/l16") || mime.startsWith("audio/pcm")) {
        final rate = int.tryParse(RegExp(r"rate\s*=\s*(\d+)").firstMatch(mime)?.group(1) ?? "");
        final channels = int.tryParse(RegExp(r"channels\s*=\s*(\d+)").firstMatch(mime)?.group(1) ?? "");
        if ((rate != null && rate <= 0) || (channels != null && channels != 1) || bytes.length.isOdd) {
          throw AiException("Gemini returned invalid speech PCM");
        }
        decoded = (pcm: bytes, sampleRate: rate ?? 24000);
      } else {
        throw AiException("Gemini returned an unsupported speech format ($mime)");
      }
      if (sampleRate != null && sampleRate != decoded.sampleRate) {
        throw AiException("Gemini changed the speech sample rate within a line");
      }
      sampleRate = decoded.sampleRate;
      pcm.addAll(decoded.pcm);
    }
    if (pcm.isEmpty || sampleRate == null) throw AiException("Gemini returned no audio");
    if (sampleRate < 8000 || sampleRate > 96000 || pcm.length > sampleRate * 2 * 45) {
      throw AiException("Gemini returned an oversized speech recording");
    }
    _logger.info("Gemini speech: ${pcm.length ~/ 2} samples at $sampleRate Hz; keeping the full recording");
    return (pcm: cleanSpeech(pcm, sampleRate: sampleRate, trimNoise: false, boost: boost), sampleRate: sampleRate);
  }

  static List<String>? _geminiSpeechModelIds;

  /// When each speech model that hit its usage limit is tried again.
  static final Map<String, DateTime> _speechModelUsedUp = {};
  static const _usedUpFor = Duration(minutes: 30);

  static const _geminiSpeechFallback = "models/gemini-2.5-flash-preview-tts";

  /// The Gemini text-to-speech models the key can use, best first: the newest flash model, then older flash models,
  /// then the pro models.
  static Future<List<String>> _geminiSpeechModels(
    String key, {
    required OperationDeadline deadline,
    required Future<void> cancelled,
  }) async {
    if (_geminiSpeechModelIds != null) return _geminiSpeechModelIds!;
    final exhaustsDeadline = deadline.remaining <= const Duration(seconds: 15);
    final client = http.Client();
    unawaited(cancelled.then((_) => client.close()));
    try {
      final response = await client
          .get(Uri.parse("$_geminiBaseUrl/models?pageSize=200"), headers: {"x-goog-api-key": key})
          .timeout(deadline.cap(const Duration(seconds: 15)));
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw AiException(_describeError(AiProvider.gemini, response), statusCode: response.statusCode);
      }
      if (response.statusCode != 200) return [_geminiSpeechFallback];
      final ids = (jsonDecode(response.body)["models"] as List<dynamic>? ?? [])
          .map((model) => (model as Map<String, dynamic>)["name"] as String? ?? "")
          .toList();
      final ordered = speechModelOrder(ids);
      _logger.info("Gemini speech models: ${ordered.join(", ")}");
      return _geminiSpeechModelIds = ordered.isEmpty ? [_geminiSpeechFallback] : ordered;
    } on AiException {
      rethrow;
    } on TimeoutException {
      if (exhaustsDeadline || deadline.expired) rethrow;
      return [_geminiSpeechFallback];
    } catch (e) {
      _logger.warning("Listing Gemini models failed, using $_geminiSpeechFallback", e);
      return [_geminiSpeechFallback];
    } finally {
      client.close();
    }
  }

  static final _speechModelPattern = RegExp(
    r"^models/gemini-(\d+(?:\.\d+)?)-(flash(?:-lite)?|pro)(?:-preview)?-tts(?:-preview)?$",
  );

  /// The speech models among [ids], best first: flash before pro, newer before older.
  static List<String> speechModelOrder(Iterable<String> ids) {
    final models = ids.where(_speechModelPattern.hasMatch).toSet().toList();
    double version(String id) => double.parse(_speechModelPattern.firstMatch(id)!.group(1)!);
    bool pro(String id) => _speechModelPattern.firstMatch(id)!.group(2) == "pro";
    models.sort((a, b) {
      if (pro(a) != pro(b)) return pro(a) ? 1 : -1;
      final byVersion = version(b).compareTo(version(a));
      if (byVersion != 0) return byVersion;
      if (a.contains("-lite-") != b.contains("-lite-")) return a.contains("-lite-") ? 1 : -1;
      return a.compareTo(b);
    });
    return models;
  }

  /// Tidies up 16-bit mono PCM speech. Gemini's voices sometimes leave hiss or static after the last word: that
  /// sounds like noise (the signal crosses zero far more often than a voice does), so everything after the last
  /// voiced bit, plus a little for a trailing "s" or "t", is cut. The edges are faded so the clip doesn't click, and
  /// [endPause] of silence follows.
  ///
  /// Set [trimNoise] to false for Gemini: soft last words and whispered consonants
  /// can be indistinguishable from noise. Keep the recording, boost and pad it.
  static List<int> cleanSpeech(List<int> pcm, {required int sampleRate, bool trimNoise = true, bool boost = true}) {
    final input = Uint8List.fromList(pcm);
    final count = input.length ~/ 2;
    if (count == 0) return const [];
    final data = ByteData.sublistView(input);
    final samples = Float64List(count);
    for (var i = 0; i < count; i++) {
      samples[i] = data.getInt16(i * 2, Endian.little) / 32768;
    }
    if (!trimNoise) return _finishSpeech(samples, sampleRate: sampleRate, keep: count, wordsEnd: count, boost: boost);

    final window = max(1, sampleRate ~/ 50); // 20 ms
    final windows = <({double rms, double crossings, double harmonic})>[];
    for (var start = 0; start < count; start += window) {
      final end = min(count, start + window);
      var energy = 0.0;
      var crossings = 0;
      for (var i = start; i < end; i++) {
        energy += samples[i] * samples[i];
        if (i > start && (samples[i] >= 0) != (samples[i - 1] >= 0)) crossings++;
      }
      windows.add((
        rms: sqrt(energy / (end - start)),
        crossings: crossings / (end - start),
        // Over 40 ms around the window, long enough to tell a low voice's harmonics apart.
        harmonic: harmonicFlatness(
          samples,
          max(0, start - window ~/ 2),
          min(count, start - window ~/ 2 + 2 * window),
          sampleRate: sampleRate,
        ),
      ));
    }
    final peak = windows.map((w) => w.rms).max;
    if (peak <= 0) return const [];
    // A voice has harmonics; static of any kind doesn't. Judged against this voice's own loud parts, since some voices
    // are breathier than others.
    final loud = [
      for (final w in windows)
        if (w.rms >= peak * 0.1) w.harmonic,
    ]..sort();
    final voiceHarmonic = loud.isEmpty ? 0.2 : loud[loud.length ~/ 2];
    // At least 0.3: a word with some breath in it (or a fricative) is still a word, while static sits well above.
    final noisy = min(0.42, max(0.3, max(voiceHarmonic + 0.12, voiceHarmonic * 1.5)));
    bool voiced(({double rms, double crossings, double harmonic}) w) =>
        w.rms >= peak * 0.05 && w.crossings < 0.25 && w.harmonic < noisy;
    var lastVoiced = windows.lastIndexWhere(voiced);
    // Noise after a pause: a last stretch with hardly any voice in it goes, from the pause on. Hardly any, not half:
    // a last phrase like "by Aerosmith" is half hissing consonants, yet it's words.
    while (lastVoiced >= 0) {
      var start = lastVoiced;
      while (start > 0 && windows[start - 1].rms >= peak * 0.03) {
        start--;
      }
      var gapEnd = start - 1;
      while (gapEnd >= 0 && windows[gapEnd].rms < peak * 0.03) {
        gapEnd--;
      }
      final gap = start - 1 - gapEnd;
      if (gap < 6 || gapEnd < 0 || lastVoiced - start > 75) break;
      final stretch = [
        for (var i = start; i <= lastVoiced; i++)
          if (windows[i].rms >= peak * 0.05) windows[i],
      ];
      if (stretch.isEmpty || stretch.where(voiced).length >= stretch.length * 0.2) break;
      lastVoiced = windows.sublist(0, gapEnd + 1).lastIndexWhere(voiced);
    }
    var lastKept = lastVoiced;
    if (lastVoiced >= 0) {
      var silence = lastVoiced + 1;
      while (silence < windows.length && windows[silence].rms >= peak * 0.015) {
        silence++;
      }
      // A word's last sound (the "s" in "words", the "t" in "out") isn't voiced, but it's short and then it's quiet.
      // Static goes on for longer.
      if (silence - lastVoiced - 1 <= 11) lastKept = silence - 1;
      // A last consonant can follow a short hush, like the "t" in "out": short, quieter than the voice, then nothing.
      // It sounds like noise, so it's told apart from static by being brief.
      final voicedLevels = [
        for (final w in windows)
          if (voiced(w)) w.rms,
      ]..sort();
      final voiceLevel = voicedLevels.isEmpty ? peak : voicedLevels[voicedLevels.length ~/ 2];
      var hush = lastKept + 1;
      while (hush < windows.length && hush <= lastKept + 6 && windows[hush].rms < peak * 0.03) {
        hush++;
      }
      var sound = hush;
      while (sound < windows.length && windows[sound].rms >= peak * 0.03) {
        sound++;
      }
      final length = sound - hush;
      if (length > 0 && length <= 13) {
        final loudest = windows.sublist(hush, sound).map((w) => w.rms).max;
        if (loudest <= voiceLevel * 0.5) lastKept = sound - 1;
      }
      // Then the word dies away: keep that while it keeps getting quieter. Static stays level.
      for (var i = lastKept + 1; i < windows.length && i <= lastKept + 8; i++) {
        if (windows[i].rms > windows[i - 1].rms * 0.97) break;
        lastKept = i;
      }
    }
    // Where the words seem to end is a guess, and a wrong one cut off last words. So a little more is kept and faded
    // out, from that point on: a soft ending still comes through, while leftover hiss fades away. Only sound that runs
    // straight on from the words, though: after a hush there's nothing more to say.
    while (lastKept > lastVoiced && windows[lastKept].rms < peak * 0.015) {
      lastKept--;
    }
    final wordsEnd = lastVoiced < 0 ? count : min(count, (lastKept + 1) * window);
    final tailEnd = min(count, wordsEnd + sampleRate * tail.inMilliseconds ~/ 1000);
    var keep = wordsEnd;
    for (var i = wordsEnd ~/ window; keep < tailEnd && i < windows.length && windows[i].rms >= peak * 0.015; i++) {
      keep = min(tailEnd, (i + 1) * window);
    }
    if (count - keep > sampleRate ~/ 10) {
      _logger.info("Cut ${(count - keep) * 1000 ~/ sampleRate} ms of noise off the end of the voice");
    }

    return _finishSpeech(samples, sampleRate: sampleRate, keep: keep, wordsEnd: wordsEnd, boost: boost);
  }

  static List<int> _finishSpeech(
    List<double> samples, {
    required int sampleRate,
    required int keep,
    required int wordsEnd,
    required bool boost,
  }) {
    final fadeIn = min(keep, sampleRate * 30 ~/ 1000);
    final fadeOut = max(keep - wordsEnd, min(keep, sampleRate * 30 ~/ 1000));
    final pause = sampleRate * endPause.inMilliseconds ~/ 1000;
    final output = ByteData((keep + pause) * 2);
    for (var i = 0; i < keep; i++) {
      var gain = 1.0;
      // S-shaped fades: no sudden change in slope at either end, so no click.
      if (i < fadeIn) gain = _smooth(i / fadeIn);
      if (i >= keep - fadeOut) gain = min(gain, _smooth((keep - i) / fadeOut));
      final sample = samples[i] * gain;
      output.setInt16(
        i * 2,
        ((boost ? _limit(sample * voiceBoost) : sample) * 32767).round().clamp(-32768, 32767),
        Endian.little,
      );
    }
    return output.buffer.asUint8List();
  }

  /// Silence after the last word. Long enough that stopping the player once it reports the end can't cut off the
  /// word: the phone's audio output (Bluetooth most of all) plays a little behind the player.
  static const endPause = Duration(milliseconds: 500);

  /// How much is kept, fading out, after where the words seem to end.
  static const tail = Duration(milliseconds: 250);

  /// How much louder cleaned speech comes out (the DJ is played over music, and a player can't go above full volume).
  static const voiceBoost = 1.25;

  /// Leaves [x] alone up to 0.85 and bends the rest smoothly under 1, so boosted peaks don't clip.
  static double _limit(double x) {
    const knee = 0.85;
    final size = x.abs();
    if (size <= knee) return x;
    final bent = knee + (1 - knee) * _tanh((size - knee) / (1 - knee));
    return x.isNegative ? -bent : bent;
  }

  static double _tanh(double x) {
    final e = exp(2 * x);
    return (e - 1) / (e + 1);
  }

  /// 0 to 1 along an S-curve (a raised cosine).
  static double _smooth(double x) => 0.5 - 0.5 * cos(pi * x.clamp(0.0, 1.0));

  /// How flat the spectrum of `samples[start..end]` is, from about 0 (a pure tone) to about 0.56 (white noise):
  /// the geometric over the arithmetic mean of the power spectrum.
  static double spectralFlatness(List<double> samples, int start, int end) {
    final power = _powerSpectrum(samples, start, end);
    if (power == null) return 1;
    var logSum = 0.0;
    var sum = 0.0;
    final bins = power.length - 1;
    for (var k = 1; k <= bins; k++) {
      logSum += log(power[k]);
      sum += power[k];
    }
    final mean = sum / bins;
    return mean <= 1e-10 ? 1 : exp(logSum / bins) / mean;
  }

  /// Like [spectralFlatness], after taking out the spectrum's overall shape, between 60 Hz and 4 kHz: about 0.56
  /// for any kind of noise, muffled or not, and low for a voice, whose harmonics stand out as evenly spaced peaks.
  static double harmonicFlatness(List<double> samples, int start, int end, {required int sampleRate}) {
    final power = _powerSpectrum(samples, start, end);
    if (power == null) return 1;
    final size = (power.length - 1) * 2;
    final from = max(1, (60 * size / sampleRate).floor());
    final to = min(power.length - 1, (4000 * size / sampleRate).ceil());
    const reach = 7; // about ±160 Hz at 24 kHz: wider than the gap between harmonics
    var logSum = 0.0;
    var sum = 0.0;
    var bins = 0;
    for (var k = from; k <= to; k++) {
      var envelope = 0.0;
      var n = 0;
      for (var j = max(1, k - reach); j <= min(power.length - 1, k + reach); j++) {
        envelope += power[j];
        n++;
      }
      final ratio = power[k] / (envelope / n);
      logSum += log(ratio);
      sum += ratio;
      bins++;
    }
    if (bins == 0) return 1;
    final mean = sum / bins;
    return exp(logSum / bins) / mean;
  }

  /// The power spectrum of a Hann-windowed `samples[start..end]`, bins 0 to size/2. Null when too short or silent.
  static Float64List? _powerSpectrum(List<double> samples, int start, int end) {
    var size = 1;
    while (size < end - start) {
      size *= 2;
    }
    if (size < 8) return null;
    final re = Float64List(size);
    final im = Float64List(size);
    final length = end - start;
    for (var i = 0; i < length; i++) {
      // Hann window, so the window's edges don't add noise of their own.
      re[i] = samples[start + i] * (0.5 - 0.5 * cos(2 * pi * i / max(1, length - 1)));
    }
    // In-place radix-2 FFT.
    for (var i = 1, j = 0; i < size; i++) {
      var bit = size >> 1;
      for (; j & bit != 0; bit >>= 1) {
        j ^= bit;
      }
      j ^= bit;
      if (i < j) {
        final r = re[i], m = im[i];
        re[i] = re[j];
        im[i] = im[j];
        re[j] = r;
        im[j] = m;
      }
    }
    for (var half = 1; half < size; half *= 2) {
      final angle = -pi / half;
      for (var i = 0; i < size; i += 2 * half) {
        for (var k = 0; k < half; k++) {
          final (wr, wi) = (cos(angle * k), sin(angle * k));
          final a = i + k, b = i + k + half;
          final tr = re[b] * wr - im[b] * wi;
          final ti = re[b] * wi + im[b] * wr;
          re[b] = re[a] - tr;
          im[b] = im[a] - ti;
          re[a] += tr;
          im[a] += ti;
        }
      }
    }
    final power = Float64List(size ~/ 2 + 1);
    var total = 0.0;
    for (var k = 0; k <= size ~/ 2; k++) {
      power[k] = re[k] * re[k] + im[k] * im[k] + 1e-12;
      total += power[k];
    }
    return total / power.length <= 1e-10 ? null : power;
  }

  /// [cleanSpeech] for a whole WAV file. Files that aren't 16-bit mono PCM come back unchanged.
  static List<int> cleanWav(List<int> bytes, {bool boost = true}) {
    final audio = _readSpeechWav(bytes);
    if (audio == null) return bytes;
    return wav(
      cleanSpeech(audio.pcm, sampleRate: audio.sampleRate, boost: boost),
      sampleRate: audio.sampleRate,
    );
  }

  /// Matches recorded DJ voices using the level of their active 20 ms windows.
  /// Pauses do not make a slow character louder. One gain applies to the whole
  /// recording, with bounded amplification and peak headroom; no words, fades or
  /// output-buffer padding are removed. This is speech RMS matching, not LUFS.
  static List<int> balanceSpeechWav(List<int> bytes, {bool boost = true}) {
    final audio = _readSpeechWav(bytes);
    if (audio == null || audio.pcm.isEmpty) return bytes;
    final pcm = ByteData.sublistView(Uint8List.fromList(audio.pcm));
    final count = audio.pcm.length ~/ 2;
    final window = max(1, audio.sampleRate ~/ 50);
    final levels = <({double energy, int count})>[];
    var peak = 0.0, loudest = 0.0;
    for (var start = 0; start < count; start += window) {
      final end = min(count, start + window);
      var energy = 0.0;
      for (var i = start; i < end; i++) {
        final sample = pcm.getInt16(i * 2, Endian.little) / 32768;
        peak = max(peak, sample.abs());
        energy += sample * sample;
      }
      levels.add((energy: energy, count: end - start));
      loudest = max(loudest, sqrt(energy / (end - start)));
    }
    // Near-silence should stay quiet, rather than having its noise amplified.
    if (loudest < 0.003) return bytes;
    final gate = max(0.003, loudest * 0.1);
    var energy = 0.0;
    var active = 0;
    for (final level in levels) {
      if (level.energy / level.count >= gate * gate) {
        energy += level.energy;
        active += level.count;
      }
    }
    if (active == 0) return bytes;
    // Preserve the existing boosted level. When disabled, the final level must
    // also fall by 1.25 so RMS matching doesn't undo the user's boost switch.
    final target = boost ? 0.18 : 0.18 / voiceBoost;
    final gain = min((target / sqrt(energy / active)).clamp(0.25, 4.0), 0.95 / peak);
    for (var i = 0; i < count; i++) {
      pcm.setInt16(i * 2, (pcm.getInt16(i * 2, Endian.little) * gain).round().clamp(-32768, 32767), Endian.little);
    }
    return wav(pcm.buffer.asUint8List(), sampleRate: audio.sampleRate);
  }

  static ({List<int> pcm, int sampleRate})? _readSpeechWav(List<int> bytes) {
    final data = ByteData.sublistView(Uint8List.fromList(bytes));
    String tag(int offset) => String.fromCharCodes(bytes.sublist(offset, offset + 4));
    if (bytes.length < 12 || tag(0) != "RIFF" || tag(8) != "WAVE") return null;
    int? sampleRate;
    var offset = 12;
    while (offset + 8 <= bytes.length) {
      final size = data.getUint32(offset + 4, Endian.little);
      final body = offset + 8;
      if (tag(offset) == "fmt " && size >= 16 && body + size <= bytes.length) {
        final format = data.getUint16(body, Endian.little);
        final channels = data.getUint16(body + 2, Endian.little);
        final bits = data.getUint16(body + 14, Endian.little);
        if (format != 1 || channels != 1 || bits != 16) return null;
        sampleRate = data.getUint32(body + 4, Endian.little);
        if (sampleRate <= 0) return null;
      } else if (tag(offset) == "data" && sampleRate != null) {
        // Streamed files may leave the size open: then the data runs to the end.
        final end = size == 0 || size == 0xFFFFFFFF ? bytes.length : body + size;
        if (end > bytes.length || (end - body).isOdd) return null;
        return (pcm: bytes.sublist(body, end), sampleRate: sampleRate);
      }
      offset = body + size + (size.isOdd ? 1 : 0);
    }
    return null;
  }

  /// Wraps 16-bit mono PCM samples in a WAV header.
  static List<int> wav(List<int> pcm, {required int sampleRate}) {
    final header = ByteData(44);
    void ascii(int offset, String text) {
      for (var i = 0; i < text.length; i++) {
        header.setUint8(offset + i, text.codeUnitAt(i));
      }
    }

    ascii(0, "RIFF");
    header.setUint32(4, 36 + pcm.length, Endian.little);
    ascii(8, "WAVE");
    ascii(12, "fmt ");
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little); // PCM
    header.setUint16(22, 1, Endian.little); // mono
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, sampleRate * 2, Endian.little);
    header.setUint16(32, 2, Endian.little);
    header.setUint16(34, 16, Endian.little);
    ascii(36, "data");
    header.setUint32(40, pcm.length, Endian.little);
    return [...header.buffer.asUint8List(), ...pcm];
  }

  // Shared

  static Map<String, dynamic> _jsonObject(String text, AiProvider provider) {
    final result = jsonDecode(text);
    if (result is! Map<String, dynamic>) {
      throw AiException(
        '${provider.displayName} returned an unexpected answer format',
        category: AiFailureCategory.invalidResponse,
      );
    }
    return result;
  }

  static Future<Map<String, dynamic>> _post(
    AiProvider provider,
    Uri url,
    Map<String, String> headers,
    Map<String, dynamic> body, {
    Duration timeout = const Duration(minutes: 3),
    bool backgroundDecode = false,
    Future<void>? cancelled,
  }) async {
    final http.Response response;
    final client = http.Client();
    if (cancelled != null) unawaited(cancelled.then((_) => client.close()));
    try {
      response = await client
          .post(url, headers: {"Content-Type": "application/json", ...headers}, body: jsonEncode(body))
          .timeout(timeout);
    } on TimeoutException {
      throw AiException('${provider.displayName} request timed out', timedOut: true);
    } catch (e) {
      throw AiException(
        "Couldn't reach ${provider.displayName}, check the internet connection",
        category: AiFailureCategory.network,
      );
    } finally {
      client.close();
    }
    if (response.statusCode != 200) {
      throw AiException(_describeError(provider, response), statusCode: response.statusCode);
    }
    final bytes = response.bodyBytes;
    if (backgroundDecode && bytes.length > 8 * 1024 * 1024) throw AiException('The speech response was too large');
    return backgroundDecode ? _decodeJsonInBackground(bytes) : jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  }

  // Keep request clients/cancellation futures out of the isolate closure's
  // context. Only response bytes may cross the isolate boundary.
  static Future<Map<String, dynamic>> _decodeJsonInBackground(List<int> bytes) =>
      Isolate.run(() => jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>);

  /// Picks the model with the highest version number matching [pattern] (its first group is the version).
  static Future<String> _discoverModel(
    AiProvider provider,
    Uri url,
    Map<String, String> headers, {
    required String listField,
    required String idField,
    required RegExp pattern,
    required String fallback,
    Duration timeout = const Duration(seconds: 15),
    OperationDeadline? deadline,
  }) async {
    final remaining = deadline?.remaining;
    final exhaustsDeadline = remaining != null && remaining <= timeout;
    final requestTimeout = _timeLeft(deadline, maximum: timeout);
    final client = http.Client();
    try {
      final response = await client.get(url, headers: headers).timeout(requestTimeout);
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw AiException(_describeError(provider, response), statusCode: response.statusCode);
      }
      if (response.statusCode != 200) return fallback;
      final ids = (jsonDecode(response.body)[listField] as List<dynamic>? ?? [])
          .map((model) => (model as Map<String, dynamic>)[idField] as String? ?? "")
          .where(pattern.hasMatch);
      final best = ids.sortedBy<num>((id) => double.parse(pattern.firstMatch(id)!.group(1)!)).lastOrNull;
      _logger.info("Using ${provider.displayName} model ${best ?? fallback}");
      return best ?? fallback;
    } on AiException {
      rethrow;
    } on TimeoutException {
      // A timer can fire just before the elapsed clock reaches its boundary.
      // Once discovery has used the request's remaining budget, don't start
      // a generation request in that tiny interval.
      if (exhaustsDeadline || (deadline?.expired ?? false)) rethrow;
      return fallback;
    } catch (e) {
      final reason = e is FormatException || e is TypeError ? 'invalidResponse' : 'network';
      _logger.warning("Listing ${provider.displayName} models failed ($reason), using $fallback");
      return fallback;
    } finally {
      client.close();
    }
  }

  static String _describeError(AiProvider provider, http.Response response) {
    String? message;
    try {
      final error = jsonDecode(response.body)["error"];
      message = error is Map<String, dynamic> ? error["message"] as String? : error?.toString();
    } catch (_) {}
    final name = provider.displayName;
    return switch (response.statusCode) {
      401 || 403 => "The $name API key isn't valid or lacks access",
      400 when (message ?? "").toLowerCase().contains("api key") => "The $name API key isn't valid",
      429 => "$name usage limit reached${message != null ? ": $message" : ", try again in a minute"}",
      _ => "$name error ${response.statusCode}${message != null ? ": $message" : ""}",
    };
  }
}
