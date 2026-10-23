/// When the DJ talks.
enum DjVoiceMode { off, aiDjOnly, always }

/// What the DJ sounds like, as an OpenAI and a Gemini voice, and who it is when it isn't the default friendly host.
enum DjVoiceCharacter {
  energetic(
    openai: "ash",
    gemini: "Puck",
    persona:
        "You're an enthusiastic music host: punchy observations, lively verbs and playful momentum. Vary the hype; not every song needs a big build-up.",
  ),
  chill(
    openai: "sage",
    gemini: "Aoede",
    persona:
        "You're a relaxed music host: easy conversation, understated warmth, a little dry humour. Leave room for the music; avoid hype and stock catchphrases.",
  ),
  deep(
    openai: "onyx",
    gemini: "Charon",
    persona:
        "You're a quietly confident music host: concise, thoughtful observations and occasional deadpan wit. Keep the words natural, never grandiose.",
  ),
  bright(
    openai: "coral",
    gemini: "Zephyr",
    persona:
        "You're a cheerful, curious music host: light wordplay, vivid details and a conversational smile. Vary the sentence shapes and avoid repeating pet phrases.",
  ),
  aussieMale(openai: "echo", gemini: "Fenrir", accent: _aussieAccent, persona: _aussiePersona, locale: "en-AU"),
  aussieFemale(openai: "nova", gemini: "Laomedeia", accent: _aussieAccent, persona: _aussiePersona, locale: "en-AU"),
  actionHero(
    openai: "onyx",
    gemini: "Algenib",
    voice:
        "Style: a larger-than-life 1980s action movie hero and bodybuilder hosting the music. Deep, powerful, "
        "deadpan voice with a strong Austrian-German accent, short punchy delivery, confident pauses.",
    persona:
        "You're an over-the-top 1980s action movie hero and former bodybuilding champion from Austria, hosting the "
        "music: short, punchy, deadpan sentences, gym and action movie bravado, pumping the listener up, playful "
        "one-liners. Make up your own lines: don't quote famous movie lines and don't say who you are or name any "
        "real actor. $_stay",
  ),
  tycoon(
    openai: "onyx",
    gemini: "Alnilam",
    voice:
        "Style: a boastful billionaire showman. Confident, emphatic, slightly nasal New York delivery, punching "
        "single words, with dramatic pauses before the big claims.",
    persona:
        "You're a boastful billionaire showman hosting the music: everything is the best, tremendous, the greatest "
        "ever, nobody has better songs, the listener has fantastic taste, many people are saying so. Keep it about "
        "the music: no politics, and don't say who you are or name any real person. $_stay",
  ),
  pirate(
    openai: "fable",
    gemini: "Algenib",
    voice: "Style: a gravelly, hearty old pirate captain, rolling his R's, with a booming laugh in his voice.",
    persona:
        "You're a jolly old pirate captain hosting the music from your ship: pirate talk (arr, matey, ahoy, "
        "the seven seas), songs as treasure and voyages, not overdone so the song names stay clear. $_stay",
  ),
  trailer(
    openai: "onyx",
    gemini: "Charon",
    voice:
        "Style: an epic movie trailer narrator. Very deep, booming, slow and dramatic, with long suspenseful pauses.",
    persona:
        "You're an epic movie trailer narrator announcing songs as if they were blockbusters: \"In a world…\", "
        "dramatic build-ups, grand stakes for small things. Keep it short and the song names clear. $_stay",
  ),
  documentary(
    openai: "fable",
    gemini: "Sadaltager",
    voice:
        "Style: a hushed, fascinated nature documentary narrator with a refined British accent, soft and wondering, "
        "as if trying not to disturb the animals.",
    persona:
        "You're a nature documentary narrator observing the listener's music like rare wildlife in its habitat: "
        "hushed wonder, songs as creatures, instruments as fascinating discoveries. $_stay",
    locale: "en-GB",
  ),
  sports(
    openai: "echo",
    gemini: "Fenrir",
    voice: "Style: an excited sports commentator calling live play-by-play, fast, loud and building to big moments.",
    persona:
        "You're a sports commentator calling the music like a live match: every song change is a substitution, "
        "a goal or a comeback, play-by-play excitement and stats. $_stay",
  ),
  herald(
    openai: "fable",
    gemini: "Gacrux",
    voice: "Style: a medieval royal herald at court, grand, formal and ceremonious, with a fanfare-like delivery.",
    persona:
        "You're a medieval royal herald announcing each song as a noble guest arriving at court: \"Hear ye\", "
        "grand titles for the artists, old-fashioned courtly words. $_stay",
    locale: "en-GB",
  ),
  robot(
    openai: "alloy",
    gemini: "Iapetus",
    voice: "Style: a friendly robot from the future. Flat, precise, slightly mechanical voice, evenly paced.",
    persona:
        "You're a friendly robot from the future, studying \"human music\" with great curiosity: precise, literal "
        "observations, odd computations, gentle robot humour. $_stay",
  ),
  lateNight(
    openai: "onyx",
    gemini: "Algieba",
    voice: "Style: a late-night radio host, smooth, low, slow and intimate, like talking softly after midnight.",
    persona:
        "You're a late-night host keeping the listener company in the small hours: smooth, unhurried, a little "
        "poetic, about the night, the city and the mood of the music. $_stay",
  ),
  morningShow(
    openai: "coral",
    gemini: "Sadachbia",
    voice: "Style: a loud, cheerful morning show host, bursting with energy, quick and bubbly.",
    persona:
        "You're a loud, cheerful morning show host: coffee jokes, waking up, getting the day started, upbeat "
        "puns. Bring that energy whatever the time. $_stay",
  ),
  oldTimeRadio(
    openai: "fable",
    gemini: "Rasalgethi",
    voice:
        "Style: a 1940s radio announcer, very proper and crisp, with a mid-Atlantic accent and old-fashioned "
        "showmanship.",
    persona:
        "You're a 1940s radio announcer presenting the music: formal, charming, old-fashioned words (\"ladies and "
        "gentlemen\", \"swell\", \"brought to you by\"), as if every song were a live broadcast. $_stay",
  ),
  clubMc(
    openai: "ash",
    gemini: "Puck",
    voice: "Style: a hype club MC on the mic, loud, energetic and rhythmic, getting the crowd going.",
    persona:
        "You're a club MC hyping the crowd: shout-outs, \"make some noise\", \"hands up\", short hype lines that "
        "ride into the drop. $_stay",
  ),
  meditation(
    openai: "shimmer",
    gemini: "Enceladus",
    voice: "Style: a calm meditation guide, soft, breathy, very slow and soothing, with gentle pauses.",
    persona:
        "You're a calm meditation guide between songs: a gentle invitation to breathe, notice the music and relax, "
        "very soft and simple. $_stay",
  ),
  librarian(
    openai: "sage",
    gemini: "Achernar",
    voice: "Style: a cosy librarian speaking quietly, warm, gentle and close, almost whispering.",
    persona:
        "You're a cosy librarian sharing the music in a quiet reading room: whispered warmth, a little fact or "
        "story about the song or artist, like recommending a favourite book. $_stay",
  ),
  british(openai: "fable", gemini: "Iapetus", accent: "Accent: a natural, friendly British accent.", locale: "en-GB"),
  irish(
    openai: "echo",
    gemini: "Achird",
    accent: "Accent: a natural, warm Irish accent.",
    persona: "You're Irish: write like a friendly Irish host, with a touch of Irish expressions (not overdone).",
    locale: "en-IE",
  ),
  scottish(
    openai: "echo",
    gemini: "Orus",
    accent: "Accent: a natural, friendly Scottish accent.",
    persona: "You're Scottish: write like a friendly Scottish host, with a touch of Scottish words (not overdone).",
    locale: "en-GB",
  ),
  southern(
    openai: "ash",
    gemini: "Umbriel",
    accent: "Accent: a natural, easy-going Southern US accent.",
    persona: "You're from the American South: write with easy-going Southern warmth and a touch of its expressions.",
    locale: "en-US",
  ),
  dutch(
    openai: "nova",
    gemini: "Zubenelgenubi",
    accent: "Accent: a natural Dutch accent speaking English.",
    persona: "You're Dutch: direct and friendly, with dry humour. Write in the requested narration language.",
  ),

