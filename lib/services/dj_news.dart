import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xml/xml.dart';

/// When the DJ reads the news.
enum DjNewsMode {
  off,

  /// A short bulletin in the first announcement of each hour, like radio news at the top of the hour.
  onTheHour,

  /// One headline in about one announcement in five.
  nowAndThen,
}

/// A news feed the DJ can read headlines from: world news, or news of one country or nation, as for a second feed
/// of local news.
enum DjNewsFeed {
  bbcWorld('BBC News', 'https://feeds.bbci.co.uk/news/world/rss.xml'),
  bbcUk('BBC News', 'https://feeds.bbci.co.uk/news/uk/rss.xml'),
  bbcAustralia('BBC News', 'https://feeds.bbci.co.uk/news/world/australia/rss.xml'),
  guardianWorld('The Guardian', 'https://www.theguardian.com/world/rss'),
  nprWorld('NPR', 'https://feeds.npr.org/1004/rss.xml'),
  alJazeera('Al Jazeera', 'https://www.aljazeera.com/xml/rss/all.xml'),
  abcAustralia('ABC News', 'https://www.abc.net.au/news/feed/45910/rss.xml'),
  bbcEngland('BBC News', 'https://feeds.bbci.co.uk/news/england/rss.xml'),
  bbcScotland('BBC News', 'https://feeds.bbci.co.uk/news/scotland/rss.xml'),
  bbcWales('BBC News', 'https://feeds.bbci.co.uk/news/wales/rss.xml'),
  bbcNorthernIreland('BBC News', 'https://feeds.bbci.co.uk/news/northern_ireland/rss.xml'),
  guardianUk('The Guardian', 'https://www.theguardian.com/uk-news/rss'),
  guardianAustralia('The Guardian', 'https://www.theguardian.com/australia-news/rss'),
  guardianUs('The Guardian', 'https://www.theguardian.com/us-news/rss'),
  nprNational('NPR', 'https://feeds.npr.org/1003/rss.xml'),
  abcJustIn('ABC News', 'https://www.abc.net.au/news/feed/51120/rss.xml'),
  sbsAustralia('SBS News', 'https://www.sbs.com.au/news/topic/australia/feed'),
  rnzNational('RNZ', 'https://www.rnz.co.nz/rss/national.xml'),
  cbcCanada('CBC News', 'https://www.cbc.ca/webfeed/rss/rss-canada'),
  rteNews('RTÉ News', 'https://www.rte.ie/feeds/rss/?index=/news/'),
  custom('', '');

  const DjNewsFeed(this.source, this.url);

  /// The feed's name (the DJ doesn't say it).
  final String source;
  final String url;
}

/// How the DJ reads the news.
enum DjNewsStyle {
  /// Like a radio newsreader: natural and warm, out of character.
  newsreader,

  /// In the DJ's own character, lightly, the facts kept exact.
  inCharacter,
}

/// The news settings: [pause] stops the music while news is read, between songs; [detail] adds a sentence of what
/// happened to each headline, from the feed's summary; [sting] plays a short chime before the news. [second] is a
/// feed of local news read as well, if any ([secondCustom] its address when it's the listener's own).
typedef DjNewsSettings = ({
  DjNewsMode mode,
  DjNewsFeed feed,
  String custom,
  DjNewsFeed? second,
  String secondCustom,
  int count,
  bool gentle,
  bool pause,
  bool detail,
  DjNewsStyle style,
  bool sting,
});

/// A story in a feed: its headline, and the feed's summary of it (empty when there's none).
typedef DjNewsStory = ({String headline, String summary});

/// Headlines for one announcement, each from the feed named in [sources], with the summary of each in [summaries]
/// (empty when there's none), read out too when [detail] is on; kept either way, as what makes a story upsetting may
/// be in its summary. The last [local] are from the second feed, of local news. [gentle] when upsetting stories are to
/// be left out. [playsAt] is when the announcement is expected to be heard.
typedef DjNewsBulletin = ({
  List<String> sources,
  List<String> headlines,
  int local,
  List<String> summaries,
  bool detail,
  bool gentle,
  DateTime playsAt,
});

/// Top news headlines for the DJ, only when the listener turns them on. They're fetched straight from the chosen
/// feed (nothing about the listener is sent), cached for half an hour and refreshed in the background, so a DJ line
/// never waits on the network. Headlines already read out are remembered for a day.
class DjNews {
  DjNews._();

  static final _logger = Logger('DjNews');
  static const _modeKey = 'djNewsMode';
  static const _feedKey = 'djNewsFeed';
  static const _customKey = 'djNewsCustomFeed';
  static const _secondKey = 'djNewsSecondFeed';
  static const _secondCustomKey = 'djNewsSecondCustomFeed';
  static const _countKey = 'djNewsCount';
  static const _gentleKey = 'djNewsGentle';
  static const _pauseKey = 'djNewsPause';
  static const _detailKey = 'djNewsDetail';
  static const _styleKey = 'djNewsStyle';
  static const _stingKey = 'djNewsSting';
  static const _spokenKey = 'djNewsSpoken';
  static const _lastKey = 'djNewsLast';
  static const _localNextKey = 'djNewsLocalNext';
  static const _life = Duration(minutes: 30);
  static const _retryAfter = Duration(minutes: 5);
  static const _remember = Duration(days: 1);
  static const _stale = Duration(hours: 3);

