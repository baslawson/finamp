import 'dart:async';

import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/analyzer_service.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:finamp/services/lrclib_service.dart';
import 'package:finamp/services/metadata_provider.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get_it/get_it.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// When to say a line between two songs, so it ends before the next song's vocals start ("hitting the post", as radio
/// hosts call it) instead of talking over the singing.
typedef DjIntroPlan = ({Duration beforeChange, Duration afterChange});

class DjIntroTiming {
  DjIntroTiming._();

  static const _enabledKey = 'djHitThePost';

  /// Room left between the end of the line and the first sung line.
  static const margin = Duration(milliseconds: 700);

  /// The longest the DJ waits into a long intro before starting, so the line still feels like an introduction.
  static const longestWait = Duration(seconds: 20);

  /// Vocal starts earlier than this aren't an intro worth timing to.
  static const shortestIntro = Duration(seconds: 2);

  /// The earliest a line starts before the next song, when that song's singing starts right away.
  static const longestLead = Duration(seconds: 25);

  static bool? _enabled;
  static final Map<String, Duration?> _cache = {};

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

  /// How long before the change of songs a line of [length] starts, and how far into the next song, given where its
  /// vocals start. Without [vocals], the line is centred on the change, as before. When the singing starts right away,
  /// the line is said over the end of this song instead, finishing as the next one comes in (starting at most
  /// [longestLead] before it).
  static DjIntroPlan plan(Duration length, {Duration? vocals}) {
    if (vocals == null) return (beforeChange: length ~/ 2, afterChange: Duration.zero);
    if (vocals < shortestIntro) {
      return (beforeChange: length > longestLead ? longestLead : length, afterChange: Duration.zero);
    }
    final post = vocals - margin;
    if (post >= length) {
      // The whole line fits in the intro: start late enough to end right before the singing.
      final wait = post - length;
      return (beforeChange: Duration.zero, afterChange: wait > longestWait ? longestWait : wait);
    }
    // Too long for the intro: start over the end of this song, so it still ends before the vocals.
    return (beforeChange: length - post, afterChange: Duration.zero);
  }

  /// How long before the end of the current song's file a line planned by [plan] starts, when the next song is heard
  /// [overlap] before that end (under a crossfade): [plan] counts from where the next song starts, not from the change
  /// of queue items. Zero or less means after the change, at [DjIntroPlan.afterChange] into the next song.
  static Duration startBeforeEnd(DjIntroPlan plan, {Duration overlap = Duration.zero}) =>
      overlap + plan.beforeChange - plan.afterChange;

  /// When the first sung line starts in synced [lines]; null without timed lines.
  static Duration? firstSungLine(List<LyricLine>? lines) {
    for (final line in lines ?? const <LyricLine>[]) {
      if (line.start == null) return null;
      final text = (line.text ?? '').replaceAll(RegExp(r'[♪♫\s]'), '');
      if (text.isNotEmpty) return Duration(microseconds: line.startMicros);
    }
    return null;
  }

  /// Where [item]'s vocals start: its synced lyrics (server, downloaded or LRCLIB), else where the analyzer measured
  /// the intro ending. Null when unknown or when timing is turned off. Never throws.
  static Future<Duration?> vocalStart(FinampQueueItem item, {Duration timeout = const Duration(seconds: 5)}) async {
    if (!await isEnabled()) return null;
    final json = item.item.extras?["itemJson"];
    final id = json is Map ? json["Id"] as String? : null;
    if (id == null) return null;
    if (_cache.containsKey(id)) return _cache[id];
    Duration? found;
    // A slow or failed lookup isn't remembered, so the song's lyrics can still be used next time it comes up.
    var settled = true;
    try {
      found = await _fromLyrics(item.baseItem).timeout(
        timeout,
        onTimeout: () {
          settled = false;
          return null;
        },
      );
    } catch (_) {
      // Lyrics are optional here.
      settled = false;
    }
    if (found == null) {
      final intro = AnalyzerService.cached(id)?.intro;
      if (intro != null && intro > 0) found = Duration(milliseconds: (intro * 1000).round());
    }
    if (!settled && found == null) return null;
    if (_cache.length > 200) _cache.remove(_cache.keys.first);
    return _cache[id] = found;
  }

  static Future<Duration?> _fromLyrics(BaseItemDto item) async {
    if (!GetIt.instance.isRegistered<ProviderContainer>()) return null;
    final container = GetIt.instance<ProviderContainer>();
    // Listening keeps the auto-disposed lyrics alive while they load; the player screen shares the same cache.
    final metadataListener = container.listen(metadataProvider(item), (_, _) {});
    try {
      final metadata = await container.read(metadataProvider(item).future);
      final fromServer = firstSungLine(metadata?.lyrics?.lyrics);
      if (fromServer != null || metadata?.lyrics != null) return fromServer;
      final offline = Hive.isBoxOpen('FinampSettings') && FinampSettingsHelper.finampSettings.isOffline;
      if (offline) return null;
      final lrclibListener = container.listen(lrclibLyricsProvider(metadata?.item ?? item), (_, _) {});
      try {
        return firstSungLine((await container.read(lrclibLyricsProvider(metadata?.item ?? item).future))?.lyrics);
      } finally {
        lrclibListener.close();
      }
    } finally {
      metadataListener.close();
    }
  }

  @visibleForTesting
  static void reset() {
    _enabled = null;
    _cache.clear();
  }
}