  /// Not a voice itself: the morning show in the morning, the usual host by day, late-night radio at night.
  byTimeOfDay(openai: "ash", gemini: "Puck");

  const DjVoiceCharacter({
    required this.openai,
    required this.gemini,
    this.voice,
    this.accent,
    this.persona,
    this.locale,
  });

  static const _aussieAccent = "Accent: a natural, relaxed Australian accent, like a host on Australian radio.";
  static const _aussiePersona =
      "You're Australian: write like a friendly Aussie host, with a touch of Australian expressions (not overdone).";
  static const _stay = "Stay in this character, over the friendly host above.";

  /// The character speaking at [time]: itself, or for [byTimeOfDay] the one that suits the hour.
  DjVoiceCharacter at(DateTime time) => this != byTimeOfDay
      ? this
      : time.hour >= 6 && time.hour < 10
      ? morningShow
      : time.hour >= 22 || time.hour < 4
      ? lateNight
      : energetic;

  final String openai;
  final String gemini;

  /// How the voice sounds, in place of the friendly host.
  final String? voice;

  /// An accent on top of the host's voice.
  final String? accent;

  /// Who the DJ is when writing its lines, on top of the friendly host.
  final String? persona;

  /// The phone voice's language, when it isn't the phone's own.
  final String? locale;

