import 'dart:convert';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:chopper/chopper.dart' show Response;
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/services/analyzer_service.dart';
import 'package:finamp/services/finamp_logs_helper.dart';
import 'package:finamp/services/jellyfin_api.dart';
import 'package:finamp/services/listening_log_service.dart';
import 'package:finamp/services/theme_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

FinampQueueItem _queueItem(String id, {int minutes = 3}) => FinampQueueItem(
  item: MediaItem(
    id: id,
    title: id,
    extras: {
      'itemJson': {'Id': id, 'Name': id, 'RunTimeTicks': minutes * 60 * 10000000},
    },
  ),
  source: QueueItemSource.rawId(
    type: QueueItemSourceType.unknown,
    id: 'test',
    name: const QueueItemSourceName(type: QueueItemSourceNameType.preTranslated, pretranslatedName: 'Test'),
  ),
);

Response<dynamic> _response(String body) =>
    Response(http.Response.bytes(utf8.encode(body), 200, headers: {'content-type': 'application/json'}), body);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('queue item', () {
    test('parses its track once, and again when the track is replaced', () {
      final item = _queueItem('one');
      final first = item.baseItem;
      expect(identical(item.baseItem, first), true);
      expect(first.name, 'one');
      // Other extras changing keeps the same track.
      item.item = item.item.copyWith(extras: {...?item.item.extras, 'karaokeSaved': true});
      expect(identical(item.baseItem, first), true);
      item.item = _queueItem('two').item;
      expect(item.baseItem.name, 'two');
      expect(item.baseItemId.raw, 'two');
    });
  });

  group('listening log', () {
    late Directory folder;
    late PathProviderPlatform oldPaths;
    late SharedPreferencesAsyncPlatform? oldPreferences;
    setUp(() async {
      folder = await Directory.systemTemp.createTemp('finamp-log-cache-');
      oldPaths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _Paths(folder.path);
      oldPreferences = SharedPreferencesAsyncPlatform.instance;
      SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    });
    tearDown(() async {
      PathProviderPlatform.instance = oldPaths;
      SharedPreferencesAsyncPlatform.instance = oldPreferences;
      await folder.delete(recursive: true);
    });

    ListenEntry entry(String id) =>
        ListenEntry(time: DateTime(2026), listened: const Duration(minutes: 2), trackId: id, track: id);
    File log() => File('${folder.path}/listening_log.jsonl');

    test('is parsed once while the file is unchanged, and again once it changes', () async {
      await log().writeAsString('${jsonEncode(entry('aaa').toJson())}\n');
      final written = (await log().stat()).modified;
      expect((await ListeningLogService.load()).map((v) => v.trackId), ['aaa']);

      // The same size and time: taken as unchanged, so what was read is given again.
      await log().writeAsString('${jsonEncode(entry('bbb').toJson())}\n');
      await log().setLastModified(written);
      expect((await ListeningLogService.load()).map((v) => v.trackId), ['aaa']);

      // Grown: read again.
      await log().writeAsString('${jsonEncode(entry('ccc').toJson())}\n', mode: FileMode.append);
      expect((await ListeningLogService.load()).map((v) => v.trackId), ['bbb', 'ccc']);

      // Each caller gets a list of its own.
      (await ListeningLogService.load()).clear();
      expect(await ListeningLogService.load(), hasLength(2));

      await log().delete();
      expect(await ListeningLogService.load(), isEmpty);
    });

    test('a listen recorded after a read is in the next read', () async {
      await log().writeAsString('${jsonEncode(entry('before').toJson())}\n');
      expect((await ListeningLogService.load()).map((v) => v.trackId), ['before']);
      final start = DateTime.now().subtract(const Duration(minutes: 2));
      ListeningLogService.record(
        FinampHistoryItem(item: _queueItem('after'), startTime: start, endTime: DateTime.now()),
      );
      expect((await ListeningLogService.load()).map((v) => v.trackId), ['before', 'after']);
      // And it's what the file holds.
      expect((await log().readAsLines()).where((line) => line.isNotEmpty), hasLength(2));
    });
  });

  group('JSON responses', () {
    test('large ones decode off the UI thread to the same result', () async {
      final big = [
        for (var i = 0; i < 2000; i++)
          {
            'Id': 'item$i',
            'Name': 'Song number $i',
            'Genres': ['Jazz'],
          },
      ];
      final body = jsonEncode({'Items': big, 'TotalRecordCount': big.length});
      expect(body.length, greaterThan(IsolateJson.isolateThreshold));
      final response = await IsolateJson.responseFactory<dynamic, dynamic>(_response(body));
      expect(response.body, jsonDecode(body));
    });

    test('small ones and ones that are not JSON come back as before', () async {
      expect((await IsolateJson.responseFactory<dynamic, dynamic>(_response('{"a":1}'))).body, {'a': 1});
      final notJson = 'x' * (IsolateJson.isolateThreshold + 1);
      expect((await IsolateJson.responseFactory<dynamic, dynamic>(_response(notJson))).body, notJson);
      expect((await IsolateJson.responseFactory<dynamic, dynamic>(_response('nope'))).body, 'nope');
    });
  });

  group('artwork themes', () {
    ThemeColorRequest request(String? blurHash) =>
        ThemeColorRequest(NetworkImage('http://art.test/$blurHash'), blurHash, false, false);
    final colors = RawThemeResult.fromColors(Colors.red, Colors.blue);

    test('the most recently used are kept, up to the limit', () {
      final themes = RecentThemes(2);
      themes.put(request('a'), colors);
      themes.put(request('b'), colors);
      expect(themes.get(request('a')), colors);
      // b is now the least recently used.
      themes.put(request('c'), colors);
      expect(themes.get(request('b')), isNull);
      expect(themes.get(request('a')), colors);
      expect(themes.get(request('c')), colors);
    });

    test('artwork without a blurhash is not kept', () {
      final themes = RecentThemes(2);
      themes.put(request(null), colors);
      expect(themes.get(request(null)), isNull);
    });
  });

  test('in-memory logs keep the latest, trimmed a tenth at a time', () {
    final logs = FinampLogsHelper();
    final limit = FinampLogsHelper.keptLogs;
    for (var i = 0; i <= limit + limit ~/ 10; i++) {
      logs.addLog(LogRecord(Level.INFO, 'line $i', 'test'));
    }
    expect(logs.logs, hasLength(limit));
    expect(logs.logs.last.message, 'line ${limit + limit ~/ 10}');
    expect(logs.logs.first.message, 'line ${limit ~/ 10 + 1}');
    logs.addLog(LogRecord(Level.INFO, 'one more', 'test'));
    expect(logs.logs, hasLength(limit + 1));
  });

  test('the shared analyzer check is asked again once the analyzer is set up', () async {
    final oldPreferences = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    addTearDown(() => SharedPreferencesAsyncPlatform.instance = oldPreferences);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    // A screen keeps the check alive, as the vibe search tiles do.
    final kept = container.listen(analyzerConfiguredProvider, (_, _) {});
    addTearDown(kept.close);
    expect(await container.read(analyzerConfiguredProvider.future), isFalse);
    await AnalyzerService.saveSettings(url: 'http://analyzer.test', token: 'secret');
    await Future<void>.delayed(Duration.zero);
    expect(await container.read(analyzerConfiguredProvider.future), isTrue);
  });
}
