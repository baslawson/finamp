import 'dart:convert';
import 'dart:io';

import 'package:finamp/hive_registrar.g.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/models/locale_adapter.dart';
import 'package:finamp/models/theme_mode_adapter.dart';
import 'package:finamp/services/ai_dj_service.dart';
import 'package:finamp/services/ai_service.dart';
import 'package:finamp/services/finamp_user_helper.dart';
import 'package:finamp/services/jellyfin_api_helper.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

final _library = BaseItemDto(id: const BaseItemId('library'), name: 'Music', type: 'CollectionFolder');
final _catalog = [
  for (var i = 0; i < 4; i++)
    BaseItemDto(
      id: BaseItemId('track$i'),
      name: 'Song $i',
      type: 'Audio',
      artists: [i < 2 ? 'Muse' : 'AC/DC'],
      albumArtist: i < 2 ? 'Muse' : 'AC/DC',
      genres: ['Rock'],
    ),
];

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
    currentViewId: _library.id,
    views: {_library.id: _library},
  );
}

class _Api extends Fake implements JellyfinApiHelper {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName != #getItems) return super.noSuchMethod(invocation);
    final ids = invocation.namedArguments[#itemIds] as List<BaseItemId>?;
    return Future<List<BaseItemDto>?>.value(_catalog.where((track) => ids == null || ids.contains(track.id)).toList());
  }
}

class _Queue extends Fake implements QueueService {
  int starts = 0;
  List<BaseItemDto> items = [_catalog.last];
  QueueItemSource? source;
  bool? randomizeGenerated;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName != #startPlayback) return super.noSuchMethod(invocation);
    starts++;
    items = invocation.namedArguments[#items] as List<BaseItemDto>;
    source = invocation.namedArguments[#source] as QueueItemSource;
    randomizeGenerated = invocation.namedArguments[#randomizeGenerated] as bool?;
    return Future<void>.value();
  }
}

class _Paths extends PathProviderPlatform {
  _Paths(this.folder);
  final String folder;
  @override
  Future<String?> getApplicationSupportPath() async => folder;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory folder;
  late SharedPreferencesAsyncPlatform? oldPrefs;
  late PathProviderPlatform oldPaths;
  late _Queue queue;
  setUpAll(() {
    Hive.registerAdapters();
    Hive.registerAdapter(ThemeModeAdapter());
    Hive.registerAdapter(ColorAdapter());
    Hive.registerAdapter(LocaleAdapter());
  });
  setUp(() async {
    folder = await Directory.systemTemp.createTemp('finamp-ai-dj-generation-');
    Hive.init(folder.path);
    final box = await Hive.openBox<FinampSettings>('FinampSettings');
    await box.put(
      'FinampSettings',
      FinampSettings(
        downloadLocations: [],
        downloadLocationsMap: {},
        tabSortBy: {},
        tabSortOrder: {},
        homeScreenConfiguration: const FinampHomeScreenConfiguration(actions: [], sections: []),
        gridImageSize: 130,
        homeScreenImageSize: 90,
        deviceId: 'test',
      ),
    );
    oldPrefs = SharedPreferencesAsyncPlatform.instance;
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    oldPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(folder.path);
    GetIt.instance.registerSingleton<FinampUserHelper>(_User());
    GetIt.instance.registerSingleton<JellyfinApiHelper>(_Api());
    queue = _Queue();
    GetIt.instance.registerSingleton<QueueService>(queue);
    await SharedPreferencesAsync().setString('aiProvider', 'claude');
    for (final provider in AiProvider.values) {
      await AiService.setApiKey(provider, '${provider.name}-key');
    }
  });
  tearDown(() async {
    await GetIt.instance.reset();
    await Hive.close();
    SharedPreferencesAsyncPlatform.instance = oldPrefs;
    PathProviderPlatform.instance = oldPaths;
    // This directory was created by this test and contains only its fixture data.
    await folder.delete(recursive: true);
  });

  for (final backup in [false, true]) {
    test('AI DJ ${backup ? 'OpenAI backup' : 'Gemini primary'} creates a mix and starts its spaced queue', () async {
      final hosts = <String>[];
      final name = await http.runWithClient(
        () => AiDjService.playMix('Rock for a road trip', trackCount: 3),
        () => MockClient((request) async {
          if (request.method == 'GET') return http.Response('{"models":[],"data":[]}', 200);
          hosts.add(request.url.host);
          if (backup && request.url.host == 'generativelanguage.googleapis.com') return http.Response('{}', 429);
          final result = jsonEncode({
            'name': 'Road trip',
            'artistsRequested': false,
            'energyShape': 'free',
            'tracks': [0, 1, 2],
          });
          return http.Response(
            jsonEncode(
              request.url.host == 'api.openai.com'
                  ? {
                      'choices': [
                        {
                          'message': {'content': result},
                        },
                      ],
                    }
                  : {
                      'candidates': [
                        {
                          'content': {
                            'parts': [
                              {'text': result},
                            ],
                          },
                        },
                      ],
                    },
            ),
            200,
          );
        }),
      );
      expect(name, 'Road trip');
      expect(hosts, ['generativelanguage.googleapis.com', if (backup) 'api.openai.com']);
      expect(queue.starts, 1);
      expect(queue.items.map((v) => v.id.raw).toSet(), {'track0', 'track1', 'track2'});
      expect(queue.items.map((v) => v.artists!.single), ['Muse', 'AC/DC', 'Muse']);
      expect(queue.source?.id, 'aiDj');
      // The mix keeps its order: shuffle randomness would undo it.
      expect(queue.randomizeGenerated, isFalse);
    });
  }
  test('a failed mix leaves the existing playback queue intact and never switches to Claude', () async {
    final hosts = <String>[];
    await expectLater(
      http.runWithClient(
        () => AiDjService.playMix('Rock', trackCount: 3),
        () => MockClient((request) async {
          if (request.method == 'GET') return http.Response('{"models":[],"data":[]}', 200);
          hosts.add(request.url.host);
          return http.Response('{}', 503);
        }),
      ),
      throwsA(isA<AiException>()),
    );
    expect(hosts, ['generativelanguage.googleapis.com', 'api.openai.com']);
    expect(queue.starts, 0);
    expect(queue.items, [_catalog.last]);
  });
}
