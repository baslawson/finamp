import 'package:finamp/services/dj_language_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('an explicit English app language wins over a Dutch device language', () {
    expect(DjLanguagePolicy.resolve(appLocale: 'en-AU', deviceLocale: 'nl_NL'), 'en-AU');
    expect(DjLanguagePolicy.resolve(deviceLocale: 'en_AU.UTF-8'), 'en-AU');
    expect(DjLanguagePolicy.resolve(deviceLocale: 'C'), 'en-US');
  });
  test('English host accents use a supported English speech locale', () {
    expect(DjLanguagePolicy.geminiSpeechCode('en-US', voiceLocale: 'en-AU'), 'en-AU');
    expect(DjLanguagePolicy.geminiSpeechCode('en-NZ', voiceLocale: 'en-IE'), 'en-US');
    expect(DjLanguagePolicy.geminiSpeechCode('en-GB'), 'en-GB');
    expect(DjLanguagePolicy.geminiSpeechCode('fr-FR', voiceLocale: 'en-AU'), isNull);
  });
}
