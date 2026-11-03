import 'dart:async';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/dj_voice_service.dart';
import 'package:finamp/services/jellyfin_api_helper.dart';
import 'package:finamp/services/music_player_background_task.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:finamp/services/server_hub_service.dart';
import 'package:finamp/services/server_sync_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

class ServerHubScreen extends StatefulWidget {
  const ServerHubScreen({super.key});
  static const routeName = '/server-hub';
  @override
  State<ServerHubScreen> createState() => _ServerHubScreenState();
}

class _ServerHubScreenState extends State<ServerHubScreen> {
  ServerHubService? _hub;
  Map<String, dynamic>? _status, _sync, _room;
  // The rooms open on the server, which outlive this screen: leaving it mustn't lose the way to stop a TV.
  List<Map<String, dynamic>> _rooms = [];
  List<dynamic> _historyItems = [];
  bool _loading = true, _busy = false, _enabled = true;
  String? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final hub = await ServerHubService.connect();
      if (hub == null) throw const ServerHubException('Set up your Finamp+ analyzer in Settings first.');
      final status = Map<String, dynamic>.from(await hub.request('GET', '/api/status') as Map);
      final sync = Map<String, dynamic>.from(await hub.request('GET', '/api/sync') as Map);
      final items = await hub.request('GET', '/api/sync/items') as List;
      final rooms = [
        for (final room in await hub.request('GET', '/api/rooms') as List) Map<String, dynamic>.from(room as Map),
      ];
      final enabled = await ServerSyncService.enabled();
      if (!mounted) return;
      setState(() {
        if (_hub?.scope != hub.scope || !rooms.any((room) => room['id'] == _room?['id'])) _room = null;
        _rooms = rooms;
        _hub = hub;
        _status = status;
        _sync = sync;
        _historyItems = items;
        _enabled = enabled;
        _error = null;
      });
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is ServerHubException
              ? error.message
              : 'Cannot reach the server. Check your connection and try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              error is ServerHubException ? error.message : 'This action could not be completed. Try again.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Fresh links for one of the open rooms: the TV's, the phone remote's and a new pairing code.
  Future<Map<String, dynamic>> _links(String room) async =>
      Map<String, dynamic>.from(await _hub!.request('POST', '/api/rooms/$room/links') as Map);

  Future<void> _closeRoom(String room) async {
    try {
      await _hub!.request('DELETE', '/api/rooms/$room');
    } on ServerHubException catch (error) {
      // Already closed or expired: either way it's gone.
      if (error.status != 404) rethrow;
    }
    if (mounted) {
      setState(() {
        _rooms.removeWhere((open) => open['id'] == room);
        if (_room?['id'] == room) _room = null;
      });
    }
  }

  Future<void> _open(String page, String capability) async {
    if (!await launchUrl(_hub!.page(page, capability), mode: LaunchMode.externalApplication)) {
      throw const ServerHubException('A browser could not be opened.');
    }
  }

