import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A headphone model with an AutoEQ correction profile.
typedef HeadphoneProfile = ({String name, String path, String source});

/// The active correction: which headphone, and its AutoEQ curve as (frequency Hz, gain dB) points.
typedef HeadphoneCorrection = ({String name, String path, List<(double, double)> curve});

class HeadphoneTone {
  const HeadphoneTone({this.bass = 0, this.warmth = 0, this.clarity = 0});
  final double bass, warmth, clarity;
  Map<String, double> toJson() => {'bass': bass, 'warmth': warmth, 'clarity': clarity};
  factory HeadphoneTone.fromJson(Map<String, dynamic> json) {
    double value(String key) {
      final raw = json[key];
      return raw is num && raw.isFinite ? raw.toDouble().clamp(-4, 4) : 0;
    }

    return HeadphoneTone(bass: value('bass'), warmth: value('warmth'), clarity: value('clarity'));
  }
  List<(double, double)> get curve => bass == 0 && warmth == 0 && clarity == 0
      ? const []
      : [
          (20, bass),
          (80, bass),
          (200, bass * .25 + warmth * .5),
          (400, warmth),
          (1000, warmth * .25),
          (2500, clarity * .75),
          (5000, clarity),
          (10000, clarity * .5),
          (20000, 0),
        ];
}

/// Applies AutoEQ (https://github.com/jaakkopasanen/AutoEq) headphone corrections to the device equalizer.
class HeadphoneEqService {
  HeadphoneEqService._();

  static final _logger = Logger("HeadphoneEqService");
  static const _results = "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results";
  static const _prefsKey = "headphoneEqCorrection";
  static Future<void> _writes = Future.value();
  static int _previewGeneration = 0;
  static Future<HeadphoneTone> loadTone() async {
    try {
      return HeadphoneTone.fromJson(
        Map<String, dynamic>.from(jsonDecode(await SharedPreferencesAsync().getString('headphoneTone') ?? '{}') as Map),
      );
    } on Object {
      return const HeadphoneTone();
    }
  }

  static Future<void> saveTone(HeadphoneTone tone, AndroidEqualizer equalizer) async {
    _previewGeneration++;
    await SharedPreferencesAsync().setString('headphoneTone', jsonEncode(tone.toJson()));
    unawaited(refresh(equalizer).catchError((Object e) => _logger.warning('Could not apply tone controls', e)));
  }

  static Future<void> _serial(Future<void> Function() action) {
    final next = _writes.catchError((Object _) {}).then((_) => action());
    _writes = next;
    return next;
  }

  /// Equal band-power matching is an estimate, not a track loudness measurement.
  /// A shared reserve keeps the PCM normalization gain identical for both sides.
  static List<double> matchBandPower(List<double> gains, {double minDecibels = -100, double maxDecibels = 100}) {
    if (gains.isEmpty) return [];
    var low = gains.reduce(min) - maxDecibels, high = gains.reduce(max) - minDecibels;
    for (var i = 0; i < 64; i++) {
      final offset = (low + high) / 2;
      final power =
          gains.fold<double>(0, (sum, gain) => sum + pow(10, (gain - offset).clamp(minDecibels, maxDecibels) / 10)) /
          gains.length;
      if (power > 1) {
        low = offset;
      } else {
        high = offset;
      }
    }
    return [for (final gain in gains) (gain - (low + high) / 2).clamp(minDecibels, maxDecibels).toDouble()];
  }

  static Future<void> previewTone(AndroidEqualizer equalizer, {required bool before}) {
    final generation = ++_previewGeneration;
    return _serial(() async {
      final parameters = await equalizer.parameters;
      if (generation != _previewGeneration) return;
      final correction = await loadSaved();
      final base = combine(correction?.curve ?? [], extraCurve);
      final tuned = combine(base, (await loadTone()).curve);
      final bands = [
        for (final band in parameters.bands) (band.lowerFrequency, band.centerFrequency, band.upperFrequency),
      ];
      List<double> gains(List<(double, double)> curve) => matchBandPower(
        bandGains(curve, bands, minDecibels: parameters.minDecibels, maxDecibels: parameters.maxDecibels),
        minDecibels: parameters.minDecibels,
        maxDecibels: parameters.maxDecibels,
      );
      final a = gains(base), b = gains(tuned);
      final pair = [a, b];
      final reserve = pair.map((side) => side.fold<double>(0, (sum, v) => sum + max(0, v))).reduce(max);
      if (generation != _previewGeneration) return;
      await _reserve(max(headroomDb, reserve));
      for (final (i, band) in parameters.bands.indexed) {
        await band.setGain(pair[before ? 0 : 1][i]);
      }
      await equalizer.setEnabled(true);
      await _reserve(reserve);
    });
  }

