import 'package:finamp/services/ai_service.dart';
import 'package:finamp/services/dj_voice_settings.dart';
import 'package:finamp/services/rolling_reserve_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('volume, ducking and cadence changes reuse prepared audio without paid regeneration', () {
    const profile = DjVoiceProfile();
    final changed = profile.copyWith(
      settings: (mode: DjVoiceMode.always, every: 5, character: profile.settings.character, aiVoice: true, volume: .3),
      musicUnderVoice: .5,
      randomTiming: true,
    );
    final speech = AiSpeechSettings(primary: AiProvider.gemini);
    expect(
      RollingReserveService.voiceSignature(profile, speech),
      RollingReserveService.voiceSignature(changed, speech),
    );
  });
  test('voice identity, length, provider and boost changes cannot replay an obsolete reserved recording', () {
    const profile = DjVoiceProfile();
    final speech = AiSpeechSettings(primary: AiProvider.gemini);
    final original = RollingReserveService.voiceSignature(profile, speech);
    expect(
      RollingReserveService.voiceSignature(profile.copyWith(length: DjAnnouncementLength.brief), speech),
      isNot(original),
    );
    expect(
      RollingReserveService.voiceSignature(profile, AiSpeechSettings(primary: AiProvider.openai)),
      isNot(original),
    );
    expect(
      RollingReserveService.voiceSignature(profile, AiSpeechSettings(primary: AiProvider.gemini, boost: false)),
      isNot(original),
    );
    expect(
      RollingReserveService.voiceSignature(
        profile.copyWith(
          settings: (
            mode: profile.settings.mode,
            every: 2,
            character: DjVoiceCharacter.chill,
            aiVoice: true,
            volume: .7,
          ),
        ),
        speech,
      ),
      isNot(original),
    );
  });

  test('co-host reservation changes voice keys while unrelated favourites reuse the same audio', () {
    const profile = DjVoiceProfile(
      rotate: true,
      favourites: [DjVoiceCharacter.pirate, DjVoiceCharacter.trailer, DjVoiceCharacter.meditation],
    );
    final speech = AiSpeechSettings(primary: AiProvider.gemini);
    final original = RollingReserveService.voiceSignature(profile, speech);
    final duo = profile.copyWith(show: const DjShowSettings(duoChance: 25, coHost: DjVoiceCharacter.pirate));
    final reserved = RollingReserveService.voiceSignature(duo, speech);
    expect(reserved, isNot(original));
    expect(
      RollingReserveService.voiceSignature(
        duo.copyWith(favourites: [DjVoiceCharacter.trailer, DjVoiceCharacter.meditation]),
        speech,
      ),
      reserved,
    );
    expect(
      RollingReserveService.voiceSignature(duo.copyWith(show: duo.show.copyWith(duoChance: 100)), speech),
      reserved,
    );
    final paused = duo.copyWith(favourites: [DjVoiceCharacter.pirate, DjVoiceCharacter.trailer]);
    final other = paused.copyWith(show: paused.show.copyWith(coHost: DjVoiceCharacter.trailer));
    expect(
      RollingReserveService.voiceSignature(paused, speech),
      isNot(RollingReserveService.voiceSignature(other, speech)),
    );
  });
}
