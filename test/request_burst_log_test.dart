import 'dart:async';

import 'package:chopper/chopper.dart' as chopper;
import 'package:fake_async/fake_async.dart';
import 'package:finamp/services/chopper_aggregate_logger.dart';
import 'package:finamp/services/http_aggregate_logging_interceptor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:logging/logging.dart';

void main() {
  group("a burst of requests", () {
    test("keeps the first few and reports the rest in one line once it goes quiet", () {
      fakeAsync((time) {
        final reports = <String>[];
        final burst = RequestBurst(report: reports.add);
        final leftOut = [for (final ms in [10, 20, 30, 40, 90, 50]) burst.leaveOut(ms)];
        expect(leftOut, [false, false, false, true, true, true]);
        time.elapse(const Duration(seconds: 9));
        expect(reports, isEmpty);
        time.elapse(const Duration(seconds: 2));
        expect(reports, ["...and 3 more playlists loaded, the slowest in 90 ms"]);
      });
    });

    test("that stays small reports nothing", () {
      fakeAsync((time) {
        final reports = <String>[];
        final burst = RequestBurst(report: reports.add);
        expect(burst.leaveOut(10), isFalse);
        time.elapse(const Duration(minutes: 1));
        expect(reports, isEmpty);
      });
    });

    test("starts over after going quiet", () {
      fakeAsync((time) {
        final reports = <String>[];
        final burst = RequestBurst(report: reports.add);
        for (var i = 0; i < 5; i++) {
          burst.leaveOut(10);
        }
        time.elapse(const Duration(seconds: 11));
        expect(burst.leaveOut(10), isFalse);
        expect(reports, hasLength(1));
      });
    });

    test("a pause shorter than the quiet time doesn't end it", () {
      fakeAsync((time) {
        final reports = <String>[];
        final burst = RequestBurst(report: reports.add);
        for (var i = 0; i < 4; i++) {
          burst.leaveOut(10);
          time.elapse(const Duration(seconds: 9));
        }
        expect(reports, isEmpty);
        time.elapse(const Duration(seconds: 2));
        expect(reports, ["...and 1 more playlists loaded, the slowest in 10 ms"]);
      });
    });
  });

  group("the logging interceptor", () {
    late List<String> lines;
    late StreamSubscription<LogRecord> listening;

    chopper.ChopperClient client(int Function(http.Request) status) => chopper.ChopperClient(
      baseUrl: Uri.parse("https://music.example.com/jellyfin"),
      client: MockClient((request) async => http.Response("[]", status(request), request: request)),
      interceptors: [
        HttpAggregateLoggingInterceptor(
          level: chopper.Level.basic,
          burstQuietAfter: const Duration(milliseconds: 20),
        ),
      ],
    );

    Future<chopper.Response<dynamic>> get(chopper.ChopperClient api, String path) => api.get<dynamic, dynamic>(
      Uri.parse(path),
    );

    setUp(() {
      lines = [];
      Logger.root.level = Level.ALL;
      listening = chopper.chopperLogger.onRecord.listen((record) => lines.add(record.message));
    });

    tearDown(() => listening.cancel());

    Future<void> quiet() => Future<void>.delayed(const Duration(milliseconds: 60));

    test("thins out successful playlist loads and counts them", () async {
      final api = client((_) => 200);
      for (var i = 0; i < 6; i++) {
        await get(api, "/Playlists/p$i/Items");
      }
      await quiet();
      expect(lines.where((line) => line.startsWith("--> GET")), hasLength(3));
      expect(lines.where((line) => line.startsWith("<-- 200")), hasLength(3));
      expect(lines.last, startsWith("...and 3 more playlists loaded"));
    });

    test("always logs a failed playlist load in full", () async {
      final api = client((request) => request.url.path.contains("bad") ? 500 : 200);
      for (var i = 0; i < 5; i++) {
        await get(api, "/Playlists/p$i/Items");
      }
      await get(api, "/Playlists/bad/Items");
      await quiet();
      expect(lines.where((line) => line.startsWith("<-- 500")), hasLength(1));
      expect(lines.where((line) => line.contains("/Playlists/bad/Items")), hasLength(2));
    });

    test("leaves other requests alone", () async {
      final api = client((_) => 200);
      for (var i = 0; i < 6; i++) {
        await get(api, "/Users/me/Items/$i");
      }
      await quiet();
      expect(lines.where((line) => line.startsWith("--> GET")), hasLength(6));
      expect(lines.where((line) => line.startsWith("...and")), isEmpty);
    });
  });
}
