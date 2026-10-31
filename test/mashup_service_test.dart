import 'dart:convert';
import 'dart:io';

import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/analyzer_service.dart';
import 'package:finamp/services/mashup_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  const singer = '0123456789abcdef0123456789abcdef', band = 'fedcba9876543210fedcba9876543210';
  final revision = 'a' * 64;
  late Directory directory;
  late List<http.Request> requests;
  late http.Response Function(http.Request request) answer;
  late MashupService service;

  Map<String, dynamic> ready({int bytes = 4}) => {
    'state': 'ready',
    'revision': revision,
    'part': 'mashup',
    'vocals': singer,
    'backing': band,
    'plan': {'tempo': 0.97, 'semitones': -2, 'key': 'same', 'score': 0.5, 'warnings': <String>[]},
    'mixes': {
      'mashup': {'bytes': bytes, 'version': 1, 'lufs': -14, 'truePeak': -1},
    },
  };
  BaseItemDto song(String id, String name) =>
      BaseItemDto.fromJson({'Id': id, 'Name': name, 'Type': 'Audio', 'RunTimeTicks': 1000});

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('finamp-mashup-test-');
    requests = [];
    answer = (request) => request.url.path.endsWith('/audio')
        ? http.Response.bytes([1, 2, 3, 4], 200)
        : http.Response(jsonEncode(ready()), 200);
    service = MashupService(
      directory: () async => directory,
      settings: () async => (url: 'http://analyzer.test/', token: 'test-token'),
      client: MockClient((request) async {
        requests.add(request);
        expect(request.headers['X-Api-Key'], 'test-token');
        expect(request.url.toString(), isNot(contains('test-token')));
        return answer(request);
      }),
    );
  });

  tearDown(() => directory.delete(recursive: true));

  test('partners ask for the role and read each plan', () async {
    answer = (_) => http.Response(
      jsonEncode([
        {'id': band, 'score': 0.8, 'semitones': 1, 'tempo': 1.04, 'key': 'relative'},
      ]),
      200,
    );
    final partners = await service.partners(singer.toUpperCase(), sings: false);
    expect(requests.single.url.toString(), 'http://analyzer.test/mashup-partners/$singer?role=backing&limit=20');
    expect((partners.single.id, partners.single.plan.semitones, partners.single.plan.tempoPercent), (band, 1, 4));
    await service.partners(singer);
    expect(requests.last.url.queryParameters['role'], 'vocals');
  });

  test('a refused pair says why, and an older server asks to be updated', () async {
    answer = (_) => http.Response(jsonEncode({'detail': 'The keys are too far apart'}), 409);
    await expectLater(
      service.plan(singer, band),
      throwsA(isA<AnalyzerException>().having((e) => e.message, 'message', 'The keys are too far apart')),
    );
    expect(requests.single.url.path, '/mashup/$singer/$band/plan');
    for (final detail in ['Not Found', 'Choose vocals, drums or both']) {
      answer = (_) => http.Response(jsonEncode({'detail': detail}), detail == 'Not Found' ? 404 : 400);
      await expectLater(
        service.list(),
        throwsA(isA<AnalyzerException>().having((e) => e.message, 'message', contains('Update the Finamp+ server'))),
      );
    }
    // A song the analyzer doesn't know yet is not an old server.
    answer = (_) => http.Response(jsonEncode({'detail': "That song hasn't been analysed yet"}), 404);
    await expectLater(
      service.partners(singer),
      throwsA(isA<AnalyzerException>().having((e) => e.message, 'message', contains('analysed'))),
    );
    await expectLater(service.make(singer, singer), throwsA(isA<AnalyzerException>()));
  });

  test('ideas send the songs played lately and read each pair', () async {
    expect(await service.ideas([]), isEmpty);
    expect(requests, isEmpty);
    answer = (_) => http.Response(
      jsonEncode([
        {'vocals': singer, 'backing': band, 'score': 0.7, 'semitones': -1, 'tempo': 1.03, 'key': 'relative'},
      ]),
      200,
    );
    final ideas = await service.ideas([singer.toUpperCase(), band]);
    expect(requests.single.url.path, '/mashup-ideas');
    expect(requests.single.url.queryParameters, {'songs': '$singer,$band', 'limit': '20'});
    expect((ideas.single.vocals, ideas.single.backing, ideas.single.plan.semitones), (singer, band, -1));
  });

  test('making, listing and deleting on the server use the pair', () async {
    final made = await service.make(singer, band);
    expect((requests.last.method, requests.last.url.path), ('POST', '/mashup/$singer/$band'));
    expect((made.ready, made.plan!.semitones, made.measurement?.lufs), (true, -2, -14));
    answer = (_) => http.Response(
      jsonEncode({
        'items': [
          ready(),
          {'id': 'broken', 'state': 'failed'},
        ],
        'total': 2,
      }),
      200,
    );
    final jobs = await service.list();
    expect(requests.last.url.queryParameters, {'part': 'mashup', 'limit': '100', 'offset': '0'});
    expect(jobs.map((job) => job.backing), [band]);
    answer = (_) => http.Response('{}', 200);
    await service.deleteServer(jobs.single);
    expect((requests.last.method, requests.last.url.path), ('DELETE', '/mashup/$singer/$band'));
    expect(requests.last.url.queryParameters, {'revision': revision});
  });

  test('the list reads every page, and lyrics follow where the singing was placed', () async {
    answer = (request) {
      final offset = int.parse(request.url.queryParameters['offset']!);
      return http.Response(
        jsonEncode({
          'items': [
            if (offset < 2)
              {
                ...ready(),
                'revision': '$offset' * 64,
                'placement': {'offset': 3.75},
              },
          ],
          'total': 2,
        }),
        200,
      );
    };
    final jobs = await service.list();
    expect(requests.map((request) => request.url.queryParameters['offset']), ['0', '1']);
    expect(jobs.map((job) => job.revision), ['0' * 64, '1' * 64]);
    final timeline = jobs.first.lyricsTimeline!;
    expect((timeline.tempo, timeline.offset), (0.97, const Duration(milliseconds: 3750)));
    expect(MashupJob.fromJson(ready()).lyricsTimeline, isNull);
  });

  test('a played mashup is cached, and a saved one plays offline until deleted from the phone', () async {
    final job = MashupJob.fromJson(ready());
    final cached = await service.download(job);
    expect(await cached.readAsBytes(), [1, 2, 3, 4]);
    expect(requests.single.url.toString(), 'http://analyzer.test/mashup/$singer/$band/audio?revision=$revision');
    await service.download(job);
    expect(requests, hasLength(1));
    expect(await service.isSaved(job), isFalse);
    expect(await service.saved(), isEmpty);

    // Saving copies the cached file instead of downloading it again.
    final saved = await service.download(job, keepOffline: true, singer: song(singer, 'Song A'), band: song(band, 'B'));
    expect(requests, hasLength(1));
    expect(saved.path, isNot(cached.path));
    expect(await service.isSaved(job), isTrue);
    final list = await service.saved();
    expect((list.single.singer.name, list.single.band.name, list.single.job.revision), ('Song A', 'B', revision));

    await service.deleteLocal(job);
    expect((await cached.exists(), await saved.exists()), (false, false));
    expect(await service.saved(), isEmpty);
  });

  test('a short or oversized download leaves nothing behind', () async {
    for (final bytes in [8, 2]) {
      final job = MashupJob.fromJson(ready(bytes: bytes));
      await expectLater(service.download(job), throwsA(isA<AnalyzerException>()));
    }
    final files = await directory.list(recursive: true).where((entry) => entry is File).toList();
    expect(files, isEmpty);
    await expectLater(service.download(MashupJob.fromJson({'state': 'queued'})), throwsA(isA<AnalyzerException>()));
  });
}
