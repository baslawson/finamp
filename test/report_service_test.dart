import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:finamp/services/report_service.dart';
import 'package:finamp/services/server_hub_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

class _Hub implements ServerHubService {
  final sent = <({String path, Object? body, String contentType})>[];
  Completer<void>? hold;
  bool switchedAway = false;

  @override
  void checkAccount() {
    if (switchedAway) throw const ServerHubException('The active account changed.');
  }

  @override
  Future<dynamic> request(
    String method,
    String path, {
    Object? body,
    String? program,
    String contentType = 'audio/wav',
    Duration timeout = const Duration(seconds: 15),
  }) async {
    sent.add((path: path, body: body, contentType: contentType));
    await hold?.future;
    return {"name": "x"};
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _Hub hub;
  late DateTime clock;
  late List<({Uint8List? screenshot, String? note})> archived;
  late bool unmetered;

  setUp(() {
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    hub = _Hub();
    clock = DateTime(2026, 10, 28, 12);
    archived = [];
    unmetered = false;
    Logger.root.level = Level.ALL;
    ReportService.reset();
    ReportService.connect = () async => hub;
    ReportService.now = () => clock;
    ReportService.unmetered = () async => unmetered;
    ReportService.settle = const Duration(seconds: 30);
    ReportService.spacing = const Duration(hours: 1);
    ReportService.archive = ({screenshot, note}) async {
      archived.add((screenshot: screenshot, note: note));
      return Uint8List.fromList([80, 75, 5, 6]);
    };
  });

  tearDown(ReportService.reset);

  test("logs upload as a zip", () async {
    await ReportService.uploadLogs();
    expect(hub.sent.single.path, "/api/reports/logs");
    expect(hub.sent.single.contentType, "application/zip");
    expect(archived.single.screenshot, isNull);
  });

  test("a bug report sends the screenshot and note with the logs", () async {
    final png = Uint8List.fromList([1, 2, 3]);
    await ReportService.uploadBug(png, "The queue jumped");
    expect(hub.sent.single.path, "/api/reports/bug");
    expect(archived.single.screenshot, png);
    expect(archived.single.note, "The queue jumped");
  });

  test("without a server hub it says to set one up", () async {
    ReportService.connect = () async => null;
    await expectLater(ReportService.uploadLogs(), throwsA(isA<ServerHubException>()));
  });

  test("uploads go one at a time", () async {
    hub.hold = Completer();
    final first = ReportService.uploadLogs();
    final second = ReportService.uploadBug(Uint8List(1), "");
    await pumpEventQueue();
    expect(hub.sent.length, 1);
    hub.hold!.complete();
    await Future.wait([first, second]);
    expect(hub.sent.map((sent) => sent.path), ["/api/reports/logs", "/api/reports/bug"]);
  });

  test("an error uploads the logs a little later, once", () {
    fakeAsync((async) {
      unawaited(ReportService.start());
      async.flushMicrotasks();
      Logger("Player").severe("Playback broke");
      Logger("Player").severe("And again");
      async.elapse(const Duration(seconds: 29));
      expect(hub.sent, isEmpty);
      async.elapse(const Duration(seconds: 2));
      async.flushMicrotasks();
      expect(hub.sent.length, 1);
      // Another error within the hour: no second upload.
      clock = clock.add(const Duration(minutes: 10));
      Logger("Player").severe("Once more");
      async.elapse(const Duration(minutes: 1));
      async.flushMicrotasks();
      expect(hub.sent.length, 1);
      // Over an hour later it uploads again.
      clock = clock.add(const Duration(hours: 1));
      Logger("Player").severe("Later");
      async.elapse(const Duration(minutes: 1));
      async.flushMicrotasks();
      expect(hub.sent.length, 2);
    });
  });

  test("errors close together make one upload, even without the hourly limit", () {
    fakeAsync((async) {
      ReportService.spacing = Duration.zero;
      unawaited(ReportService.start());
      async.flushMicrotasks();
      Logger("Player").severe("Playback broke");
      async.elapse(const Duration(seconds: 10));
      Logger("Player").severe("And again");
      async.elapse(const Duration(minutes: 1));
      async.flushMicrotasks();
      expect(hub.sent.length, 1);
    });
  });

  test("a bug report made before an account switch isn't sent to the new account", () async {
    hub.hold = Completer();
    final first = ReportService.uploadLogs();
    final report = ReportService.uploadBug(Uint8List(1), "Made in the first account");
    await pumpEventQueue();
    final other = _Hub();
    ReportService.connect = () async => other;
    hub.switchedAway = true;
    hub.hold!.complete();
    await first;
    await expectLater(report, throwsA(isA<ServerHubException>()));
    expect(other.sent, isEmpty);
    expect(hub.sent.length, 1);
  });

  test("turning automatic uploads off drops one queued behind a bug report", () {
    fakeAsync((async) {
      hub.hold = Completer();
      unawaited(ReportService.start());
      async.flushMicrotasks();
      unawaited(ReportService.uploadBug(Uint8List(1), "Sent by hand"));
      async.flushMicrotasks();
      Logger("Player").severe("Playback broke");
      async.elapse(const Duration(minutes: 1));
      async.flushMicrotasks();
      unawaited(ReportService.setAutoUpload(false));
      async.flushMicrotasks();
      hub.hold!.complete();
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();
      expect(hub.sent.map((sent) => sent.path), ["/api/reports/bug"]);
    });
  });

  test("turning automatic uploads off while the logs are zipped keeps them here", () async {
    final zipping = Completer<void>();
    ReportService.archive = ({screenshot, note}) async {
      await zipping.future;
      return Uint8List.fromList([80, 75, 5, 6]);
    };
    unmetered = true;
    await ReportService.start();
    await pumpEventQueue();
    await ReportService.setAutoUpload(false);
    zipping.complete();
    await pumpEventQueue();
    expect(hub.sent, isEmpty);
  });

  test("warnings, and its own failures, don't upload", () {
    fakeAsync((async) {
      unawaited(ReportService.start());
      async.flushMicrotasks();
      Logger("Player").warning("Slow");
      Logger("ReportService").severe("Upload failed");
      async.elapse(const Duration(minutes: 1));
      async.flushMicrotasks();
      expect(hub.sent, isEmpty);
    });
  });

  test("with automatic uploads off, errors don't upload", () {
    fakeAsync((async) {
      unawaited(ReportService.setAutoUpload(false));
      unawaited(ReportService.start());
      async.flushMicrotasks();
      Logger("Player").severe("Playback broke");
      async.elapse(const Duration(minutes: 1));
      async.flushMicrotasks();
      expect(hub.sent, isEmpty);
    });
  });

  test("once a day on Wi-Fi at start", () async {
    await ReportService.start();
    await pumpEventQueue();
    expect(hub.sent, isEmpty);
    ReportService.reset();
    unmetered = true;
    await ReportService.start();
    await pumpEventQueue();
    expect(hub.sent.length, 1);
    ReportService.reset();
    clock = clock.add(const Duration(hours: 5));
    await ReportService.start();
    await pumpEventQueue();
    expect(hub.sent.length, 1);
    ReportService.reset();
    clock = clock.add(const Duration(days: 1));
    await ReportService.start();
    await pumpEventQueue();
    expect(hub.sent.length, 2);
  });

  test("the bug button setting is remembered", () async {
    await ReportService.setBugButton(true);
    ReportService.reset();
    expect(ReportService.bugButton.value, isFalse);
    await ReportService.start();
    expect(ReportService.bugButton.value, isTrue);
    expect(await SharedPreferencesAsync().getBool("reportsBugButton"), isTrue);
  });
}
