import 'dart:convert';

import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/artist_spacing.dart';
import 'package:finamp/services/finamp_user_helper.dart';
import 'package:finamp/services/jellyfin_api_helper.dart';
import 'package:finamp/services/listenbrainz_client.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:finamp/services/radio_preferences.dart';
import 'package:finamp/services/scrobble_service.dart';
import 'package:get_it/get_it.dart';

enum ListenBrainzDiscoveryFailure { connect, noRecommendations, noMatches, unavailable }

class ListenBrainzDiscoveryException implements Exception {
  const ListenBrainzDiscoveryException(this.reason);
  final ListenBrainzDiscoveryFailure reason;
}

class ListenBrainzDiscoveryService {
  ListenBrainzDiscoveryService._();
  static const sourceId = 'listenBrainzDiscovery';
  static final _uuid = RegExp(r'^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$');

  static String? recordingId(BaseItemDto item) {
    for (final entry in (item.providerIds ?? const <String, dynamic>{}).entries) {
      final key = entry.key.toLowerCase();
      if (key != 'musicbrainztrack' && key != 'musicbrainzrecording') continue;
      final id = entry.value.toString().trim().toLowerCase();
      if (_uuid.hasMatch(id)) return id;
    }
    return null;
  }

  /// Exact recording IDs avoid silently substituting another recording/version.
  static List<BaseItemDto> match(
    List<String> recommendations,
    Iterable<BaseItemDto> library,
    RadioPreferences preferences, {
    BaseItemDto? seed,
  }) {
    final byRecording = <String, BaseItemDto>{};
    for (final item in library) {
      final id = recordingId(item);
      if (id != null && preferences.permits(item)) byRecording.putIfAbsent(id, () => item);
    }
    final seen = <BaseItemId>{?seed?.id};
    final candidates = <BaseItemDto>[
      ?seed,
      for (final id in recommendations)
        if (byRecording[id.toLowerCase()] case final BaseItemDto item)
          if (seen.add(item.id)) item,
    ];
    return ArtistSpacing.order(candidates, ArtistSpacing.artistKey, keepFirst: true, dropUnavoidable: true);
  }

  static Future<List<BaseItemDto>> generate({BaseItemDto? seed, void Function(int)? onLibraryProgress}) async {
    final scope = RadioPreferencesStore.scope;
    final settings = await ScrobbleService.loadSettings();
    if ((settings.listenBrainzUser?.trim().isEmpty ?? true) || (settings.listenBrainzToken?.trim().isEmpty ?? true)) {
      throw const ListenBrainzDiscoveryException(ListenBrainzDiscoveryFailure.connect);
    }
    final Uri uri = Uri.https(
      'api.listenbrainz.org',
      '/1/cf/recommendation/user/${settings.listenBrainzUser}/recording',
      {'count': '100'},
    );
    final List<String> ids;
    try {
      final response = await ListenBrainzClient.shared.get(uri, token: settings.listenBrainzToken);
      if (response.statusCode == 204 || response.statusCode == 404) {
        throw const ListenBrainzDiscoveryException(ListenBrainzDiscoveryFailure.noRecommendations);
      }
      if (response.statusCode != 200) throw const FormatException('Recommendations unavailable');
      final values =
          (jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>)['payload'] as Map<String, dynamic>;
      ids = {
        for (final value in values['mbids'] as List)
          if (value is Map && value['recording_mbid'] is String) (value['recording_mbid'] as String).toLowerCase(),
      }.where(_uuid.hasMatch).take(100).toList();
    } on ListenBrainzDiscoveryException {
      rethrow;
    } catch (_) {
      throw const ListenBrainzDiscoveryException(ListenBrainzDiscoveryFailure.unavailable);
    }
    if (ids.isEmpty) throw const ListenBrainzDiscoveryException(ListenBrainzDiscoveryFailure.noRecommendations);
    if (scope != RadioPreferencesStore.scope) {
      throw const ListenBrainzDiscoveryException(ListenBrainzDiscoveryFailure.unavailable);
    }
    final api = GetIt.instance<JellyfinApiHelper>();
    final library = GetIt.instance<FinampUserHelper>().currentUser?.currentView;
    final preferences = await RadioPreferencesStore.load();
    final candidates = <BaseItemDto>[];
    final seen = <BaseItemId>{};
    final remaining = ids.toSet();
    // Bound paging and stop early once every recommended recording was found.
    for (var offset = 0; offset < 100000 && remaining.isNotEmpty; offset += 500) {
      if (scope != RadioPreferencesStore.scope) {
        throw const ListenBrainzDiscoveryException(ListenBrainzDiscoveryFailure.unavailable);
      }
      final List<BaseItemDto>? page;
      try {
        page = await api
            .getItems(
              parentItem: library,
              includeItemTypes: 'Audio',
              recursive: true,
              fields: '${api.defaultFields},ProviderIds',
              sortBy: 'SortName',
              startIndex: offset,
              limit: 500,
            )
            .timeout(const Duration(seconds: 20));
      } catch (_) {
        throw const ListenBrainzDiscoveryException(ListenBrainzDiscoveryFailure.unavailable);
      }
      if (page == null) throw const ListenBrainzDiscoveryException(ListenBrainzDiscoveryFailure.unavailable);
      var added = 0;
      for (final item in page) {
        if (!seen.add(item.id)) continue;
        added++;
        final id = recordingId(item);
        if (id != null && remaining.contains(id) && preferences.permits(item)) {
          candidates.add(item);
          remaining.remove(id);
        }
      }
      onLibraryProgress?.call(seen.length);
      if (page.length < 500 || added == 0) break;
    }
    final result = match(ids, candidates, preferences, seed: seed);
    if (result.length <= (seed == null ? 0 : 1)) {
      throw const ListenBrainzDiscoveryException(ListenBrainzDiscoveryFailure.noMatches);
    }
    if (scope != RadioPreferencesStore.scope) {
      throw const ListenBrainzDiscoveryException(ListenBrainzDiscoveryFailure.unavailable);
    }
    return result;
  }

  static Future<void> play({required String name, BaseItemDto? seed}) async {
    final scope = RadioPreferencesStore.scope;
    final tracks = await generate(seed: seed);
    if (scope != RadioPreferencesStore.scope) {
      throw const ListenBrainzDiscoveryException(ListenBrainzDiscoveryFailure.unavailable);
    }
    await GetIt.instance<QueueService>().startPlayback(
      items: tracks,
      source: QueueItemSource.rawId(
        type: QueueItemSourceType.playlist,
        id: sourceId,
        name: QueueItemSourceName(type: QueueItemSourceNameType.preTranslated, pretranslatedName: name),
      ),
      order: FinampPlaybackOrder.linear,
      startingIndex: 0,
      randomizeGenerated: false,
    );
  }
}
