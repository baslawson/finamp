import 'dart:async';
import 'dart:convert';

import 'package:finamp/services/ai_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

class _TrackedClient extends MockClient {
  _TrackedClient(super.handler, this.onClose);
  final void Function() onClose;
  @override
  void close() {
    onClose();
    super.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferencesAsyncPlatform? oldPrefs;
  setUp(() {
    oldPrefs = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
  });
  tearDown(() => SharedPreferencesAsyncPlatform.instance = oldPrefs);

  Future<Map<String, dynamic>> generate() => AiService.generateJson(
    prompt: 'Write a song introduction.',
    schemaName: 'dj_line',
    schema: {
      'type': 'object',
      'properties': {
        'line': {'type': 'string'},
      },
      'required': ['line'],
    },
    timeout: const Duration(milliseconds: 150),
  );

  for (final provider in AiProvider.values) {
    test('${provider.name} generation timeout closes its request instead of hanging the DJ', () async {
      await AiService.setProvider(provider);
      await AiService.setApiKey(provider, 'test-key');
      final pending = Completer<http.Response>();
      var created = 0, closed = 0, posts = 0;
      final request = http.runWithClient(generate, () {
        created++;
        return _TrackedClient((request) async {
          if (request.method == 'GET') {
            return http.Response(jsonEncode({'models': <dynamic>[], 'data': <dynamic>[]}), 200);
          }
          posts++;
          return pending.future;
        }, () => closed++);
      });
      await expectLater(request, throwsA(isA<AiException>().having((e) => e.timedOut, 'timedOut', isTrue)));
      expect(posts, 1);
      expect(closed, created);
      pending.complete(http.Response('{}', 200));
      await Future<void>.delayed(Duration.zero);
      expect(posts, 1);
    });
  }

  for (final provider in [AiProvider.gemini, AiProvider.openai]) {
    test('${provider.name} discovery expiry cannot start generation when its timer fires early', () async {
      await AiService.setProvider(provider);
      await AiService.setApiKey(provider, 'test-key');
      final pending = Completer<http.Response>();
      var posts = 0, closed = 0;
      final request = runZoned(
        () => http.runWithClient(
          generate,
          () => _TrackedClient((request) async {
            if (request.method == 'GET') return pending.future;
            posts++;
            return http.Response('{}', 200);
          }, () => closed++),
        ),
        zoneSpecification: ZoneSpecification(
          createTimer: (self, parent, zone, duration, callback) => parent.createTimer(
            zone,
            duration > const Duration(milliseconds: 100) ? duration - const Duration(milliseconds: 100) : duration,
            callback,
          ),
        ),
      );
      await expectLater(request, throwsA(isA<AiException>().having((e) => e.timedOut, 'timedOut', isTrue)));
      expect(posts, 0);
      expect(closed, 1);
      pending.complete(http.Response(jsonEncode({'models': <dynamic>[], 'data': <dynamic>[]}), 200));
      await Future<void>.delayed(Duration.zero);
      expect(posts, 0);
    });

    test('${provider.name} discovery consumes the same deadline and never sends a late generation', () async {
      await AiService.setProvider(provider);
      await AiService.setApiKey(provider, 'test-key');
      final pending = Completer<http.Response>();
      var closed = 0, posts = 0;
      final request = http.runWithClient(
        generate,
        () => _TrackedClient((request) async {
          if (request.method == 'GET') return pending.future;
          posts++;
          return http.Response('{}', 200);
        }, () => closed++),
      );
      await expectLater(request, throwsA(isA<AiException>().having((e) => e.timedOut, 'timedOut', isTrue)));
      expect(posts, 0);
      expect(closed, 1);
      pending.complete(http.Response(jsonEncode({'models': <dynamic>[], 'data': <dynamic>[]}), 200));
      await Future<void>.delayed(Duration.zero);
      expect(posts, 0);
    });
  }
}