  static Future<void> endPreview(AndroidEqualizer equalizer) {
    _previewGeneration++;
    return refresh(equalizer);
  }

  static double headroomDb = 0;
  static Future<void> Function(double)? onHeadroomChanged;
  static Future<void> _reserve(double value) async {
    if ((headroomDb - value).abs() < 1e-9) return;
    headroomDb = value;
    await onHeadroomChanged?.call(value);
  }

  static List<HeadphoneProfile>? _index;

  /// A curve added on top of the headphone correction, like the genre EQ's. Empty for none.
  static List<(double, double)> extraCurve = const [];

  static final _indexLine = RegExp(r"^- \[(.+)\]\(\./(.+)\) by (.+?)(?: on .+)?$");

  /// All headphones AutoEQ has profiles for, cached on disk after the first download.
  static Future<List<HeadphoneProfile>> loadIndex() async {
    if (_index != null) return _index!;
    final cache = File("${(await getApplicationSupportDirectory()).path}/autoeq_index.md");
    String? markdown;
    try {
      final response = await http.get(Uri.parse("$_results/INDEX.md")).timeout(const Duration(seconds: 15));
      if (response.statusCode == 200) {
        markdown = utf8.decode(response.bodyBytes);
        await cache.writeAsString(markdown);
      }
    } catch (e) {
      _logger.warning("Failed to download AutoEQ index", e);
    }
    if (markdown == null && await cache.exists()) markdown = await cache.readAsString();
    if (markdown == null) throw Exception("Couldn't load the headphone list");
    return _index = parseIndex(markdown);
  }

  static List<HeadphoneProfile> parseIndex(String markdown) => [
    for (final line in markdown.split("\n"))
      if (_indexLine.firstMatch(line.trim()) case final match?)
        (name: match.group(1)!, path: Uri.decodeFull(match.group(2)!), source: match.group(3)!),
  ];

  /// Headphones whose name contains every word of [query].
  static List<HeadphoneProfile> search(List<HeadphoneProfile> index, String query) {
    final words = query.toLowerCase().split(RegExp(r"\s+")).where((word) => word.isNotEmpty).toList();
    if (words.isEmpty) return [];
    return index.where((profile) {
      final name = profile.name.toLowerCase();
      return words.every(name.contains);
    }).toList();
  }

  /// Parses an AutoEQ GraphicEQ file ("GraphicEQ: 20 -0.3; 21 -0.3; ...").
  static List<(double, double)> parseGraphicEq(String text) {
    final body = text.substring(text.indexOf(":") + 1);
    return [
      for (final point in body.split(";"))
        if (point.trim().split(RegExp(r"\s+")) case [final frequency, final gain])
          (double.parse(frequency), double.parse(gain)),
    ];
  }

