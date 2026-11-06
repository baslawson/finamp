import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:finamp/components/karaoke_export_sheet.dart';
import 'package:finamp/components/karaoke_links.dart';
import 'package:finamp/l10n/app_localizations.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/services/analyzer_service.dart';
import 'package:finamp/services/finamp_user_helper.dart';
import 'package:finamp/services/karaoke_export.dart';
import 'package:finamp/services/karaoke_service.dart';
import 'package:finamp/services/server_hub_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

class _User extends Fake implements FinampUserHelper {
  @override
  final currentUser = FinampUser(
    id: 'user',
    publicAddress: 'https://server.invalid',
    localAddress: '',
    preferLocalNetwork: false,
    isLocal: false,
    accessToken: 'test',
    serverId: 'server',
  );
}

class _OtherUser extends Fake implements FinampUserHelper {
  @override
  final currentUser = FinampUser(
    id: 'other',
    publicAddress: 'https://server.invalid',
    localAddress: '',
    preferLocalNetwork: false,
    isLocal: false,
    accessToken: 'other',
    serverId: 'server',
  );
}

final song = 'c' * 32;
const name = 'Daryl Braithwaite - As The Days Go By (No vocals).mp3';

http.Response json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

/// Waits for [done], as a download makes its folder on disk before asking, which takes more than a few turns of the
/// event loop.
Future<void> until(bool Function() done) async {
  for (var tries = 0; !done() && tries < 500; tries++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(done(), isTrue, reason: 'waited 5 seconds');
}

String baseName(String path) => path.split(RegExp(r'[\\/]')).last;

KaraokeExportFile prepared() => (name: name, ticket: 'ticket', bytes: 5);

const linkId = 'ffffffffffffffffffffffffffffffff';

Map<String, Object> linkJson({String id = linkId, int downloads = 0}) => {
  'id': id,
  'name': name,
  'format': 'mp3',
  'url': 'http://10.0.0.2/hub/dl/token-$id',
  'downloads': downloads,
  'expires': 1800000000,
  'created': 1799900000,
  'public': false,
};

Map<String, Object> ready([int bytes = 5]) => {'state': 'ready', 'ticket': 'ticket', 'name': name, 'bytes': bytes};

void main() {
  late http.Client oldClient;
  late List<http.Request> requests;
  late Directory folder;
  late Future<http.Response> Function(http.Request request) answer;

  KaraokeExport export({Duration patience = const Duration(minutes: 5)}) =>
      KaraokeExport(directory: () async => folder, poll: Duration.zero, patience: patience);

  setUp(() async {
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    await AnalyzerService.saveSettings(url: 'http://hub.test', token: 'token');
    GetIt.instance.registerSingleton<FinampUserHelper>(_User());
    folder = await Directory.systemTemp.createTemp('karaoke_export_test');
    // Links stopped in one test mustn't count as stopped in the next.
    KaraokeExport.stopped.clear();
    oldClient = ServerHubService.client;
    requests = [];
    answer = (_) async => json({'detail': 'Not Found'}, 404);
    ServerHubService.client = MockClient((request) {
      requests.add(request);
      return answer(request);
    });
  });

  tearDown(() async {
    ServerHubService.client = oldClient;
    await GetIt.instance.reset();
    await folder.delete(recursive: true);
  });

  String call(http.Request request) => '${request.method} ${request.url.path}';

  group('prepare', () {
    test('a converted file comes at once, asked for with the song, part, guide and format', () async {
      answer = (_) async => json(ready());
      final file = await export().prepare(
        'cccccccc-cccc-cccc-cccc-cccccccccccc',
        KaraokePart.drums,
        25,
        KaraokeFileFormat.wav,
      );
      expect(file, (name: name, ticket: 'ticket', bytes: 5));
      expect(requests.map(call), ['POST /hub/api/karaoke/exports']);
      expect(jsonDecode(requests.single.body), {'song': song, 'part': 'drums', 'guide': 25, 'format': 'wav'});
      expect(requests.single.headers['X-Jellyfin-Token'], 'test');
    });

    test('waits while the server converts, asking without starting another conversion', () async {
      var asked = 0;
      answer = (request) async {
        if (request.method == 'POST') return json({'state': 'preparing', 'job': 'j'});
        return json(++asked < 3 ? {'state': 'preparing'} : ready());
      };
      final file = await export().prepare(song, KaraokePart.vocals, 0, KaraokeFileFormat.mp3);
      expect(file.ticket, 'ticket');
      expect(requests.map(call), [
        'POST /hub/api/karaoke/exports',
        'GET /hub/api/karaoke/exports',
        'GET /hub/api/karaoke/exports',
        'GET /hub/api/karaoke/exports',
      ]);
      expect(requests.last.url.queryParameters, {'song': song, 'part': 'vocals', 'guide': '0', 'format': 'mp3'});
    });

    test("a failed conversion says the server's reason", () async {
      answer = (request) async => json(
        request.method == 'POST'
            ? {'state': 'preparing', 'job': 'j'}
            : {'state': 'failed', 'message': 'The server could not convert this mix'},
      );
      await expectLater(
        export().prepare(song, KaraokePart.vocals, 0, KaraokeFileFormat.mp3),
        throwsA(isA<ServerHubException>().having((e) => e.message, 'message', 'The server could not convert this mix')),
      );
    });

    test('a vanished job is asked for once more, then given up', () async {
      answer = (request) async =>
          json(request.method == 'POST' ? {'state': 'preparing', 'job': 'j'} : {'state': 'missing'});
      await expectLater(
        export().prepare(song, KaraokePart.vocals, 0, KaraokeFileFormat.mp3),
        throwsA(isA<ServerHubException>()),
      );
      expect(requests.where((request) => request.method == 'POST'), hasLength(2));
    });

    test('a conversion that takes too long is given up with a reason', () async {
      answer = (request) async => json({'state': 'preparing', 'job': 'j'});
      await expectLater(
        export(patience: Duration.zero).prepare(song, KaraokePart.vocals, 0, KaraokeFileFormat.mp3),
        throwsA(isA<ServerHubException>().having((e) => e.message, 'message', contains('still converting'))),
      );
    });

    test("the server's own refusal reaches the listener; an older server's missing route doesn't", () async {
      answer = (_) async => json({'detail': 'Prepare this karaoke mix first'}, 409);
      await expectLater(
        export().prepare(song, KaraokePart.vocals, 0, KaraokeFileFormat.mp3),
        throwsA(isA<ServerHubException>().having((e) => e.message, 'message', 'Prepare this karaoke mix first')),
      );
      answer = (_) async => json({'detail': 'Not Found'}, 404);
      await expectLater(
        export().prepare(song, KaraokePart.vocals, 0, KaraokeFileFormat.mp3),
        throwsA(isA<ServerHubException>().having((e) => e.message, 'message', contains('Update the Finamp server'))),
      );
    });
  });

  group('download', () {
    test('saves the file under its name, reporting progress', () async {
      answer = (request) async => http.Response.bytes(utf8.encode('audio'), 200, headers: {'content-length': '5'});
      final fractions = <double>[];
      final file = await export().download(prepared(), progress: fractions.add);
      expect(baseName(file.path), name);
      expect(file.parent.parent.path, folder.path, reason: 'in a folder of its own');
      expect(await file.readAsString(), 'audio');
      expect(fractions.last, 1);
      expect(call(requests.single), 'GET /hub/api/karaoke/exports/file/ticket');
      expect(requests.single.headers.containsKey('X-Jellyfin-Token'), isFalse, reason: 'the ticket is the permission');
    });

    test('an incomplete download leaves nothing behind', () async {
      answer = (request) async => http.Response.bytes(utf8.encode('aud'), 200);
      await expectLater(export().download(prepared()), throwsA(isA<ServerHubException>()));
      expect(folder.listSync(), isEmpty);
    });

    test('the same file downloaded twice at once arrives whole both times', () async {
      final bodies = <StreamController<List<int>>>[];
      ServerHubService.client = MockClient.streaming((request, _) async {
        final body = StreamController<List<int>>();
        bodies.add(body);
        return http.StreamedResponse(body.stream, 200, contentLength: 5);
      });
      final first = export().download(prepared());
      await until(() => bodies.length == 1);
      bodies[0].add(utf8.encode('au'));
      await pumpEventQueue();
      final second = export().download(prepared());
      await until(() => bodies.length == 2);
      bodies[1].add(utf8.encode('audio'));
      await bodies[1].close();
      expect(await (await second).readAsString(), 'audio');
      bodies[0].add(utf8.encode('dio'));
      await bodies[0].close();
      expect(await (await first).readAsString(), 'audio');
      expect(folder.listSync(recursive: true).whereType<File>().map((entry) => baseName(entry.path)), [
        name,
        name,
      ], reason: 'nothing left behind');
    });

    test('a download stopped part-way (the sheet closed) closes its connection and leaves nothing', () async {
      final body = StreamController<List<int>>();
      Future<void>? aborted;
      ServerHubService.client = MockClient.streaming((request, _) async {
        aborted = (request as http.Abortable).abortTrigger!;
        return http.StreamedResponse(body.stream, 200, contentLength: 5);
      });
      var closed = false;
      final download = export().download(prepared(), cancelled: () => closed);
      await until(() => aborted != null);
      body.add(utf8.encode('au'));
      await pumpEventQueue();
      closed = true;
      body.add(utf8.encode('d'));
      await expectLater(download, throwsA(isA<KaraokeExportCancelled>()));
      await aborted!.timeout(const Duration(seconds: 1));
      expect(folder.listSync(), isEmpty);
    });

    test('a wait for a conversion ends when the sheet closes', () async {
      answer = (request) async => json({'state': 'preparing', 'job': 'j'});
      var closed = false;
      final waiting = export().prepare(song, KaraokePart.vocals, 0, KaraokeFileFormat.mp3, cancelled: () => closed);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      closed = true;
      await expectLater(waiting, throwsA(isA<KaraokeExportCancelled>()));
      final asked = requests.length;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(requests.length, asked, reason: 'no more asking');
    });

    test('two songs with the same name each keep their own file', () async {
      var body = 'first';
      answer = (request) async => http.Response.bytes(utf8.encode(body), 200);
      final first = await export().download((name: name, ticket: 'one', bytes: 5));
      body = 'other';
      final second = await export().download((name: name, ticket: 'two', bytes: 5));
      expect(baseName(first.path), baseName(second.path));
      expect(await first.readAsString(), 'first', reason: 'perhaps still being shared');
      expect(await second.readAsString(), 'other');
    });

    test('a server that stops answering is given up on, and the request itself stopped', () async {
      final stopped = <Future<void>>[];
      final started = StreamController<List<int>>();
      var asked = 0;
      ServerHubService.client = MockClient.streaming((request, _) async {
        final trigger = (request as http.Abortable).abortTrigger!;
        stopped.add(trigger);
        // The first never starts its answer; the second sends a little, then nothing more.
        if (asked++ == 0) {
          await trigger;
          throw http.RequestAbortedException(request.url);
        }
        return http.StreamedResponse(started.stream, 200, contentLength: 5);
      });
      final quick = KaraokeExport(directory: () async => folder, stall: const Duration(milliseconds: 50));
      await expectLater(
        quick.download(prepared()),
        throwsA(isA<ServerHubException>().having((e) => e.message, 'message', contains('did not start'))),
      );
      started.add(utf8.encode('au'));
      await expectLater(quick.download(prepared()), throwsA(isA<ServerHubException>()));
      await Future.wait(stopped).timeout(const Duration(seconds: 1));
      expect(folder.listSync(), isEmpty);
    });

    test('an expired ticket says so', () async {
      answer = (request) async => json({'detail': 'This link expired'}, 401);
      await expectLater(
        export().download(prepared()),
        throwsA(isA<ServerHubException>().having((e) => e.message, 'message', contains('expired'))),
      );
    });

    test('files from earlier saves are cleared, recent ones kept', () async {
      final old = File('${folder.path}/old.mp3')..writeAsStringSync('x');
      old.setLastModifiedSync(DateTime.now().subtract(const Duration(hours: 2)));
      final recent = File('${folder.path}/recent.mp3')..writeAsStringSync('x');
      answer = (request) async => http.Response.bytes(utf8.encode('audio'), 200);
      final downloaded = await export().download(prepared());
      await export().clearOld();
      expect(old.existsSync(), isFalse);
      expect(recent.existsSync(), isTrue);
      expect(downloaded.existsSync(), isTrue, reason: 'just downloaded, perhaps still being shared');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await export().clearOld(age: Duration.zero);
      expect(downloaded.parent.existsSync(), isFalse, reason: "an old download's folder goes with it");
    });

    test('a download still coming in is not cleared, however long it has taken', () async {
      // Its folder was made long ago (by the clock here, longer than the age allowed); its file is still written to.
      final running = Directory('${folder.path}/running')..createSync();
      final partial = File('${running.path}/$name.partial')..writeAsStringSync('au');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      partial.writeAsStringSync('dio', mode: FileMode.append);
      await export().clearOld(age: const Duration(milliseconds: 150));
      expect(partial.existsSync(), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await export().clearOld(age: const Duration(milliseconds: 150));
      expect(running.existsSync(), isFalse, reason: 'once it stops changing, it goes');
    });
  });

  group('links', () {
    final link = {
      'id': 'f' * 32,
      'name': name,
      'format': 'mp3',
      'url': 'https://example.net/finamp-analyzer/hub/dl/token',
      'downloads': 2,
      'expires': 1800000000,
      'created': 1799900000,
    };

    test('a link is made for how long was chosen', () async {
      answer = (_) async => json({...link, 'public': true});
      final shared = await export().share(song, KaraokePart.both, 50, KaraokeFileFormat.flac, KaraokeLinkLength.week);
      expect(jsonDecode(requests.single.body), {
        'song': song,
        'part': 'both',
        'guide': 50,
        'format': 'flac',
        'hours': 168,
      });
      expect(shared.public, isTrue);
      expect(shared.link.url, link['url']);
      expect(shared.link.expires, DateTime.fromMillisecondsSinceEpoch(1800000000000));
    });

    test('links are listed, and stopping one already gone is no error', () async {
      answer = (request) async => request.method == 'GET'
          ? json({
              'links': [link],
              'public': false,
            })
          : json({'detail': 'This link already ended'}, 404);
      final listed = await export().links();
      expect(listed.public, isFalse);
      expect(listed.links.single.downloads, 2);
      expect(listed.links.single.format, KaraokeFileFormat.mp3);
      await export().stop('f' * 32);
      expect(call(requests.last), 'DELETE /hub/api/karaoke/links/${'f' * 32}');
      // A 404 not the hub's own (a proxy's while the hub restarts) says neither way either.
      for (final notTheHub in [
        http.Response('<html>404 page not found</html>', 404),
        json({'detail': 'Not Found'}, 404),
      ]) {
        answer = (_) async => notTheHub;
        await expectLater(export().stop('e' * 32), throwsA(isA<KaraokeStopUnanswered>()));
      }
      expect(KaraokeExport.stopped, isNot(contains('e' * 32)));
      // Refused, it still works; a server error (or a proxy's page) says neither way.
      answer = (_) async => json({'detail': 'Invalid link'}, 400);
      await expectLater(export().stop('f' * 32), throwsA(isA<ServerHubException>()));
      answer = (_) async => json({'detail': 'Server error'}, 500);
      await expectLater(export().stop('f' * 32), throwsA(isA<KaraokeStopUnanswered>()));
      answer = (_) async => http.Response('<html>Bad gateway</html>', 502);
      await expectLater(export().stop('f' * 32), throwsA(isA<KaraokeStopUnanswered>()));
      // Not sent at all, as the account changed: it still works, and says so.
      final hub = await ServerHubService.connect();
      final sent = requests.length;
      await GetIt.instance.reset();
      GetIt.instance.registerSingleton<FinampUserHelper>(_OtherUser());
      await expectLater(export().stop('f' * 32, hub: hub), throwsA(isA<ServerHubException>()));
      expect(requests, hasLength(sent));
    });
  });

  test('only a real explanation from the hub is passed on', () {
    expect(
      ServerHubService.serverMessage(json({'detail': 'Stop one of your download links first'}, 429)),
      'Stop one of your download links first',
    );
    expect(ServerHubService.serverMessage(json({'detail': 'Not Found'}, 404)), isNull);
    expect(ServerHubService.serverMessage(http.Response('<html>', 502)), isNull);
    expect(ServerHubService.serverMessage(json({'detail': 'x' * 301}, 400)), isNull);
    expect(ServerHubService.serverMessage(json({'detail': <Object>[]}, 422)), isNull);
  });

  group('sheet', () {
    Future<void> open(WidgetTester tester, {required bool offline, List<int>? savedGuides}) async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: KaraokeExportSheet(
              song: song,
              part: KaraokePart.vocals,
              guide: 0,
              title: (guide) => 'As The Days Go By${guide > 0 ? ' · $guide%' : ''}',
              export: export(),
              savedGuides: savedGuides,
              offline: offline,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('online it offers the three formats and a link, made after converting', (tester) async {
      answer = (request) async => switch (call(request)) {
        'POST /hub/api/karaoke/exports' => json(ready()),
        'GET /hub/api/karaoke/links' => json({'links': <Object>[], 'public': false}),
        'POST /hub/api/karaoke/links' => json({
          'id': 'f' * 32,
          'name': name,
          'format': 'mp3',
          'url': 'http://10.0.0.2/hub/dl/token',
          'downloads': 0,
          'expires': 1800000000,
          'created': 1799900000,
          'public': false,
        }),
        _ => json({'detail': 'Not Found'}, 404),
      };
      await open(tester, offline: false);
      for (final format in ['FLAC', 'WAV', 'MP3']) {
        expect(find.text(format), findsOneWidget);
      }
      expect(find.textContaining('320 kbps'), findsOneWidget, reason: 'MP3 is chosen first');
      await tester.tap(find.text('WAV'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Uncompressed'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.text('Make link'));
        for (var i = 0; i < 20 && find.textContaining('/hub/dl/').evaluate().isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump();
        }
      });
      await tester.pumpAndSettle();
      expect(find.text('http://10.0.0.2/hub/dl/token'), findsOneWidget);
      expect(find.textContaining('home network'), findsOneWidget, reason: 'the server has no public address');
      expect(requests.map(call), ['POST /hub/api/karaoke/exports', 'POST /hub/api/karaoke/links']);
      expect(jsonDecode(requests.first.body)['format'], 'wav');
      expect(jsonDecode(requests.last.body)['hours'], 24, reason: 'links last a day unless chosen otherwise');
      await tester.tap(find.text('FLAC'));
      await tester.pumpAndSettle();
      expect(find.textContaining('/hub/dl/'), findsNothing, reason: 'the link offers the WAV, not the FLAC now chosen');
      // All of this account's links are a tap away.
      await tester.runAsync(() async {
        await tester.tap(find.text('Your download links'));
        for (var i = 0; i < 50 && find.text('You have no download links that still work.').evaluate().isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump();
        }
      });
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Download links'), findsOneWidget);
      expect(find.text('You have no download links that still work.'), findsOneWidget);
      expect(requests.last.url.path, '/hub/api/karaoke/links');
    });

    testWidgets('a link just made can be stopped there; one that fails to stop stays', (tester) async {
      var stops = 0;
      answer = (request) async => switch (call(request)) {
        'POST /hub/api/karaoke/exports' => json(ready()),
        'POST /hub/api/karaoke/links' => json(linkJson()),
        'DELETE /hub/api/karaoke/links/$linkId' =>
          ++stops == 1 ? json({'detail': 'Invalid link'}, 400) : json({'stopped': true}),
        _ => json({'links': <Object>[], 'public': true}),
      };
      await open(tester, offline: false);
      Future<void> settle(bool Function() done) => tester.runAsync(() async {
        for (var i = 0; i < 20 && !done(); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump();
        }
      });
      await tester.tap(find.text('Make link'));
      await settle(() => find.textContaining('/hub/dl/').evaluate().isNotEmpty);
      await tester.pumpAndSettle();
      final changed = KaraokeExport.linksChanged.value;
      await tester.tap(find.text('Stop link'));
      await settle(() => stops == 1 && find.text('Invalid link').evaluate().isNotEmpty);
      await tester.pumpAndSettle();
      expect(find.text('Invalid link'), findsOneWidget);
      expect(find.textContaining('/hub/dl/'), findsOneWidget, reason: 'not stopped, so it still works and stays');
      await tester.tap(find.text('Stop link'));
      await settle(() => find.textContaining('/hub/dl/').evaluate().isEmpty);
      await tester.pumpAndSettle();
      expect(stops, 2);
      expect(find.textContaining('/hub/dl/'), findsNothing);
      expect(find.textContaining('Link stopped'), findsOneWidget);
      expect(KaraokeExport.linksChanged.value, changed + 1, reason: 'lists elsewhere load again');
    });

    testWidgets('a stop the server never answered is not offered again, and says it may have stopped', (tester) async {
      answer = (request) async => switch (call(request)) {
        'POST /hub/api/karaoke/exports' => json(ready()),
        'POST /hub/api/karaoke/links' => json(linkJson()),
        'DELETE /hub/api/karaoke/links/$linkId' => throw const SocketException('Connection reset'),
        _ => json({'detail': 'Not Found'}, 404),
      };
      await open(tester, offline: false);
      await tester.runAsync(() async {
        await tester.tap(find.text('Make link'));
        for (var i = 0; i < 20 && find.textContaining('/hub/dl/').evaluate().isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump();
        }
        await tester.tap(find.text('Stop link'));
        for (var i = 0; i < 20 && find.textContaining('may or may not').evaluate().isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump();
        }
      });
      await tester.pumpAndSettle();
      expect(find.textContaining('may or may not have stopped'), findsOneWidget);
      expect(find.textContaining('/hub/dl/'), findsNothing, reason: 'it may be dead: not offered for sharing');
    });

    testWidgets('closing the sheet part-way through a download stops it', (tester) async {
      final body = StreamController<List<int>>();
      Future<void>? aborted;
      ServerHubService.client = MockClient.streaming((request, _) async {
        requests.add(request as http.Request);
        if (request.url.path.contains('/exports/file/')) {
          aborted = (request as http.Abortable).abortTrigger!;
          return http.StreamedResponse(body.stream, 200, contentLength: 5);
        }
        return http.StreamedResponse(Stream.value(utf8.encode(jsonEncode(ready()))), 200);
      });
      await open(tester, offline: false);
      await tester.runAsync(() async {
        await tester.tap(find.text('Share file'));
        await until(() => aborted != null);
        body.add(utf8.encode('au'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        body.add(utf8.encode('d'));
        await aborted!.timeout(const Duration(seconds: 2));
        await until(() => folder.listSync().isEmpty);
      });
    });

    testWidgets('a link stopped from the list of links is taken away where it was made', (tester) async {
      answer = (request) async => switch (call(request)) {
        'POST /hub/api/karaoke/exports' => json(ready()),
        'POST /hub/api/karaoke/links' => json(linkJson()),
        'DELETE /hub/api/karaoke/links/$linkId' => json({'stopped': true}),
        _ => json({'detail': 'Not Found'}, 404),
      };
      await open(tester, offline: false);
      await tester.runAsync(() async {
        await tester.tap(find.text('Make link'));
        for (var i = 0; i < 20 && find.textContaining('/hub/dl/').evaluate().isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump();
        }
        // Stopped from Your download links, over this sheet.
        await export().stop(linkId);
      });
      await tester.pumpAndSettle();
      expect(find.textContaining('/hub/dl/'), findsNothing);
      expect(find.text('Copy link'), findsNothing);
    });

    testWidgets('from Saved karaoke the guide level can be chosen, any of them online', (tester) async {
      await open(tester, offline: false, savedGuides: [0]);
      for (final level in KaraokeService.guideLevels) {
        expect(find.text('$level%'), findsOneWidget);
      }
      await tester.tap(find.text('50%'));
      await tester.pumpAndSettle();
      expect(find.text('As The Days Go By · 50%'), findsOneWidget);
    });

    testWidgets('the list of links stops one, loads again when one is made elsewhere, and says when it fails', (
      tester,
    ) async {
      final other = 'e' * 32;
      var live = [linkJson(downloads: 2)];
      answer = (request) async => switch (call(request)) {
        'GET /hub/api/karaoke/links' => json({'links': live, 'public': true}),
        'DELETE /hub/api/karaoke/links/$linkId' => json({'stopped': true}),
        _ => json({'detail': 'Not Found'}, 404),
      };
      Future<void> settle() => tester.runAsync(() async {
        for (var i = 0; i < 5; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump();
        }
      });
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: KaraokeLinksList(export: export())),
        ),
      );
      await settle();
      expect(find.text(name), findsOneWidget);
      expect(find.textContaining('2 downloads'), findsOneWidget);
      // A link made elsewhere (the download sheet) shows here without leaving the screen.
      live = [linkJson(downloads: 2), linkJson(id: other)];
      KaraokeExport.linksChanged.value++;
      await settle();
      expect(find.text(name), findsNWidgets(2));
      // Stopped; the list loaded again still has it (one asked for just before): it's gone all the same.
      await tester.tap(find.byTooltip('Stop link').first);
      await settle();
      expect(requests.where((request) => request.method == 'DELETE').map(call), [
        'DELETE /hub/api/karaoke/links/${'f' * 32}',
      ]);
      expect(find.text(name), findsOneWidget);
      expect(find.text('Link stopped. It no longer downloads anything.'), findsOneWidget, reason: 'said in the list');
      // The screen around it connecting again (its Refresh) asks for the links again.
      final gets = requests.where((request) => request.method == 'GET').length;
      Future<ServerHubService?> connect({bool otherAccount = false}) async {
        final hub = await tester.runAsync(() async {
          if (otherAccount) {
            await GetIt.instance.unregister<FinampUserHelper>();
            GetIt.instance.registerSingleton<FinampUserHelper>(_OtherUser());
          }
          return ServerHubService.connect();
        });
        return hub;
      }

      // Shown meanwhile: not from an account known before, no; from the same one, yes; from another, no (this one
      // couldn't stop them).
      for (final (otherAccount, shownMeanwhile) in [(false, false), (false, true), (true, false)]) {
        final hub = await connect(otherAccount: otherAccount);
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: KaraokeLinksList(hub: hub, export: export()),
            ),
          ),
        );
        expect(find.text(name), shownMeanwhile ? findsOneWidget : findsNothing);
        await settle();
        expect(find.text(name), findsOneWidget);
      }
      expect(requests.where((request) => request.method == 'GET').length, gets + 3);
      // A list that can't be loaded says so, rather than looking empty.
      answer = (_) async => json({'detail': 'Server error'}, 500);
      KaraokeExport.linksChanged.value++;
      await settle();
      expect(find.text('Server error'), findsOneWidget);
      expect(find.text(name), findsNothing, reason: 'links that may have stopped meanwhile are not offered');
      // A 404 (a proxy's while the hub restarts, or a server from before download links) shows nothing shown before,
      // and says so rather than looking like no links.
      answer = (_) async => json({'links': live, 'public': true});
      KaraokeExport.linksChanged.value++;
      await settle();
      expect(find.text(name), findsOneWidget, reason: 'the one stopped earlier stays away');
      answer = (_) async => http.Response('<html>404 page not found</html>', 404);
      KaraokeExport.linksChanged.value++;
      await settle();
      expect(find.text(name), findsNothing);
      expect(find.text('Update the Finamp server to use the server hub.'), findsOneWidget);
      // No answer at all says the list didn't load, not that a file couldn't be made.
      answer = (_) async => throw const SocketException('Connection reset');
      KaraokeExport.linksChanged.value++;
      await settle();
      expect(find.text('Your download links could not be loaded. Try again.'), findsOneWidget);
    });

    testWidgets('stopping the last link still says so', (tester) async {
      var live = [linkJson()];
      answer = (request) async {
        if (request.method == 'DELETE') {
          live = [];
          return json({'stopped': true});
        }
        return json({'links': live, 'public': true});
      };
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: KaraokeLinksList(export: export())),
        ),
      );
      Future<void> settle() => tester.runAsync(() async {
        for (var i = 0; i < 5; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump();
        }
      });
      await settle();
      await tester.tap(find.byTooltip('Stop link'));
      await settle();
      expect(find.text(name), findsNothing);
      expect(find.text('Link stopped. It no longer downloads anything.'), findsOneWidget);
      // Then, with nothing left to show, the list goes.
      await tester.pump(const Duration(seconds: 7));
      expect(find.text('Link stopped. It no longer downloads anything.'), findsNothing);
      expect(find.text('Download links'), findsNothing);
    });

    testWidgets('a link goes from the list when it ends, with nothing else happening', (tester) async {
      final ends = DateTime.now().add(const Duration(seconds: 1)).millisecondsSinceEpoch ~/ 1000 + 1;
      answer = (_) async => json({
        'links': [
          {...linkJson(), 'expires': ends},
        ],
        'public': true,
      });
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: KaraokeLinksList(export: export())),
        ),
      );
      await tester.runAsync(() async {
        for (var i = 0; i < 20 && find.text(name).evaluate().isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump();
        }
      });
      expect(find.text(name), findsOneWidget);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 2500)));
      await tester.pump(const Duration(seconds: 4));
      expect(find.text(name), findsNothing);
    });

    testWidgets('a list loaded again keeps the newest answer, and loads again when the app comes back', (tester) async {
      final first = Completer<http.Response>();
      var gets = 0;
      answer = (request) {
        if (call(request) != 'GET /hub/api/karaoke/links') return Future.value(json({'detail': 'Not Found'}, 404));
        // The first answer comes last, and is out of date by then.
        if (++gets == 1) return first.future;
        return Future.value(
          json({
            'links': [linkJson(id: 'e' * 32, downloads: 7)],
            'public': true,
          }),
        );
      };
      Future<void> settle() => tester.runAsync(() async {
        for (var i = 0; i < 5; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump();
        }
      });
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: KaraokeLinksList(export: export())),
        ),
      );
      await settle();
      KaraokeExport.linksChanged.value++;
      await settle();
      first.complete(
        json({
          'links': [linkJson(downloads: 1)],
          'public': true,
        }),
      );
      await settle();
      expect(find.textContaining('7 downloads'), findsOneWidget);
      expect(find.textContaining('1 download'), findsNothing);
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await settle();
      expect(gets, 3, reason: 'back in front, download counts may have changed');
    });

    testWidgets('offline only the copy saved on the phone can be shared, as FLAC', (tester) async {
      await open(tester, offline: true, savedGuides: [0, 25]);
      expect(find.text('MP3'), findsNothing);
      expect(find.text('Make link'), findsNothing);
      expect(find.textContaining('Converting needs your server'), findsOneWidget);
      expect(find.text('50%'), findsNothing, reason: 'offline, only the levels saved here');
      expect(find.text('25%'), findsOneWidget);
    });
  });
}
