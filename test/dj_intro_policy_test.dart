import 'package:finamp/services/dj_intro_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a saved resume position suppresses the opening even while native position is zero', () {
    expect(
      DjIntroPolicy.allows(
        position: Duration.zero,
        duration: const Duration(minutes: 3),
        resumedAt: const Duration(seconds: 135),
      ),
      isFalse,
    );
    expect(DjIntroPolicy.allows(position: Duration.zero, resumedAt: const Duration(milliseconds: 501)), isFalse);
    expect(DjIntroPolicy.allows(position: Duration.zero, resumedAt: Duration.zero), isTrue);
  });

  test('late and short-song openings are rejected by actual playback position', () {
    expect(DjIntroPolicy.allows(position: const Duration(seconds: 135), duration: const Duration(minutes: 3)), isFalse);
    expect(
      DjIntroPolicy.allows(position: const Duration(milliseconds: 29999), duration: const Duration(minutes: 3)),
      isTrue,
    );
    expect(DjIntroPolicy.allows(position: const Duration(seconds: 30), duration: const Duration(minutes: 3)), isFalse);
    expect(DjIntroPolicy.allows(position: const Duration(seconds: 4), duration: const Duration(seconds: 20)), isTrue);
    expect(DjIntroPolicy.allows(position: const Duration(seconds: 5), duration: const Duration(seconds: 20)), isFalse);
  });

  test('missing duration does not block a fresh start or permit a late introduction', () {
    expect(DjIntroPolicy.allows(position: Duration.zero), isTrue);
    expect(DjIntroPolicy.allows(position: Duration.zero, duration: Duration.zero), isTrue);
    expect(DjIntroPolicy.allows(position: const Duration(seconds: 30)), isFalse);
    expect(DjIntroPolicy.allows(position: const Duration(seconds: -1)), isFalse);
  });
}