  /// How likely an announcement is to carry a headline in [DjNewsMode.nowAndThen], and how long at least between two.
  static const nowAndThenChance = 0.2;
  static const nowAndThenGap = Duration(minutes: 15);

  static DjNewsSettings? _settings;

  /// Each chosen feed's stories, by its address, and when they were fetched.
  static final Map<String, ({List<DjNewsStory> stories, DateTime at})> _cache = {};
  static final Map<String, Future<List<DjNewsStory>>> _fetching = {};

  /// With a second feed, whether a lone headline comes from it next: the two take turns.
  static bool _secondNext = false;

  /// With a second feed, whether a lone headline read from an update should be its local one.
  static bool get localNext => _secondNext;
  static Map<String, DateTime>? _spoken;
  static DateTime? _last;

  // Headlines in a line written but not heard yet (lines are written ahead), and when: not offered again meanwhile.
  // A line that's never heard (skipped, dropped) frees its headlines after [_heldFor].
  static final Map<String, DateTime> _held = {};
  static const _heldFor = Duration(minutes: 10);

  @visibleForTesting
  static DateTime Function() now = DateTime.now;

  @visibleForTesting
  static Random random = Random();

  @visibleForTesting
  static Future<http.Response> Function(Uri url) get = (url) => http.get(url, headers: {'User-Agent': 'Finamp+'});

  static Future<DjNewsSettings> settings() async {
    if (_settings case final settings?) return settings;
    try {
      final prefs = SharedPreferencesAsync();
      final mode = await prefs.getString(_modeKey);
      final feed = await prefs.getString(_feedKey);
      final second = await prefs.getString(_secondKey);
      final style = await prefs.getString(_styleKey);
      return _settings = (
        mode: DjNewsMode.values.firstWhere((value) => value.name == mode, orElse: () => DjNewsMode.off),
        feed: DjNewsFeed.values.firstWhere((value) => value.name == feed, orElse: () => DjNewsFeed.bbcWorld),
        custom: await prefs.getString(_customKey) ?? '',
        second: DjNewsFeed.values.firstWhereOrNull((value) => value.name == second),
        secondCustom: await prefs.getString(_secondCustomKey) ?? '',
        count: await prefs.getInt(_countKey) == 3 ? 3 : 1,
        gentle: await prefs.getBool(_gentleKey) ?? true,
        pause: await prefs.getBool(_pauseKey) ?? false,
        detail: await prefs.getBool(_detailKey) ?? true,
        style: DjNewsStyle.values.firstWhere((value) => value.name == style, orElse: () => DjNewsStyle.newsreader),
        sting: await prefs.getBool(_stingKey) ?? true,
      );
    } catch (_) {
      return (
        mode: DjNewsMode.off,
        feed: DjNewsFeed.bbcWorld,
        custom: '',
        second: null,
        secondCustom: '',
        count: 1,
        gentle: true,
        pause: false,
        detail: true,
        style: DjNewsStyle.newsreader,
        sting: true,
      );
    }
  }

  /// [noSecond] takes the second feed away.
  static Future<void> save({
    DjNewsMode? mode,
    DjNewsFeed? feed,
    String? custom,
    DjNewsFeed? second,
    bool noSecond = false,
    String? secondCustom,
    int? count,
    bool? gentle,
    bool? pause,
    bool? detail,
    DjNewsStyle? style,
    bool? sting,
  }) {
    // One after another, so two controls changed at once both keep their change, and a failed save doesn't stop later
    // ones.
    final saved = _saving.then(
      (_) => _save(
        mode: mode,
        feed: feed,
        custom: custom,
        second: second,
        noSecond: noSecond,
        secondCustom: secondCustom,
        count: count,
        gentle: gentle,
        pause: pause,
        detail: detail,
        style: style,
        sting: sting,
      ),
    );
    _saving = saved.catchError((Object _) {});
    return saved;
  }

  static Future<void> _saving = Future.value();

  static Future<void> _save({
    DjNewsMode? mode,
    DjNewsFeed? feed,
    String? custom,
    DjNewsFeed? second,
    required bool noSecond,
    String? secondCustom,
    int? count,
    bool? gentle,
    bool? pause,
    bool? detail,
    DjNewsStyle? style,
    bool? sting,
  }) async {
    final current = await settings();
    final next = (
      mode: mode ?? current.mode,
      feed: feed ?? current.feed,
      custom: (custom ?? current.custom).trim(),
      second: noSecond ? null : second ?? current.second,
      secondCustom: (secondCustom ?? current.secondCustom).trim(),
      count: count ?? current.count,
      gentle: gentle ?? current.gentle,
      pause: pause ?? current.pause,
      detail: detail ?? current.detail,
      style: style ?? current.style,
      sting: sting ?? current.sting,
    );
    _settings = next;
    _cache.removeWhere((url, _) => !_urlsOf(next).contains(url));
    final prefs = SharedPreferencesAsync();
    await prefs.setString(_modeKey, next.mode.name);
    await prefs.setString(_feedKey, next.feed.name);
    await prefs.setString(_customKey, next.custom);
    await prefs.setString(_secondKey, next.second?.name ?? '');
    await prefs.setString(_secondCustomKey, next.secondCustom);
    await prefs.setInt(_countKey, next.count);
    await prefs.setBool(_gentleKey, next.gentle);
    await prefs.setBool(_pauseKey, next.pause);
    await prefs.setBool(_detailKey, next.detail);
    await prefs.setString(_styleKey, next.style.name);
    await prefs.setBool(_stingKey, next.sting);
  }

