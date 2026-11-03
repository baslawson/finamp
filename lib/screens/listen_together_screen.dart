import 'dart:async';

import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/screens/playback_reporting_settings_screen.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:finamp/services/playon_service.dart';
import 'package:finamp/services/sync_play_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

/// Create or join a Jellyfin SyncPlay group to listen in sync with others.
class ListenTogetherScreen extends ConsumerStatefulWidget {
  const ListenTogetherScreen({super.key, this.loadGroups});
  final Future<List<SyncPlayGroup>> Function()? loadGroups;

  static const routeName = "/listentogether";

  @override
  ConsumerState<ListenTogetherScreen> createState() => _ListenTogetherScreenState();
}

class _ListenTogetherScreenState extends ConsumerState<ListenTogetherScreen> {
  final _nameController = TextEditingController();
  late Future<List<SyncPlayGroup>> _groups = _loadGroups();
  Future<List<SyncPlayGroup>> _loadGroups() => (widget.loadGroups ?? SyncPlayService.listGroups)();
  StreamSubscription<String>? _events;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _events = SyncPlayService.events.listen((event) => GlobalSnackbar.message((_) => event));
  }

  @override
  void dispose() {
    _events?.cancel();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      GlobalSnackbar.error(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _refresh() {
    setState(() {
      _groups = _loadGroups();
    });
  }

  @override
  Widget build(BuildContext context) {
    final connected = GetIt.instance<PlayOnService>().socketState == SocketState.connected;
    final offline = ref.watch(finampSettingsProvider.isOffline);

    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.listenTogether),
        actions: [IconButton(onPressed: _refresh, icon: const Icon(TablerIcons.refresh))],
      ),
      body: StreamBuilder<SyncPlayGroup?>(
        stream: SyncPlayService.group,
        builder: (context, snapshot) {
          final group = snapshot.data;
          return ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              Text(context.l10n.listenTogetherDescription),
              const SizedBox(height: 12),
              if (offline || !connected)
                Card(
                  child: ListTile(
                    leading: const Icon(TablerIcons.plug_connected_x),
                    title: Text(context.l10n.listenTogetherNeedsPlayOn),
                    onTap: () => Navigator.of(context).pushNamed(PlaybackReportingSettingsScreen.routeName),
                  ),
                ),
              if (group != null) _GroupCard(group: group, busy: _busy, run: _run) else ..._joinOrCreate(context),
            ],
          );
        },
      ),
    );
  }

  List<Widget> _joinOrCreate(BuildContext context) => [
    TextField(
      controller: _nameController,
      decoration: InputDecoration(
        labelText: context.l10n.listenTogetherGroupName,
        border: const OutlineInputBorder(),
        suffixIcon: IconButton(
          tooltip: context.l10n.listenTogetherCreate,
          icon: const Icon(TablerIcons.plus),
          onPressed: _busy
              ? null
              : () => _run(() async {
                  final name = _nameController.text.trim();
                  await SyncPlayService.createGroup(name.isEmpty ? context.l10n.listenTogether : name);
                }),
        ),
      ),
    ),
    const SizedBox(height: 16),
    Text(context.l10n.listenTogetherGroups, style: Theme.of(context).textTheme.titleMedium),
    FutureBuilder(
      future: _groups,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) return const LinearProgressIndicator();
        if (snapshot.hasError) return Text(snapshot.error.toString());
        final groups = snapshot.data!;
        if (groups.isEmpty) return Text(context.l10n.listenTogetherNoGroups);
        return Column(
          children: [
            for (final group in groups)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(TablerIcons.users_group),
                title: Text(group.name),
                subtitle: Text(group.participants.join(", ")),
                trailing: FilledButton.tonal(
                  onPressed: _busy ? null : () => _run(() => SyncPlayService.joinGroup(group.id)),
                  child: Text(context.l10n.listenTogetherJoin),
                ),
              ),
          ],
        );
      },
    ),
  ];
}

class _GroupCard extends StatelessWidget {
  const _GroupCard({required this.group, required this.busy, required this.run});

  final SyncPlayGroup group;
  final bool busy;
  final Future<void> Function(Future<void> Function()) run;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 8,
          children: [
            Text(group.name, style: textTheme.headlineSmall),
            Text(context.l10n.listenTogetherListeners(group.participants.join(", "))),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  onPressed: busy ? null : () => run(SyncPlayService.previous),
                  icon: const Icon(TablerIcons.player_skip_back),
                ),
                IconButton.filled(
                  iconSize: 32,
                  onPressed: busy ? null : () => run(SyncPlayService.togglePlayback),
                  icon: Icon(SyncPlayService.isPlaying ? TablerIcons.player_pause : TablerIcons.player_play),
                ),
                IconButton(
                  onPressed: busy ? null : () => run(SyncPlayService.next),
                  icon: const Icon(TablerIcons.player_skip_forward),
                ),
              ],
            ),
            FilledButton.icon(
              onPressed: busy ? null : () => run(SyncPlayService.shareCurrentQueue),
              icon: const Icon(TablerIcons.share),
              label: Text(context.l10n.listenTogetherShareQueue),
            ),
            OutlinedButton.icon(
              onPressed: busy ? null : () => run(SyncPlayService.leaveGroup),
              icon: const Icon(TablerIcons.logout),
              label: Text(context.l10n.listenTogetherLeave),
            ),
          ],
        ),
      ),
    );
  }
}
