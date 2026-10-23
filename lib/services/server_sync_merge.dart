import 'dart:convert';

/// Three-way merge: local edits win, unchanged local values follow the server.
/// Deletions are inferred only against a successfully applied baseline.
Map<String, dynamic> serverSyncChanges(Map<String, dynamic> local, Map<String, dynamic> baseline) {
  Map<String, Map<String, dynamic>> stations(Map<String, dynamic> value) => {
    for (final station in (value['stations'] as List? ?? []))
      (station as Map)['id'] as String: Map<String, dynamic>.from(station),
  };
  final current = stations(local), previous = stations(baseline);
  return {
    'upsertStations': current.values.where((value) => jsonEncode(value) != jsonEncode(previous[value['id']])).toList(),
    'deleteStations': previous.keys.where((id) => !current.containsKey(id)).toList(),
    if (local['preferences'] != null && jsonEncode(local['preferences']) != jsonEncode(baseline['preferences']))
      'preferences': local['preferences'],
  };
}

Map<String, dynamic> mergeServerSync(Map<String, dynamic> remote, Map<String, dynamic> changes) {
  final stations = {for (final value in remote['stations'] as List? ?? []) (value as Map)['id']: value};
  for (final id in changes['deleteStations'] as List? ?? []) {
    stations.remove(id);
  }
  for (final value in changes['upsertStations'] as List? ?? []) {
    stations[(value as Map)['id']] = value;
  }
  return {
    ...remote,
    'stations': stations.values.toList(),
    if (changes.containsKey('preferences')) 'preferences': changes['preferences'],
  };
}