  /// The address of [settings]' main feed, or with [second], of its second feed ('' when there's none).
  static String _urlOf(DjNewsSettings settings, {bool second = false}) =>
      switch (second ? settings.second : settings.feed) {
        null => '',
        DjNewsFeed.custom => second ? settings.secondCustom : settings.custom,
        final feed => feed.url,
      };

  static Set<String> _urlsOf(DjNewsSettings settings) => {_urlOf(settings), _urlOf(settings, second: true)}..remove('');

  /// The name of [settings]' main (or [second]) feed: its own, or the custom feed's website.
  static String _sourceOf(DjNewsSettings settings, {bool second = false}) {
    final feed = second ? settings.second : settings.feed;
    if (feed == null) return '';
    if (feed != DjNewsFeed.custom) return feed.source;
    final host = Uri.tryParse(second ? settings.secondCustom : settings.custom)?.host ?? '';
    return host.startsWith('www.') ? host.substring(4) : host;
  }

  /// The chosen feeds' names as last loaded, the main feed's first; none before the settings are read.
  static List<String> get sources => switch (_settings) {
    final settings? => [_sourceOf(settings), if (settings.second != null) _sourceOf(settings, second: true)],
    null => const [],
  };

  /// Whether news is on, as last loaded (it is once a line has looked for news).
  static bool get isOn => (_settings?.mode ?? DjNewsMode.off) != DjNewsMode.off;

  /// Whether the music pauses while news is read, as last loaded.
  static bool get pausesMusic => _settings?.pause ?? false;

  /// Whether upsetting stories are being left out, as last loaded.
  static bool get gentle => _settings?.gentle ?? true;

  /// How the news is read, as last loaded.
  static DjNewsStyle get style => _settings?.style ?? DjNewsStyle.newsreader;

  /// Whether a chime plays before the news, as last loaded.
  static bool get sting => _settings?.sting ?? true;

  /// Headlines for this announcement, or null when none are due: news is off, it isn't time yet, or every headline
  /// has been read already. Never waits on the network: until the feed has been fetched once, there are none.
  /// [ahead] is how long until the announcement is heard, as lines are written ahead: the hour is the one it plays in.
  static Future<DjNewsBulletin?> due({Duration ahead = Duration.zero}) async {
    final current = await settings();
    if (current.mode == DjNewsMode.off) return null;
    await _loadMemory();
    final time = now();
    final playsAt = time.add(ahead);
    _held.removeWhere((_, at) => time.difference(at) >= _heldFor);
    _spoken!.removeWhere((_, at) => time.difference(at) > _remember);
    // News already read and news waiting to be heard both count: a bulletin held for the next hour doesn't hide one
    // read this hour.
    final times = [?_last, ..._held.values];
    DateTime hourOf(DateTime at) => DateTime(at.year, at.month, at.day, at.hour);
    final isDue = switch (current.mode) {
      DjNewsMode.off => false,
      DjNewsMode.onTheHour => !times.any((at) => hourOf(at) == hourOf(playsAt)),
      DjNewsMode.nowAndThen =>
        times.every((at) => playsAt.difference(at).abs() >= nowAndThenGap) && random.nextDouble() < nowAndThenChance,
    };
    if (!isDue) return null;
    // Not a story already read or waiting, even reworded since.
    final told = [..._spoken!.keys, ..._held.keys];
    List<({DjNewsStory story, String key})> freshIn(List<DjNewsStory> stories, String source) => [
      for (final story in stories)
        // A calm headline over an upsetting story counts as upsetting too. Not news, either, the publisher asking
        // readers in ("post your questions for the Guardian's correspondent"), or nothing once its credit is off.
        if (!(current.gentle && (upsetting(story.headline) || upsetting(story.summary))) &&
            !callOut(story.headline) &&
            unattributed(story.headline, source).isNotEmpty)
          if (_storyKey(story.headline, source) case final key when !told.any((other) => sameStory(key, other)))
            (story: story, key: key),
    ];

    final source = _sourceOf(current), localSource = _sourceOf(current, second: true);
    final world = freshIn(await stories(waitForFirst: false), source);
    final local = current.second == null
        ? const <({DjNewsStory story, String key})>[]
        : freshIn(await stories(waitForFirst: false, second: true), localSource);
    final count = current.mode == DjNewsMode.onTheHour ? current.count : 1;
    // Never two headlines about one story, from one feed or both.
    final picked = <({DjNewsStory story, String key})>[];
    final pickedLocal = <({DjNewsStory story, String key})>[];
    void take(
      List<({DjNewsStory story, String key})> from,
      List<({DjNewsStory story, String key})> into,
      int upTo, {
      List<({DjNewsStory story, String key})> notAs = const [],
    }) {
      for (final candidate in from) {
        if (into.length >= upTo || picked.length + pickedLocal.length >= count) break;
        if ([...picked, ...pickedLocal, ...into, ...notAs].any((other) => sameStory(candidate.key, other.key))) {
          continue;
        }
        into.add(candidate);
      }
    }

    // An update is world news, then one story closer to home; a lone headline is from each feed in turn. When one has
    // nothing new, the other has the room. The local story isn't one of the world stories read with it: one in both
    // feeds is world news.
    if (count > 1 || _secondNext || world.isEmpty) {
      final readWith = <({DjNewsStory story, String key})>[];
      take(world, readWith, count - 1);
      take(local, pickedLocal, 1, notAs: readWith);
    }
    take(world, picked, count);
    take(local, pickedLocal, count);
    if (picked.isEmpty && pickedLocal.isEmpty) return null;
    final all = [...picked, ...pickedLocal];
    return (
      sources: [for (var at = 0; at < all.length; at++) at < picked.length ? source : localSource],
      headlines: [for (final chosen in all) chosen.story.headline],
      local: pickedLocal.length,
      summaries: [for (final chosen in all) chosen.story.summary],
      detail: current.detail,
      gentle: current.gentle,
      playsAt: playsAt,
    );
  }