  /// Character delivery can be intentionally much slower than a normal host. Keep a hard clip limit too.
  double get minimumWordsPerSecond => switch (this) {
    trailer || meditation => 1.0,
    documentary || lateNight || librarian || herald || oldTimeRadio => 1.4,
    actionHero || tycoon || pirate || robot => 1.5,
    energetic || bright || aussieMale || aussieFemale => 2.2,
    sports || morningShow || clubMc => 1.8,
    _ => 1.5,
  };
}

typedef DjVoiceSettings = ({DjVoiceMode mode, int every, DjVoiceCharacter character, bool aiVoice, double volume});

enum DjAnnouncementLength { brief, normal, chatty }

/// Optional live-show additions. Old profiles leave every addition disabled.
class DjShowSettings {
  const DjShowSettings({
    this.duoChance = 0,
    this.coHost = DjVoiceCharacter.chill,
    this.identityEnabled = false,
    this.stationName = '',
    this.intro = '',
    this.jingleId = '',
    this.jingleText = '',
    this.jingleChance = 20,
  });
  final int duoChance, jingleChance;
  final DjVoiceCharacter coHost;
  final bool identityEnabled;
  final String stationName, intro, jingleId, jingleText;
  bool get active => duoChance > 0 || identityEnabled;
  String openingFor(String line, DjVoiceCharacter character) {
    if (!identityEnabled || intro.trim().isEmpty) return line;
    final combined = '${intro.trim()} $line';
    // Keep the complete song introduction if a slow character would need a
    // longer clip than the existing speech preparation limit allows.
    return combined.split(RegExp(r'\s+')).length <= (40 * character.minimumWordsPerSecond).floor() ? combined : line;
  }