  Future<void> _resume() async {
    final hub = _hub!;
    final latest = await hub.request('GET', '/api/sync') as Map;
    final saved = latest['queue'] as Map?;
    if (saved == null) throw const ServerHubException('There is no saved queue yet.');
    final ids = (saved['ids'] as List).cast<String>();
    final items = await GetIt.instance<JellyfinApiHelper>().getItems(itemIds: ids.map(BaseItemId.new).toList()) ?? [];
    hub.checkAccount();
    final byId = {for (final item in items) item.id.raw.replaceAll('-', ''): item};
    final ordered = ids.map((id) => byId[id.replaceAll('-', '')]).nonNulls.toList();
    final originalIndex = (saved['index'] as num).toInt();
    final current = byId[ids[originalIndex].replaceAll('-', '')];
    if (ordered.isEmpty || current == null) throw const ServerHubException('The saved song is no longer available.');
    await GetIt.instance<QueueService>().startPlayback(
      items: ordered,
      startingIndex: ordered.indexOf(current),
      beginPlaying: false,
      order: FinampPlaybackOrder.linear,
      randomizeGenerated: false,
      source: QueueItemSource(
        type: QueueItemSourceType.queue,
        name: const QueueItemSourceName(type: QueueItemSourceNameType.savedQueue),
        id: current.id,
      ),
    );
    hub.checkAccount();
    final player = GetIt.instance<MusicPlayerBackgroundTask>();
    await player.seek(Duration(milliseconds: (saved['positionMs'] as num).toInt()));
    // just_audio's play future can last until the song stops.
    unawaited(
      player.play().catchError((Object error) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Playback could not start. Try another song.')));
        }
      }),
    );
    await player.playbackState.firstWhere((state) => state.playing).timeout(const Duration(seconds: 15));
    await GetIt.instance<ServerSyncService>().claimQueue();
    await _load();
  }

  Future<void> _introduction() async {
    final program = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Station introduction'),
        children: [
          for (final entry in {
            'morning': 'Morning favourites',
            'discovery': 'Afternoon discovery',
            'evening': 'Evening chill',
          }.entries)
            SimpleDialogOption(onPressed: () => Navigator.pop(context, entry.key), child: Text(entry.value)),
        ],
      ),
    );
    if (program == null) return;
    final hub = _hub!;
    final file = await DjVoiceService.record(
      'Welcome to your ${{'morning': 'morning favourites', 'discovery': 'afternoon discovery', 'evening': 'evening chill'}[program]}. Settle in and enjoy the music.',
    );
    if (file == null) throw const ServerHubException('Set up and test your DJ voice in Settings first.');
    try {
      hub.checkAccount();
      await hub.request('POST', '/api/radio/announcement', body: await file.readAsBytes(), program: program);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Introduction sent. It plays at program changes and every five songs.')),
        );
      }
    } finally {
      await file.delete();
    }
  }

  @override
  Widget build(BuildContext context) {
    final queue = _sync?['queue'] as Map?;
    final names = {for (final item in _historyItems) (item as Map)['id']: item};
    return Scaffold(
      appBar: AppBar(
        title: const Text('Server hub'),
        actions: [IconButton(onPressed: _busy ? null : () => _run(_load), icon: const Icon(Icons.refresh))],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_error != null) ...[
                  Text(_error!),
                  TextButton(onPressed: () => _run(_load), child: const Text('Try again')),
                ],
                if (_status != null && _error == null) ...[
                  Text('Your music, around the house', style: Theme.of(context).textTheme.headlineSmall),
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      'Manage TV karaoke, your always-on station, overnight preparation, lyrics, audio health and verified backups.',
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: _busy
                        ? null
                        : () => _run(() async {
                            final result = await _hub!.request('POST', '/api/session') as Map;
                            await _open('admin', result['token'] as String);
                          }),
                    icon: const Icon(Icons.open_in_browser),
                    label: const Text('Open server controls'),
                  ),
                  // For a computer's browser, which has no way to sign in by itself.
                  TextButton.icon(
                    onPressed: _busy
                        ? null
                        : () => _run(() async {
                            final messenger = ScaffoldMessenger.of(context);
                            final result = await _hub!.request('POST', '/api/session') as Map;
                            await Clipboard.setData(
                              ClipboardData(text: _hub!.page('admin', result['token'] as String).toString()),
                            );
                            messenger.showSnackBar(
                              const SnackBar(content: Text('Link copied. It signs you in for an hour.')),
                            );
                          }),
                    icon: const Icon(Icons.link),
                    label: const Text('Copy server controls link'),
                  ),
                  if (_status!['administrator'] == true)
                    OutlinedButton.icon(
                      onPressed: _busy ? null : () => _run(_introduction),
                      icon: const Icon(Icons.mic),
                      label: const Text('Create a station introduction'),
                    ),
                  const Divider(height: 32),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.tv),
                    title: const Text('TV karaoke'),
                    subtitle: const Text('Pair a screen and use your phone as its remote.'),
                    trailing: FilledButton(
                      onPressed: _busy
                          ? null
                          : () => _run(() async {
                              final room = Map<String, dynamic>.from(
                                await _hub!.request('POST', '/api/rooms', body: {'name': 'Karaoke party'}) as Map,
                              );
                              if (mounted) {
                                setState(() {
                                  _room = room;
                                  _rooms = [
                                    ..._rooms,
                                    {'id': room['id'], 'name': room['name']},
                                  ];
                                });
                              }
                            }),
                      child: const Text('Create room'),
                    ),
                  ),
                  for (final open in _rooms) ...[
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(open['name'] as String? ?? 'Karaoke party'),
                      subtitle: const Text('Open on the server'),
                    ),
                    Wrap(
                      spacing: 8,
                      children: [
                        OutlinedButton(
                          onPressed: _busy
                              ? null
                              : () => _run(
                                  () async =>
                                      _open('remote', (await _links(open['id'] as String))['control'] as String),
                                ),
                          child: const Text('Phone remote'),
                        ),
                        OutlinedButton(
                          onPressed: _busy
                              ? null
                              : () => _run(() async {
                                  final messenger = ScaffoldMessenger.of(context);
                                  await _hub!.request('POST', '/api/rooms/${open['id']}/stop');
                                  messenger.showSnackBar(const SnackBar(content: Text('The TV is paused')));
                                }),
                          child: const Text('Stop TV'),
                        ),
                        if (_room?['id'] != open['id'])
                          TextButton(
                            onPressed: _busy
                                ? null
                                : () => _run(() async {
                                    final links = await _links(open['id'] as String);
                                    if (mounted) setState(() => _room = links);
                                  }),
                            child: const Text('Pairing code'),
                          ),
                        TextButton(
                          onPressed: _busy ? null : () => _run(() => _closeRoom(open['id'] as String)),
                          child: const Text('Close room'),
                        ),
                      ],
                    ),
                    if (_room?['id'] == open['id']) ...[
                      Text('Pairing code: ${_room!['code']}', style: Theme.of(context).textTheme.headlineSmall),
                      SelectableText('${_hub!.url}/hub/tv/'),
                      const Text(
                        'Open that address on the TV and enter the code, or scan this QR code. The code lasts ten minutes.',
                      ),
                      Center(
                        child: QrImageView(
                          data: _hub!.page('tv', _room!['screen'] as String).toString(),
                          size: 200,
                          backgroundColor: Colors.white,
                        ),
                      ),
                      TextButton(
                        onPressed: () => Clipboard.setData(
                          ClipboardData(text: _hub!.page('tv', _room!['screen'] as String).toString()),
                        ),
                        child: const Text('Copy TV link'),
                      ),
                    ],
                  ],
                  const Divider(height: 32),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Sync across devices'),
                    subtitle: const Text(
                      'Save Radio stations, preferences, listening history and your queue to your Jellyfin account.',
                    ),
                    value: _enabled,
                    onChanged: _busy
                        ? null
                        : (value) => _run(() async {
                            await ServerSyncService.setEnabled(value);
                            if (mounted) setState(() => _enabled = value);
                            if (value) await GetIt.instance<ServerSyncService>().sync();
                          }),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Saved queue'),
                    subtitle: Text(
                      queue == null
                          ? 'Play music to save your queue.'
                          : '${(queue['ids'] as List).length} songs · ${Duration(milliseconds: (queue['positionMs'] as num).toInt()).toString().split('.').first}',
                    ),
                    trailing: queue == null
                        ? null
                        : OutlinedButton(
                            onPressed: _busy ? null : () => _run(_resume),
                            child: const Text('Resume here'),
                          ),
                  ),
                  if ((_sync!['history'] as List).isNotEmpty)
                    Text('Recent listening', style: Theme.of(context).textTheme.titleLarge),
                  for (final play in (_sync!['history'] as List).take(30))
                    if (names[(play as Map)['song']] case final Map<dynamic, dynamic> song)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(song['name'] as String),
                        subtitle: Text(song['artist'] as String),
                      ),
                ],
              ],
            ),
    );
  }
}