  /// Holds [bulletin]'s headlines while the line carrying them waits to be heard, so the next line doesn't repeat them.
  static void hold(DjNewsBulletin bulletin) {
    for (final (index, headline) in bulletin.headlines.indexed) {
      _held[_storyKey(headline, bulletin.sources[index])] = bulletin.playsAt;
    }
  }

  /// Remembers that [bulletin] was read out, so it isn't read again today, and when.
  static Future<void> markSpoken(DjNewsBulletin bulletin) async {
    await _loadMemory();
    final time = now();
    // An update written for the next hour that started a few seconds early still counts for that hour.
    _last = bulletin.playsAt.isAfter(time) ? bulletin.playsAt : time;
    if (bulletin.headlines.length == 1) _secondNext = bulletin.local == 0;
    for (final (index, headline) in bulletin.headlines.indexed) {
      _held.remove(_storyKey(headline, bulletin.sources[index]));
      _spoken![_storyKey(headline, bulletin.sources[index])] = time;
    }
    _spoken!.removeWhere((_, at) => time.difference(at) > _remember);
    try {
      final prefs = SharedPreferencesAsync();
      await prefs.setStringList(_spokenKey, [
        for (final entry in _spoken!.entries) '${entry.value.millisecondsSinceEpoch}|${entry.key}',
      ]);
      await prefs.setInt(_lastKey, _last!.millisecondsSinceEpoch);
      await prefs.setBool(_localNextKey, _secondNext);
    } catch (e) {
      _logger.info("Couldn't save the news already read: $e");
    }
  }

  static Future<void> _loadMemory() async {
    if (_spoken != null) return;
    final spoken = <String, DateTime>{};
    try {
      final prefs = SharedPreferencesAsync();
      for (final entry in await prefs.getStringList(_spokenKey) ?? const <String>[]) {
        final split = entry.indexOf('|');
        final at = int.tryParse(split < 0 ? '' : entry.substring(0, split));
        if (at != null) spoken[entry.substring(split + 1)] = DateTime.fromMillisecondsSinceEpoch(at);
      }
      final last = await prefs.getInt(_lastKey);
      if (last != null) _last ??= DateTime.fromMillisecondsSinceEpoch(last);
      _secondNext = await prefs.getBool(_localNextKey) ?? false;
    } catch (_) {
      // Only means a headline could be read again.
    }
    _spoken ??= spoken;
  }

