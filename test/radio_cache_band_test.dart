import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/services/listening_hour.dart';
import 'package:finamp/services/radio_clock_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  test("a Radio cache remembers the part of the day it was chosen for, through updates", () {
    final state = RadioCacheState(
      tracks: [],
      radioMode: RadioMode.reshuffle,
      seedItem: null,
      radioState: true,
      hourBand: ListeningHour.evening,
    );
    expect(state.copyWith(generating: true).hourBand, ListeningHour.evening);
    expect(
      RadioCacheState(tracks: [], radioMode: RadioMode.reshuffle, seedItem: null, radioState: true).hourBand,
      listeningHour(DateTime.now().hour),
    );
  });

  test("time matching's setting is known at once after loading or saving", () async {
    final previous = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    addTearDown(() {
      SharedPreferencesAsyncPlatform.instance = previous;
      RadioClockSettings.cached = true;
    });
    await RadioClockSettings.save(false);
    expect(RadioClockSettings.cached, isFalse);
    RadioClockSettings.cached = true;
    expect(await RadioClockSettings.load(), isFalse);
    expect(RadioClockSettings.cached, isFalse);
  });
}
