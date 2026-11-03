import 'package:finamp/services/dj_voice_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  DjVoiceCharacter at(int hour) => DjVoiceCharacter.byTimeOfDay.at(DateTime(2026, 10, 18, hour));

  test("by time of day: morning show, the usual host, then late-night radio", () {
    expect(at(7), DjVoiceCharacter.morningShow);
    expect(at(14), DjVoiceCharacter.energetic);
    expect(at(23), DjVoiceCharacter.lateNight);
    expect(at(2), DjVoiceCharacter.lateNight);
    expect(DjVoiceCharacter.pirate.at(DateTime(2026, 10, 18, 7)), DjVoiceCharacter.pirate);
  });

  test("characters play their own part, with the recording rules kept", () {
    final pirate = DjVoiceService.styleFor(DjVoiceCharacter.pirate);
    expect(pirate, contains("pirate"));
    expect(pirate, isNot(contains("friendly music host")));
    expect(pirate, contains("Recording:"));
    expect(DjVoiceService.styleFor(DjVoiceCharacter.irish), allOf(contains("friendly music host"), contains("Irish")));
  });
}
