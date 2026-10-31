import 'dart:async';
import 'dart:convert';

import 'package:finamp/services/dj_context.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferencesAsyncPlatform? previous;
  final requests = <Uri>[];

  setUp(() {
    previous = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    DjContext.reset();
    DjContext.activityOverride = (running: false, pace: null, car: false, night: false);
    requests.clear();
  });
  tearDown(() {
    DjContext.reset();
    SharedPreferencesAsyncPlatform.instance = previous;
  });

  http.Response weather(http.Request request) {
    requests.add(request.url);
    if (request.url.host == 'geocoding-api.open-meteo.com') {
      return http.Response(
        jsonEncode({
          'results': [
            {'name': 'Perth', 'latitude': -31.95, 'longitude': 115.86},
          ],
        }),
        200,
      );
    }
    return http.Response(
      jsonEncode({
        'current': {'temperature_2m': 17.6, 'weather_code': 61, 'is_day': 0},
      }),
      200,
    );
  }

  Future<String?> describe(DateTime time) =>
      http.runWithClient(() => DjContext.describe(time), () => MockClient((r) async => weather(r)));

  test('time of day only, without a city, and nothing is sent anywhere', () async {
    expect(await describe(DateTime(2026, 10, 24, 9)), 'It is weekend morning.');
    expect(await describe(DateTime(2026, 10, 23, 19)), 'It is Friday evening.');
    expect(requests, isEmpty);
  });

  test('driving, running and night mode', () async {
    DjContext.activityOverride = (running: false, pace: null, car: true, night: true);
    expect(
      await describe(DateTime(2026, 10, 22, 23)),
      'It is late night; the listener is driving; night mode is on, so the listener is winding down.',
    );
    DjContext.activityOverride = (running: true, pace: 171.4, car: true, night: false);
    expect(
      await describe(DateTime(2026, 10, 22, 15)),
      'It is afternoon; the listener is out running at about 171 steps a minute.',
    );
  });

  test('the weather for a set city, cached, sending only the city name', () async {
    await DjContext.setCity('Perth');
    expect(await describe(DateTime(2026, 10, 22, 20)), 'It is evening; in Perth it is 18 degrees and raining tonight.');
    expect(requests.first.queryParameters['name'], 'Perth');
    await describe(DateTime(2026, 10, 22, 20));
    expect(requests, hasLength(2), reason: 'the second answer comes from the cache');
  });

  test('older weather is answered at once and refreshed behind it, without looking the city up again', () async {
    var time = DateTime(2026, 10, 22, 20);
    DjContext.now = () => time;
    await DjContext.setCity('Perth');
    await describe(DateTime(2026, 10, 22, 20));
    expect(requests, hasLength(2));
    time = time.add(const Duration(minutes: 31));
    final refresh = Completer<void>();
    final line = await http.runWithClient(
      () => DjContext.describe(DateTime(2026, 10, 22, 20)),
      () => MockClient((request) async {
        refresh.complete();
        return weather(request);
      }),
    );
    expect(line, contains('18 degrees'), reason: 'the line did not wait for the refresh');
    await refresh.future;
    expect(requests.map((url) => url.host), [
      'geocoding-api.open-meteo.com',
      'api.open-meteo.com',
      'api.open-meteo.com',
    ]);
  });

  test('several lookups at once share one request', () async {
    await DjContext.setCity('Perth');
    await http.runWithClient(
      () => Future.wait([DjContext.weather(), DjContext.weather(), DjContext.describe(DateTime(2026, 10, 22, 9))]),
      () => MockClient((r) async => weather(r)),
    );
    expect(requests, hasLength(2));
  });

  test('turned off, the DJ gets no context at all', () async {
    await DjContext.setEnabled(false);
    expect(await describe(DateTime(2026, 10, 22, 20)), isNull);
  });

  test('a failing weather service leaves the rest', () async {
    await DjContext.setCity('Perth');
    expect(
      await http.runWithClient(
        () => DjContext.describe(DateTime(2026, 10, 22, 12)),
        () => MockClient((_) async => http.Response('nope', 500)),
      ),
      'It is afternoon.',
    );
  });
}