  /// [text] (a headline or summary) without its publisher's credit, as the DJ doesn't say where news is from:
  /// "… - BBC News", "… (Reuters)", "BBC News reports that …", "LONDON (Reuters) - …", for [source] and other news
  /// organisations' names. A name that's part of the story itself ("BBC chief resigns") stays. '' when [text] only
  /// pointed to the publisher's pages.
  static String unattributed(String text, String source) {
    final name = _namesOf(source);
    final patterns = <(RegExp, String Function(Match))>[
      // At the end: " - BBC News", " | Al Jazeera", " (Reuters).", "- BBC News Online"; the sentence's full stop stays.
      (
        RegExp(
          '\\s*(?:[-–—|]\\s*$name(?:\\s+(?:online|live))?|\\(\\s*$name\\s*\\))\\s*([.!?]?)\\s*\$',
          caseSensitive: false,
        ),
        (match) => match[1]!,
      ),
      // Within: ", according to Reuters", and at the end of any sentence ", the BBC has learned."
      (
        RegExp(
          ',?\\s+according to (?:the\\s+)?$name(?:\\s+(?:online|live))?(?=\\s*[.,;:!?]|\\s*\$)',
          caseSensitive: false,
        ),
        (_) => '',
      ),
      // Who someone spoke to: "The minister told the BBC that …" is "The minister said that …", "told BBC Radio 4's
      // Today programme" all of it. Only a station or programme is taken with it, so "told the BBC Britain would …"
      // keeps Britain and "told the BBC's reporter" stays. Who was told is taken whole or not at all (an atomic group):
      // "tells BBC News to …" isn't "tells BBC" and "News to …", nor "tells BBC Radio Scotland to …" "BBC Radio" and
      // "Scotland to …". A few station words at most, each read one way only, so a long run of them can't take the
      // matcher ages; after a station's number only the words that go with one ("5 Live", "4 Extra"), as "told BBC
      // Radio 4 Britain would …" goes on with what was said.
      (
        RegExp(
          '\\b([Tt]old|[Tt]ells|[Tt]ell)\\s+(?=(?<recipient>(?:the\\s+)?$name(?:\\s+(?:Radio(?:\\s+(?:\\d+(?:\\s+(?:Live|Extra|Music|Xtra)\\b)?|(?!(?:Radio|World|Breakfast|Newsnight|Sport)\\b)\\p{Lu}\\p{L}*))?|World Service|Breakfast|Newsnight|Sport)){0,3}'
          '(?:[\'’]s(?:\\s+(?:\\p{Lu}[\\p{L}\\p{N}]*|\\d+|at|with|and|of|the|in|on|for)){1,8}?'
          '\\s+(?:programme|program|show|podcast))?))\\k<recipient>'
          // Not part of one: "told BBC Radio 4's World at One" with no "programme" stays whole. Nor one told to do
          // something, or told of something of theirs, as the story is about them then: "Judge tells the BBC to pay
          // damages", "Government tells ABC its funding will be cut".
          '(?![\\p{L}\\p{N}\'’])(?!\\s+(?:\\d|Radio\\b|World Service|Breakfast|Newsnight|Sport\\b))'
          '(?!\\s+(?:(?:not\\s+)?to|it|its|it[\'’]s|they|their|them)\\b)'
          // Nor when what follows could be the rest of a name this doesn't know: "tells BBC Radio 5 Live to …".
          '(?!\\s+\\p{Lu}\\p{L}*\\s+(?:(?:not\\s+)?to|it|its|it[\'’]s|they|their|them)\\b)',
          unicode: true,
        ),
        (match) => switch (match[1]!.toLowerCase()) {
          'told' => 'said',
          'tells' => 'says',
          _ => 'say',
        },
      ),
      (
        RegExp(
          ',\\s*(?:the\\s+)?$name\\s+(?:reports|reported|says|said|has learned|has been told|understands|can reveal)'
          '(?=\\s*(?:[.!?](?:\\s|\$)|\$))',
          caseSensitive: false,
        ),
        (_) => '',
      ),
      // At the start: "According to Reuters,", "BBC News reports that", "NPR: ". "BBC reports record losses" and
      // "The BBC has learned lessons" are about the BBC, so these need a "that" or a colon to be a credit.
      (RegExp('^\\s*according to (?:the\\s+)?$name\\s*,?\\s+', caseSensitive: false), (_) => ''),
      // A reporter's introduction, "NPR's Leila Fadel speaks with …": the reporter's name and what they do stay.
      // "BBC's Director General resigns" is about the BBC.
      (
        RegExp(
          '^\\s*(?:the\\s+)?$name[\'’]s\\s+(?=\\p{Lu}\\p{L}+(?:\\s+\\p{Lu}[\\p{L}\'’-]+){1,2}\\s+'
          '(?:speaks|spoke|talks|talked|reports|reported|asks|asked|explains|looks|visits|visited|joins|interviews|'
          'interviewed|sits down|sat down)\\b)',
          unicode: true,
        ),
        (_) => '',
      ),
      (
        RegExp(
          '^\\s*(?:the\\s+)?$name\\s+(?:reports|says|reveals|has learned|has been told|understands|can reveal)'
          '(?:\\s+that\\b|\\s*:)[,:]?\\s*',
          caseSensitive: false,
        ),
        (_) => '',
      ),
      (RegExp('^\\s*$name\\s*[:|–—]\\s*', caseSensitive: false), (_) => ''),
      // A dateline, "LONDON (Reuters) - ": capitals only and a dash or colon after it, so "British Broadcasting
      // Corporation (BBC) announces …" stays.
      (RegExp('^(?:\\p{Lu}[\\p{Lu}\\s,.\'’-]*)?\\(\\s*$name\\s*\\)\\s*[-–—:]\\s*', unicode: true), (_) => ''),
    ];
    final words = RegExp(r'[\p{L}\p{N}]', unicode: true);
    // An invitation to the publisher's own pages, "Follow the day's events on the ABC News live blog.", goes
    // whole (not a label, "Watch: BBC drama wins award"); if that was all of it, there's nothing to say.
    var out = text
        .trim()
        .replaceAll(
          RegExp(
            '(?:^|(?<=[.!?])\\s+)(?:Follow|Read|Watch|Listen to|Sign up|Get)\\b(?!\\s*:)[^.!?]*'
            '(?<![\\p{L}\\p{N}])$name(?![\\p{L}\\p{N}])[^.!?]*(?:[.!?]|\$)',
            unicode: true,
          ),
          '',
        )
        .trim();
    if (!words.hasMatch(out)) return '';
    for (final (pattern, replace) in patterns) {
      final next = out.replaceAllMapped(pattern, replace).trim();
      // Never down to nothing, or just punctuation: then it was all name.
      if (words.hasMatch(next)) out = next;
    }
    return out == text.trim() || out.isEmpty ? out : out[0].toUpperCase() + out.substring(1);
  }

  /// Whether [text] names a news organisation (the feeds', [source] or another's) at all, as a word, or credits one
  /// the way older versions did ("In the news from example.com:").
  /// Whether [text] names a news organisation: any, or one of [sources].
  static bool namesAnyNews(String text, Iterable<String> sources) =>
      sources.isEmpty ? namesNews(text) : sources.any((source) => namesNews(text, source));

  static bool namesNews(String text, [String source = '']) =>
      RegExp('(?<![\\p{L}\\p{N}])${_namesOf(source)}(?![\\p{L}\\p{N}])', unicode: true).hasMatch(text) ||
      RegExp(r'\b(?:the news|the latest),? from\s', caseSensitive: false).hasMatch(text);

