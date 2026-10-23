/// Keeps narration language separate from the host's accent and song metadata.
class DjLanguagePolicy {
  static final _localePattern = RegExp(r'^[a-zA-Z]{2,3}(?:-[a-zA-Z0-9]{2,8})*$');
  static String resolve({String? appLocale, required String deviceLocale}) {
    final locale = (appLocale ?? deviceLocale).split('.').first.split('@').first.replaceAll('_', '-');
    return _localePattern.hasMatch(locale) ? locale : 'en-US';
  }

  static bool isEnglish(String locale) => locale.split('-').first.toLowerCase() == 'en';

  static String writingInstructions(String locale) =>
      '${isEnglish(locale) ? 'Language: English ($locale). Write the entire announcement in English.' : 'Write the entire announcement in the language of this locale: $locale.'} '
      'Keep artist names and song titles as written. '
      'Earlier announcements and song metadata must not change the narration language. '
      'Keep the host personality in the requested language.';

  static String speakingInstructions(String locale) =>
      '${isEnglish(locale) ? 'Language: English ($locale). Read the English transcript verbatim.' : 'Read the transcript verbatim, preserving its language.'} '
      'Preserve artist names and song titles. Keep the selected accent. '
      'Do not translate the transcript or switch languages.';

  /// GenerateContent accepts these English BCP-47 speech locales. An English
  /// host keeps its regional delivery without changing the narration language.
  static String? geminiSpeechCode(String locale, {String? voiceLocale}) {
    if (!isEnglish(locale)) return null;
    const supported = {'en-AU', 'en-GB', 'en-IN', 'en-US'};
    if (supported.contains(voiceLocale)) return voiceLocale;
    return supported.contains(locale) ? locale : 'en-US';
  }
}
