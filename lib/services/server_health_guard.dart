import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/radio_preferences.dart';
import 'package:finamp/services/server_hub_service.dart';

/// Best effort: a server outage never blocks a locally available mix.
class ServerHealthGuard {
  static String? _scope;
  static DateTime _refresh = DateTime(1970);
  static Set<String> _blocked = {};
  static Future<Set<String>>? _loading;

  static Future<Set<String>> blocked() async {
    final scope = RadioPreferencesStore.scope;
    if (_scope != scope) {
      _scope = scope;
      _refresh = DateTime(1970);
      _blocked = {};
      _loading = null;
    }
    if (DateTime.now().isBefore(_refresh)) return _blocked;
    return _loading ??= _load(scope).whenComplete(() {
      if (_scope == scope) _loading = null;
    });
  }

  static Future<Set<String>> _load(String scope) async {
    try {
      final hub = await ServerHubService.connect();
      if (hub == null) return {};
      final response = await hub.request('GET', '/api/blocked', timeout: const Duration(seconds: 2)) as Map;
      if (_scope == scope && RadioPreferencesStore.scope == scope) {
        _blocked = (response['ids'] as List).cast<String>().map((id) => id.replaceAll('-', '').toLowerCase()).toSet();
      }
    } catch (_) {
      /* Keep the previous list for this account. */
    } finally {
      if (_scope == scope) _refresh = DateTime.now().add(const Duration(minutes: 5));
    }
    return _scope == scope ? _blocked : {};
  }

  static List<BaseItemDto> apply(List<BaseItemDto> items, Set<String> blocked) =>
      items.where((item) => !blocked.contains(item.id.raw.replaceAll('-', '').toLowerCase())).toList();
  static Future<List<BaseItemDto>> filter(List<BaseItemDto> items) async => apply(items, await blocked());
}
