import 'dart:convert';

import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/screens/server_hub_screen.dart';
import 'package:finamp/services/analyzer_service.dart';
import 'package:finamp/services/finamp_user_helper.dart';
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

void main() {
  late http.Client oldClient;
  late List<String> requests;
  late List<Map<String, dynamic>> rooms;
  final room = 'a' * 32;

  setUp(() async {
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    await AnalyzerService.saveSettings(url: 'http://hub.test', token: 'token');
    GetIt.instance.registerSingleton<FinampUserHelper>(_User());
    oldClient = ServerHubService.client;
    requests = [];
    // A room made earlier, from a screen since closed, is still open on the server.
    rooms = [
      {'id': room, 'name': 'Karaoke party'},
    ];
    ServerHubService.client = MockClient((request) async {
      final call = '${request.method} ${request.url.path}';
      requests.add(call);
      if (call == 'DELETE /hub/api/rooms/$room') rooms = [];
      final Object? body = {
        'GET /hub/api/status': {'administrator': false},
        'GET /hub/api/sync': {'history': <Object>[], 'queue': null},
        'GET /hub/api/sync/items': <Object>[],
        'GET /hub/api/rooms': rooms,
        'POST /hub/api/rooms/$room/stop': {'stopped': true},
        'POST /hub/api/rooms/$room/links': {
          'id': room,
          'name': 'Karaoke party',
          'code': '123456',
          'screen': 'screen-ticket',
          'control': 'control-ticket',
          'guest': 'guest-ticket',
        },
        'DELETE /hub/api/rooms/$room': {'closed': true},
      }[call];
      return body == null
          ? http.Response(jsonEncode({'detail': 'Not Found'}), 404)
          : http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});
    });
  });

  tearDown(() async {
    ServerHubService.client = oldClient;
    await GetIt.instance.reset();
  });

  Future<void> openScreen(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: ServerHubScreen()));
    await tester.pumpAndSettle();
  }

  testWidgets('a room made earlier can still be stopped and closed after leaving the screen', (tester) async {
    await openScreen(tester);
    expect(find.text('Open on the server'), findsOneWidget);

    await tester.ensureVisible(find.text('Stop TV'));
    await tester.tap(find.text('Stop TV'));
    await tester.pumpAndSettle();
    expect(requests, contains('POST /hub/api/rooms/$room/stop'));
    expect(find.text('The TV is paused'), findsOneWidget);

    await tester.ensureVisible(find.text('Pairing code'));
    await tester.tap(find.text('Pairing code'));
    await tester.pumpAndSettle();
    expect(find.text('Pairing code: 123456'), findsOneWidget);

    await tester.ensureVisible(find.text('Close room'));
    await tester.tap(find.text('Close room'));
    await tester.pumpAndSettle();
    expect(requests, contains('DELETE /hub/api/rooms/$room'));
    expect(find.text('Open on the server'), findsNothing);
    expect(find.text('Pairing code: 123456'), findsNothing);

    // Opened again, the screen shows what the server has: no rooms left.
    await openScreen(tester);
    expect(find.text('Stop TV'), findsNothing);
  });

  testWidgets('a room already gone from the server is simply removed when closed', (tester) async {
    await openScreen(tester);
    rooms = [];
    ServerHubService.client = MockClient(
      (request) async => http.Response(jsonEncode({'detail': 'This TV room closed or expired'}), 404),
    );
    await tester.ensureVisible(find.text('Close room'));
    await tester.tap(find.text('Close room'));
    await tester.pumpAndSettle();
    expect(find.text('Open on the server'), findsNothing);
    expect(find.text('This action could not be completed. Try again.'), findsNothing);
  });
}