  DjShowSettings copyWith({
    int? duoChance,
    DjVoiceCharacter? coHost,
    bool? identityEnabled,
    String? stationName,
    String? intro,
    String? jingleId,
    String? jingleText,
    int? jingleChance,
  }) => DjShowSettings(
    duoChance: duoChance ?? this.duoChance,
    coHost: coHost ?? this.coHost,
    identityEnabled: identityEnabled ?? this.identityEnabled,
    stationName: stationName ?? this.stationName,
    intro: intro ?? this.intro,
    jingleId: jingleId ?? this.jingleId,
    jingleText: jingleText ?? this.jingleText,
    jingleChance: jingleChance ?? this.jingleChance,
  );
  Map<String, dynamic> toJson() => {
    'duoChance': duoChance,
    'coHost': coHost.name,
    'identityEnabled': identityEnabled,
    'stationName': stationName,
    'intro': intro,
    'jingleId': jingleId,
    'jingleText': jingleText,
    'jingleChance': jingleChance,
  };
  factory DjShowSettings.fromJson(Map<String, dynamic> json) {
    int percent(Object? value, int fallback) => value is num && value.isFinite ? value.toInt().clamp(0, 100) : fallback;
    String text(Object? value, int limit) =>
        value is String ? value.trim().substring(0, value.trim().length.clamp(0, limit)) : '';
    return DjShowSettings(
      duoChance: percent(json['duoChance'], 0),
      coHost:
          DjVoiceCharacter.values
              .where((v) => v.name == json['coHost'] && v != DjVoiceCharacter.byTimeOfDay)
              .firstOrNull ??
          DjVoiceCharacter.chill,
      identityEnabled: json['identityEnabled'] == true,
      stationName: text(json['stationName'], 80),
      intro: text(json['intro'], 180),
      jingleId: text(json['jingleId'], 40),
      jingleText: text(json['jingleText'], 100),
      jingleChance: percent(json['jingleChance'], 20),
    );
  }
}

/// Main DJ defaults, or a station's independent override. Old settings remain
/// readable; the extra controls do not alter music playback or fade timing.
class DjVoiceProfile {
  const DjVoiceProfile({
    this.settings = defaults,
    this.length = DjAnnouncementLength.normal,
    this.rotate = false,
    this.favourites = const [],
    this.musicUnderVoice = 0.22,
    this.randomTiming = false,
    this.show = const DjShowSettings(),
  });

  static const DjVoiceSettings defaults = (
    mode: DjVoiceMode.aiDjOnly,
    every: 2,
    character: DjVoiceCharacter.energetic,
    aiVoice: true,
    volume: 0.7,
  );
  final DjVoiceSettings settings;
  final DjAnnouncementLength length;
  final bool rotate;
  final List<DjVoiceCharacter> favourites;

  /// Music remaining beneath speech; preserves the original dip by default.
  final double musicUnderVoice;
  final bool randomTiming;
  final DjShowSettings show;
  bool isCoHost(DjVoiceCharacter character) => show.duoChance > 0 && show.coHost == character;

  /// Keep saved favourites intact while reserving the second host's character.
  Set<DjVoiceCharacter> get rotationFavourites => {
    for (final character in favourites)
      if (character != DjVoiceCharacter.byTimeOfDay && !isCoHost(character)) character,
  };

  bool get rotates => rotate && settings.aiVoice && rotationFavourites.length >= 2;

  /// A paused rotation uses its remaining favourite, rather than an unrelated
  /// manual selection which may itself be the reserved co-host.
  DjVoiceCharacter get singleCharacter =>
      rotate && settings.aiVoice ? rotationFavourites.firstOrNull ?? settings.character : settings.character;

  DjVoiceProfile copyWith({
    DjVoiceSettings? settings,
    DjAnnouncementLength? length,
    bool? rotate,
    List<DjVoiceCharacter>? favourites,
    double? musicUnderVoice,
    bool? randomTiming,
    DjShowSettings? show,
  }) => DjVoiceProfile(
    settings: settings ?? this.settings,
    length: length ?? this.length,
    rotate: rotate ?? this.rotate,
    favourites: List.unmodifiable(favourites ?? this.favourites),
    musicUnderVoice: musicUnderVoice ?? this.musicUnderVoice,
    randomTiming: randomTiming ?? this.randomTiming,
    show: show ?? this.show,
  );