  /// Downloads [profile]'s correction, applies it to [equalizer] and remembers it.
  static Future<HeadphoneCorrection> select(HeadphoneProfile profile, AndroidEqualizer equalizer) async {
    final folderName = profile.path.split("/").last;
    final segments = [...profile.path.split("/"), "$folderName GraphicEQ.txt"].map(Uri.encodeComponent);
    final url = Uri.parse("$_results/${segments.join("/")}");
    final response = await http.get(url).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) throw Exception("Couldn't download the profile (${response.statusCode})");
    final correction = (name: profile.name, path: profile.path, curve: parseGraphicEq(utf8.decode(response.bodyBytes)));
    final prefs = SharedPreferencesAsync();
    await prefs.setString(
      _prefsKey,
      jsonEncode({
        "name": correction.name,
        "path": correction.path,
        "curve": [
          for (final (frequency, gain) in correction.curve) [frequency, gain],
        ],
      }),
    );
    // The equalizer only becomes ready once something plays, so apply in the background instead of waiting.
    unawaited(refresh(equalizer).catchError((Object e) => _logger.warning("Failed to apply correction", e)));
    return correction;
  }

  /// The remembered correction, if any.
  static Future<HeadphoneCorrection?> loadSaved() async {
    final json = await SharedPreferencesAsync().getString(_prefsKey);
    if (json == null) return null;
    try {
      final map = jsonDecode(json) as Map<String, dynamic>;
      return (
        name: map["name"] as String,
        path: map["path"] as String,
        curve: [
          for (final point in (map["curve"] as List).cast<List<dynamic>>())
            ((point[0] as num).toDouble(), (point[1] as num).toDouble()),
        ],
      );
    } catch (e) {
      _logger.warning("Ignoring unreadable headphone correction", e);
      return null;
    }
  }

  /// Turns the correction off and forgets it.
  static Future<void> clear(AndroidEqualizer equalizer) async {
    await SharedPreferencesAsync().remove(_prefsKey);
    await refresh(equalizer);
  }

  /// Applies the saved correction together with [extraCurve], or turns the equalizer off when there's neither.
  static Future<void> refresh(AndroidEqualizer equalizer) {
    final generation = ++_previewGeneration;
    return _serial(() async {
      final correction = await loadSaved();
      final tone = await loadTone();
      if (correction == null && extraCurve.isEmpty && tone.bass == 0 && tone.warmth == 0 && tone.clarity == 0) {
        await equalizer.setEnabled(false);
        await _reserve(0);
        return;
      }
      final parameters = await equalizer.parameters;
      if (generation != _previewGeneration) return;
      await _setCurve(
        combine(combine(correction?.curve ?? const [], extraCurve), tone.curve),
        equalizer,
        parameters: parameters,
      );
    });
  }

  /// Adds two (frequency, gain) curves together, at every frequency either of them has a point.
  static List<(double, double)> combine(List<(double, double)> a, List<(double, double)> b) {
    if (a.isEmpty) return b;
    if (b.isEmpty) return a;
    final frequencies = {
      for (final (frequency, _) in [...a, ...b]) frequency,
    }.toList()..sort();
    return [for (final frequency in frequencies) (frequency, _interpolate(a, frequency) + _interpolate(b, frequency))];
  }

  /// Re-applies the remembered correction once the equalizer is ready.
  static Future<void> applySaved(AndroidEqualizer equalizer) async {
    try {
      await refresh(equalizer);
    } catch (e) {
      _logger.warning("Failed to apply headphone correction", e);
    }
  }

  static Future<void> _setCurve(
    List<(double, double)> curve,
    AndroidEqualizer equalizer, {
    AndroidEqualizerParameters? parameters,
  }) async {
    parameters ??= await equalizer.parameters;
    final gains = bandGains(
      curve,
      [for (final band in parameters.bands) (band.lowerFrequency, band.centerFrequency, band.upperFrequency)],
      minDecibels: parameters.minDecibels,
      maxDecibels: parameters.maxDecibels,
    );
    // Reserve positive band headroom before enabling the device effect, which
    // runs after the PCM limiter. Summing boosts is conservative for overlap.
    final reserve = gains.fold<double>(0, (total, gain) => total + max(0, gain));
    await _reserve(max(headroomDb, reserve));
    for (final (index, band) in parameters.bands.indexed) {
      await band.setGain(gains[index]);
    }
    await equalizer.setEnabled(true);
    await _reserve(reserve);
  }

  /// Fits [curve] to the device bands: each band gets the curve's average over its range (in log frequency),
  /// centred around 0 dB so the overall volume stays about the same, and clamped to what the device allows.
  static List<double> bandGains(
    List<(double, double)> curve,
    List<(double lower, double center, double upper)> bands, {
    required double minDecibels,
    required double maxDecibels,
  }) {
    if (curve.isEmpty || bands.isEmpty) return List.filled(bands.length, 0);
    final raw = [
      for (final (lower, center, upper) in bands)
        () {
          final inBand = [
            for (final (frequency, gain) in curve)
              if (frequency >= lower && frequency <= upper) gain,
          ];
          return inBand.isEmpty ? _interpolate(curve, center) : inBand.reduce((a, b) => a + b) / inBand.length;
        }(),
    ];
    final mean = raw.reduce((a, b) => a + b) / raw.length;
    return [for (final gain in raw) (gain - mean).clamp(minDecibels, maxDecibels).toDouble()];
  }

  static double _interpolate(List<(double, double)> curve, double frequency) {
    if (frequency <= curve.first.$1) return curve.first.$2;
    if (frequency >= curve.last.$1) return curve.last.$2;
    for (var i = 1; i < curve.length; i++) {
      final (f1, g1) = curve[i];
      if (f1 >= frequency) {
        final (f0, g0) = curve[i - 1];
        final t = (log(frequency) - log(f0)) / (log(f1) - log(f0));
        return g0 + (g1 - g0) * t;
      }
    }
    return 0;
  }
}
