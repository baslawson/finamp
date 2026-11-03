import 'package:finamp/services/new_releases_service.dart';
import 'package:finamp/services/night_mode_service.dart';
import 'package:finamp/services/scrobble_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group("scrobble rules", () {
    test("half the track counts", () {
      expect(ScrobbleService.qualifies(const Duration(seconds: 100), const Duration(seconds: 200)), isTrue);
      expect(ScrobbleService.qualifies(const Duration(seconds: 99), const Duration(seconds: 200)), isFalse);
    });

    test("four minutes is enough for long tracks", () {
      expect(ScrobbleService.qualifies(const Duration(minutes: 4), const Duration(minutes: 20)), isTrue);
    });

    test("tracks of 30 seconds or less never count", () {
      expect(ScrobbleService.qualifies(const Duration(seconds: 30), const Duration(seconds: 30)), isFalse);
    });
  });

  test("Last.fm signature sorts parameters and skips format", () {
    final signature = ScrobbleService.lastFmSignature({
      "method": "track.scrobble",
      "track[0]": "Song",
      "artist[0]": "Band",
      "timestamp[0]": "1700000000",
      "api_key": "KEY",
      "sk": "SESSION",
      "format": "json",
    }, "SECRET");
    expect(signature, "2af1c8d00b7385c382e0d4e93c48cad1");
  });

  group("night mode window", () {
    test("wraps past midnight", () {
      expect(NightModeService.inWindow(23 * 60, 22 * 60, 7 * 60), isTrue);
      expect(NightModeService.inWindow(3 * 60, 22 * 60, 7 * 60), isTrue);
      expect(NightModeService.inWindow(12 * 60, 22 * 60, 7 * 60), isFalse);
      expect(NightModeService.inWindow(7 * 60, 22 * 60, 7 * 60), isFalse);
    });

    test("works within a day", () {
      expect(NightModeService.inWindow(14 * 60, 13 * 60, 15 * 60), isTrue);
      expect(NightModeService.inWindow(16 * 60, 13 * 60, 15 * 60), isFalse);
    });
  });

  test("album titles match despite editions and punctuation", () {
    expect(
      NewReleasesService.normalizeTitle("Hackney Diamonds (Deluxe Edition)"),
      NewReleasesService.normalizeTitle("Hackney Diamonds"),
    );
    expect(NewReleasesService.normalizeTitle("…And Justice for All"), "and justice for all");
  });
}
