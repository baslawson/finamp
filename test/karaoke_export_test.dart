import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:finamp/components/karaoke_export_sheet.dart';
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

final song = 'c' * 32;
const name = 'Daryl Braithwaite - As The Days Go By (No vocals).mp3';

http.Response json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

KaraokeExportFile prepared() => (name: name, ticket: 'ticket', bytes: 5);

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
      expect(file.path, '${folder.path}/$name');
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
      await pumpEventQueue();
      bodies[0].add(utf8.encode('au'));
      await pumpEventQueue();
      final second = export().download(prepared());
      await pumpEventQueue();
      bodies[1].add(utf8.encode('audio'));
      await bodies[1].close();
      expect(await (await second).readAsString(), 'audio');
      bodies[0].add(utf8.encode('dio'));
      await bodies[0].close();
      expect(await (await first).readAsString(), 'audio');
      expect(folder.listSync().map((entry) => entry.path.split(RegExp(r'[\\/]')).last), [
        name,
      ], reason: 'nothing left behind');
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
      await export().clearOld();
      expect(old.existsSync(), isFalse);
      expect(recent.existsSync(), isTrue);
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
      answer = (_) async => json({'detail': 'Server error'}, 500);
      await expectLater(export().stop('f' * 32), throwsA(isA<ServerHubException>()));
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