  /// A pattern for any news organisation's name: [source], the feeds' and other publishers', longest first.
  static String _namesOf(String source) {
    final names = {source, for (final feed in DjNewsFeed.values) feed.source, ..._publishers}
      ..removeWhere((name) => name.trim().isEmpty);
    return '(?:${(names.toList()..sort((a, b) => b.length.compareTo(a.length))).map(RegExp.escape).join('|')})';
  }

  /// News organisations other than the feeds' own whose credit feeds carry.
  static const _publishers = [
    'BBC',
    'BBC World Service',
    'Reuters',
    'AP',
    'Associated Press',
    'AFP',
    'Guardian',
    'NPR News',
    'ABC',
    'CNN',
    'Sky News',
  ];

  /// What [headline] from [source] is told apart from other stories by: its words, without the publisher's credit, so
  /// one story in two feeds is one story.
  static String _storyKey(String headline, String source) => switch (unattributed(headline, source)) {
    '' => _keyOf(headline),
    final told => _keyOf(told),
  };

  static String _keyOf(String headline) =>
      headline.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ').trim();

  /// Whether two headlines (as [_keyOf] keys) tell the same story: the same words, or a rewording of the same telling
  /// words (names, places, what happened), give or take a few added: "Floods force thousands from homes in Valencia"
  /// and "Valencia floods: thousands forced from homes" do. Headlines that each have words the other lacks ("Bank of
  /// Canada cuts interest rates", "Bank of England cuts interest rates") are kept apart, as that's how a different
  /// story with the same wording reads: a rewording with other words in it is rarely read twice, but no story is left
  /// out for one that only looks like it.
  @visibleForTesting
  static bool sameStory(String a, String b) {
    if (a == b) return true;
    final first = _tellingWords(a), second = _tellingWords(b);
    if (first.intersection(second).length < 3) return false;
    // Every word but the small ones, short names too ("UK cuts interest rates" isn't "Canada cuts interest rates").
    final all = _words(a), other = _words(b);
    return all.containsAll(other) || other.containsAll(all);
  }

  static Set<String> _words(String key) => {
    for (final word in key.split(' '))
      if (word.isNotEmpty && !_smallWords.contains(word) && !_commonWords.contains(word)) _stem(word),
  };

  static const _smallWords = {
    'a',
    'an',
    'and',
    'as',
    'at',
    'be',
    'by',
    'for',
    'in',
    'is',
    'it',
    'of',
    'on',
    'or',
    'the',
    'to',
    'was',
    'with',
  };

  static Set<String> _tellingWords(String key) => {
    for (final word in key.split(' '))
      if (word.length >= 4 && !_commonWords.contains(word)) _stem(word),
  };

  // Plural and tense endings, so "floods" matches "flood" and "forced" matches "force".
  static String _stem(String word) {
    var stem = word;
    for (final ending in const ['ing', 'ed', 'es', 's']) {
      if (stem.length - ending.length >= 4 && stem.endsWith(ending)) {
        stem = stem.substring(0, stem.length - ending.length);
        break;
      }
    }
    return stem.length >= 5 && stem.endsWith('e') ? stem.substring(0, stem.length - 1) : stem;
  }

  static const _commonWords = {
    'about',
    'after',
    'again',
    'against',
    'amid',
    'before',
    'being',
    'from',
    'have',
    'into',
    'just',
    'more',
    'most',
    'news',
    'over',
    'says',
    'said',
    'than',
    'that',
    'their',
    'there',
    'they',
    'this',
    'what',
    'when',
    'where',
    'which',
    'while',
    'will',
    'with',
    'would',
    'year',
    'years',
    'live',
    'latest',
    'update',
    'week',
    'first',
    'last',
    'could',
    'some',
    'also',
    'were',
    'been',
    'make',
    'made',
    'calls',
    'call',
    'back',
    'under',
    'next',
    'still',
  };

  /// Words that mark a headline as upsetting, left out while "Skip upsetting stories" is on. The DJ is also asked to
  /// skip any it still finds upsetting; without the writer (the phone's voice), this list is the only check, so it
  /// errs on the side of leaving stories out: crime, courts, conflict and disasters.
  static final _upsetting = RegExp(
    r"\b(kill\w*|dead|deadly|death\w*|die|dies|died|dying|fatal\w*|murder\w*|shoot\w*|shot|gunm[ae]n|stab\w*|attack\w*|bomb\w*|blast|"
    r"explosion|war|wars|warfare|missile\w*|airstrikes?|strikes? on|massacre\w*|genocide|terror\w*|hostages?|"
    r"rape\w*|abuse\w*|assault\w*|crash\w*|disaster\w*|earthquake\w*|flood\w*|wildfire\w*|famine|starv\w*|"
    r"injur\w*|wounded|victims?|casualt\w*|suicide|overdose|epidemic|outbreak|ebola|cholera|jail\w*|prison\w*|"
    r"sentenced|convicted|charged|arrest\w*|accused|trial|court|sex\w*|paedophil\w*|pedophil\w*|offences?|offenses?|"
    r"crime\w*|criminal\w*|police|violen\w*|riot\w*|clash\w*|fighting|troops|invasion|siege|conflict\w*|"
    r"refugees?|missing|drown\w*|fire|fires|collapse\w*|hurricane\w*|typhoon\w*|cyclone\w*|tornado\w*|tsunami\w*|"
    r"evacuat\w*)\b",
    caseSensitive: false,
  );