  Map<String, dynamic> toJson() => {
    'mode': settings.mode.name,
    'every': settings.every,
    'character': settings.character.name,
    'aiVoice': settings.aiVoice,
    'volume': settings.volume,
    'length': length.name,
    'rotate': rotate,
    'favourites': favourites.map((character) => character.name).toList(),
    'musicUnderVoice': musicUnderVoice,
    'randomTiming': randomTiming,
    if (show.active ||
        show.coHost != DjVoiceCharacter.chill ||
        show.jingleChance != 20 ||
        show.jingleId.isNotEmpty ||
        show.stationName.isNotEmpty ||
        show.intro.isNotEmpty ||
        show.jingleText.isNotEmpty)
      'show': show.toJson(),
  };

  factory DjVoiceProfile.fromJson(Map<String, dynamic> json) {
    T readEnum<T extends Enum>(List<T> values, Object? name, T fallback) =>
        values.where((value) => value.name == name).firstOrNull ?? fallback;
    final every = json['every'], volume = json['volume'], music = json['musicUnderVoice'];
    return DjVoiceProfile(
      settings: (
        mode: readEnum(DjVoiceMode.values, json['mode'], defaults.mode),
        every: every is num && every.isFinite ? every.toInt().clamp(1, 10) : defaults.every,
        character: readEnum(DjVoiceCharacter.values, json['character'], defaults.character),
        aiVoice: json['aiVoice'] is bool ? json['aiVoice'] as bool : defaults.aiVoice,
        volume: volume is num && volume.isFinite ? volume.toDouble().clamp(0.1, 1.0) : defaults.volume,
      ),
      length: readEnum(DjAnnouncementLength.values, json['length'], DjAnnouncementLength.normal),
      rotate: json['rotate'] == true,
      musicUnderVoice: music is num && music.isFinite ? music.toDouble().clamp(0.0, 1.0) : 0.22,
      randomTiming: json['randomTiming'] == true,
      show: json['show'] is Map
          ? DjShowSettings.fromJson(Map<String, dynamic>.from(json['show'] as Map))
          : const DjShowSettings(),
      favourites: List.unmodifiable({
        for (final name in json['favourites'] is List ? json['favourites'] as List : const [])
          for (final character in DjVoiceCharacter.values)
            if (character.name == name && character != DjVoiceCharacter.byTimeOfDay) character,
      }),
    );
  }
}

enum DjListeningEnvironment { car, headphones }

/// Listening presets change the three listening controls, leaving the selected
/// voice, station, mode, frequency and favourite rotation alone.
class DjListeningPreset {
  const DjListeningPreset({required this.volume, required this.length, required this.musicUnderVoice});
  final double volume, musicUnderVoice;
  final DjAnnouncementLength length;
  static const car = DjListeningPreset(volume: .9, length: DjAnnouncementLength.brief, musicUnderVoice: .12);
  static const headphones = DjListeningPreset(volume: .65, length: DjAnnouncementLength.normal, musicUnderVoice: .3);

  factory DjListeningPreset.fromProfile(DjVoiceProfile profile) => DjListeningPreset(
    volume: profile.settings.volume,
    length: profile.length,
    musicUnderVoice: profile.musicUnderVoice,
  );

  factory DjListeningPreset.fromJson(Map<String, dynamic> json) =>
      DjListeningPreset.fromProfile(DjVoiceProfile.fromJson(json));

  DjVoiceProfile apply(DjVoiceProfile profile) => profile.copyWith(
    settings: (
      mode: profile.settings.mode,
      every: profile.settings.every,
      character: profile.settings.character,
      aiVoice: profile.settings.aiVoice,
      volume: volume,
    ),
    length: length,
    musicUnderVoice: musicUnderVoice,
  );

  Map<String, dynamic> toJson() => {'volume': volume, 'length': length.name, 'musicUnderVoice': musicUnderVoice};
}