  static bool upsetting(String headline) => _upsetting.hasMatch(headline);

  /// Whether [headline] asks readers in rather than telling news: "post your questions for …", "tell us …".
  static bool callOut(String headline) => _callOut.hasMatch(headline);

  static final _callOut = RegExp(
    r"\b(?:post|send|submit|share)\s+(?:us\s+)?your\s+(?:questions?|stories|story|views|experiences?|photos?|videos?|"
    r"thoughts)\b|\btell us\b|\bhave your say\b",
    caseSensitive: false,
  );

  /// The main (or [second]) feed's current headlines, as [stories].
  static Future<List<String>> headlines({bool waitForFirst = true, bool second = false}) async => [
    for (final story in await stories(waitForFirst: waitForFirst, second: second)) story.headline,
  ];

  /// The feed's current stories, cached for half an hour. Once known, older ones are answered straight away while
  /// they're refreshed in the background. With [waitForFirst] false, nothing is waited for: before the first fetch
  /// has finished there are none.
  static Future<List<DjNewsStory>> stories({bool waitForFirst = true, bool second = false}) async {
    final url = _urlOf(await settings(), second: second);
    if (Uri.tryParse(url)?.hasScheme != true) return const [];
    final cached = _cache[url];
    if (cached != null) {
      final age = now().difference(cached.at);
      if (age < (cached.stories.isEmpty ? _retryAfter : _life)) return cached.stories;
      // News more than a few hours old isn't offered while it's refreshed, e.g. after a night asleep.
      if (cached.stories.isNotEmpty && age < _stale) {
        unawaited(_refresh(url));
        return cached.stories;
      }
    }
    final fetching = _refresh(url);
    return waitForFirst ? fetching : const [];
  }

  /// Starts fetching the headlines if news is on, e.g. when the DJ starts, so the first bulletin has them.
  static void prefetch() {
    unawaited(
      settings().then<void>((current) async {
        if (current.mode == DjNewsMode.off) return;
        await stories(waitForFirst: false);
        if (current.second != null) await stories(waitForFirst: false, second: true);
      }, onError: (Object _) {}),
    );
  }

  /// One fetch at a time for each feed; a fetch for a feed no longer chosen doesn't answer for the new one.
  static Future<List<DjNewsStory>> _refresh(String url) {
    if (_fetching[url] case final pending?) return pending;
    late final Future<List<DjNewsStory>> future;
    future = _fetch(url).whenComplete(() {
      if (identical(_fetching[url], future)) _fetching.remove(url);
    });
    return _fetching[url] = future;
  }

  static Future<List<DjNewsStory>> _fetch(String url) async {
    var result = const <DjNewsStory>[];
    try {
      final response = await get(Uri.parse(url)).timeout(const Duration(seconds: 8));
      // Feeds are UTF-8 unless the server says otherwise; http would read an unlabelled one as Latin-1.
      final labelled = response.headers['content-type']?.toLowerCase().contains('charset=') ?? false;
      final body = labelled ? response.body : utf8.decode(response.bodyBytes, allowMalformed: true);
      if (response.statusCode == 200) result = parseStories(body);
    } catch (e) {
      _logger.info("Couldn't get the news (${e.runtimeType})");
    }
    final previous = _cache[url];
    // A failed refresh keeps the last headlines for a while: news a couple of hours old is still news.
    final keep =
        result.isEmpty && previous != null && previous.stories.isNotEmpty && now().difference(previous.at) < _stale;
    if (_urlsOf(await settings()).contains(url) && !keep) _cache[url] = (stories: result, at: now());
    return result.isEmpty && keep ? previous.stories : result;
  }

  /// The headlines in an RSS or Atom feed, as [parseStories].
  static List<String> parse(String feed) => [for (final story in parseStories(feed)) story.headline];

  /// The stories in an RSS or Atom feed, top story first: plain text, without duplicates or very short titles, each
  /// with the start of its summary.
  static List<DjNewsStory> parseStories(String feed) {
    final XmlDocument document;
    try {
      document = XmlDocument.parse(feed);
    } catch (_) {
      return const [];
    }
    final entries = [
      ...document.findAllElements('item', namespace: '*'),
      ...document.findAllElements('entry', namespace: '*'),
    ];
    final seen = <String>{};
    final stories = <DjNewsStory>[];
    for (final entry in entries) {
      final title = entry.findElements('title', namespace: '*').firstOrNull?.innerText;
      // No headline is that long, even as HTML.
      if (title == null || title.length > 2000) continue;
      final plain = _plainText(title);
      // A headline has a few words, or, in scripts written without spaces (Japanese, Chinese), a few characters.
      final short = _spaceless.hasMatch(plain) ? plain.runes.length < 6 : plain.split(' ').length < 3;
      if (short || plain.length > 200 || !seen.add(_keyOf(plain))) continue;
      final summary = [
        for (final name in const ['description', 'summary', 'content'])
          if (entry.findElements(name, namespace: '*').firstOrNull case final element?)
            // Markup written into the feed as it is (Atom's XHTML) is kept, so its paragraphs don't run together.
            element.childElements.isEmpty ? element.innerText : element.innerXml,
      ].firstWhere((text) => text.trim().isNotEmpty, orElse: () => '');
      stories.add((headline: plain, summary: summaryOf(summary, plain)));
      if (stories.length == 10) break;
    }
    return stories;
  }

  static String _plainText(String text) => _decodeEntities(_withoutTags(text)).replaceAll(RegExp(r'\s+'), ' ').trim();

  /// [text] with each HTML tag a space: from a '<' to the next '>', as a pattern would, but in one pass, as a pattern
  /// would try every '<' of a run that's never closed.
  static String _withoutTags(String text) {
    final plain = StringBuffer();
    var at = 0;
    while (true) {
      final open = text.indexOf('<', at);
      final close = open < 0 ? -1 : text.indexOf('>', open);
      // Not a tag: a '<' never closed is text, as is every one after it.
      if (close < 0) break;
      plain
        ..write(text.substring(at, open))
        ..write(' ');
      at = close + 1;
    }
    return (plain..write(text.substring(at))).toString();
  }

  /// The longest summary kept: a sentence or two.
  static const summaryLength = 300;

  /// How much of a feed's summary is looked at, as HTML: plenty for [summaryLength] of text.
  static const _summaryScan = 4000;

  /// The start of a feed's [summary] of the story headlined [headline], as plain text: whole sentences up to
  /// [summaryLength] (or as much of the first as fits), without a summary that only repeats the headline or a
  /// "Continue reading" link. Empty when there's nothing more to say.
  @visibleForTesting
  static String summaryOf(String summary, String headline) {
    // Only the start is kept: a whole article in the feed is cut short first, so it isn't slow to go through.
    if (summary.length > _summaryScan) summary = summary.substring(0, _summaryScan);
    // Feeds often escape their HTML, so it's taken out once it's decoded too.
    // A tag taken out before punctuation ("the <b>Andes</b>.") leaves no space behind.
    var plain = _plainText(_plainText(summary)).replaceAllMapped(RegExp(r' ([.,;:!?])'), (match) => match[1]!);
    plain = plain.replaceAll(RegExp(r'\s*(Continue reading|Read more)\W*$', caseSensitive: false), '').trim();
    if (plain.isEmpty || _keyOf(plain) == _keyOf(headline)) return '';
    // A summary starting with the headline goes on from it: the shortest start that reads as the headline goes.
    final key = _keyOf(headline);
    // A whole word of it, where words have spaces between them.
    if (_spaceless.hasMatch(key) ? _keyOf(plain).startsWith(key) : '${_keyOf(plain)} '.startsWith('$key ')) {
      for (var end = 1; end <= min(plain.length, headline.length * 2 + 20); end++) {
        if (_keyOf(plain.substring(0, end)) != key) continue;
        plain = plain.substring(end).replaceFirst(RegExp(r'^[^\p{L}\p{N}]+', unicode: true), '');
        break;
      }
      final short = _spaceless.hasMatch(plain) ? plain.runes.length < 6 : plain.split(' ').length < 3;
      if (short) return '';
    }
    if (plain.length <= summaryLength) return plain;
    // The last sentence ending that fits: a full stop (or ! or ?) with a space or the end after it, so "$2.5" isn't
    // one, or a full stop of a script without spaces.
    var end = 0;
    for (var at = 0; at < summaryLength; at++) {
      final char = plain[at];
      if ('。！？'.contains(char)) {
        end = at + 1;
      } else if ('.!?'.contains(char)) {
        var after = at + 1;
        while (after < plain.length && '"”’)'.contains(plain[after])) {
          after++;
        }
        if (after <= summaryLength && (after == plain.length || plain[after] == ' ')) end = after;
      }
    }
    if (end > 0) return plain.substring(0, end).trim();
    final cut = plain.substring(0, summaryLength);
    final space = cut.lastIndexOf(' ');
    return '${space > summaryLength ~/ 2 ? cut.substring(0, space) : cut}…';
  }

  /// Scripts written without spaces between words.
  static final _spaceless = RegExp(
    r'[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Thai}\p{Script=Lao}\p{Script=Khmer}\p{Script=Myanmar}]',
    unicode: true,
  );

  static const _namedEntities = {
    'amp': '&',
    'lt': '<',
    'gt': '>',
    'quot': '"',
    'apos': "'",
    'nbsp': ' ',
    'ndash': '–',
    'mdash': '—',
    'lsquo': '‘',
    'rsquo': '’',
    'ldquo': '“',
    'rdquo': '”',
    'hellip': '…',
  };

  /// HTML entities left in a title that was HTML inside the XML (an Atom `type="html"` title, or escaped RSS), so
  /// they're not read out as "amp".
  static String _decodeEntities(String text) =>
      text.replaceAllMapped(RegExp(r'&(#x[0-9a-f]+|#\d+|[a-z]+);', caseSensitive: false), (match) {
        final name = match[1]!;
        final code = name.startsWith('#x') || name.startsWith('#X')
            ? int.tryParse(name.substring(2), radix: 16)
            : name.startsWith('#')
            ? int.tryParse(name.substring(1))
            : null;
        if (code != null && code > 0 && code <= 0x10FFFF) return String.fromCharCode(code);
        return _namedEntities[name.toLowerCase()] ?? match[0]!;
      });

  @visibleForTesting
  static void reset() {
    _settings = null;
    _saving = Future.value();
    _held.clear();
    _cache.clear();
    _fetching.clear();
    _secondNext = false;
    _spoken = null;
    _last = null;
    now = DateTime.now;
    random = Random();
    get = (url) => http.get(url, headers: {'User-Agent': 'Finamp+'});
  }
}
