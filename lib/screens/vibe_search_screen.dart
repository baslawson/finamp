import 'dart:io';

import 'package:finamp/components/AlbumScreen/track_list_tile.dart';
import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/components/now_playing_bar.dart';
import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/models/music_models.dart';
import 'package:finamp/screens/analyzer_settings_screen.dart';
import 'package:finamp/services/analyzer_service.dart';
import 'package:finamp/services/dj_transition_service.dart';
import 'package:finamp/services/jellyfin_api_helper.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';
import 'package:permission_handler/permission_handler.dart';

/// Loads tracks by id from the server, keeping the given order.
Future<List<BaseItemDto>> _tracksInOrder(List<String> ids) async {
  if (ids.isEmpty) return [];
  final tracks = await GetIt.instance<JellyfinApiHelper>().getItems(itemIds: [for (final id in ids) BaseItemId(id)]) ?? [];
  final byId = {for (final track in tracks) track.id.raw.replaceAll("-", ""): track};
  return [for (final id in ids) ?byId[id.replaceAll("-", "")]];
}

final _vibeResultsProvider = FutureProvider.autoDispose.family<List<BaseItemDto>, String>((ref, description) async {
  final ids = await AnalyzerService.vibe(description);
  return _tracksInOrder(ids);
});

final _analyzerConfiguredProvider = FutureProvider.autoDispose((ref) => AnalyzerService.isConfigured());

/// Shortcuts to vibe search and song recognition, shown on the empty search screen.
class AnalyzerSearchTiles extends ConsumerWidget {
  const AnalyzerSearchTiles({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final configured = ref.watch(_analyzerConfiguredProvider).valueOrNull ?? false;
    void openOrSetUp(VoidCallback open) =>
        configured ? open() : Navigator.of(context).pushNamed(AnalyzerSettingsScreen.routeName);

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Row(
        spacing: 8,
        children: [
          Expanded(
            child: _ShortcutCard(
              icon: TablerIcons.wave_sine,
              label: context.l10n.vibeSearch,
              onTap: () => openOrSetUp(() => Navigator.of(context).pushNamed(VibeSearchScreen.routeName)),
            ),
          ),
          Expanded(
            child: _ShortcutCard(
              icon: TablerIcons.ear,
              label: context.l10n.whatsThisSong,
              onTap: () => openOrSetUp(() => identifySong(context)),
            ),
          ),
        ],
      ),
    );
  }
}

class _ShortcutCard extends StatelessWidget {
  const _ShortcutCard({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          child: Row(
            spacing: 10,
            children: [
              Icon(icon),
              Expanded(child: Text(label, maxLines: 2)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Describe a sound in your own words and get the tracks in your library that sound like it.
class VibeSearchScreen extends ConsumerStatefulWidget {
  const VibeSearchScreen({super.key});

  static const routeName = "/music/search/vibe";

  @override
  ConsumerState<VibeSearchScreen> createState() => _VibeSearchScreenState();
}

class _VibeSearchScreenState extends ConsumerState<VibeSearchScreen> {
  final _controller = TextEditingController();
  String _description = "";

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _search(String description) {
    _controller.text = description;
    setState(() => _description = description.trim());
  }

  QueueItemSource get _source => QueueItemSource.rawId(
    type: QueueItemSourceType.unknown,
    name: QueueItemSourceName(type: QueueItemSourceNameType.preTranslated, pretranslatedName: _description),
    id: "vibe",
  );

  Future<void> _playAll(List<BaseItemDto> tracks) async {
    await GetIt.instance<QueueService>().startPlayback(
      items: await DjTransitionService.smoothOrder(tracks),
      source: _source,
      order: FinampPlaybackOrder.linear,
    );
  }

  @override
  Widget build(BuildContext context) {
    final suggestions = [
      context.l10n.vibeSuggestionDreamy,
      context.l10n.vibeSuggestionHeavy,
      context.l10n.vibeSuggestionAcoustic,
      context.l10n.vibeSuggestionDance,
      context.l10n.vibeSuggestionPiano,
    ];
    final results = _description.isEmpty ? null : ref.watch(_vibeResultsProvider(_description));

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: TextField(
          controller: _controller,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(border: InputBorder.none, hintText: context.l10n.vibeSearchHint),
          onSubmitted: _search,
        ),
      ),
      bottomNavigationBar: const NowPlayingBar(),
      body: results == null
          ? ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(context.l10n.vibeSearchDescription),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final suggestion in suggestions)
                      ActionChip(label: Text(suggestion), onPressed: () => _search(suggestion)),
                  ],
                ),
              ],
            )
          : results.when(
              loading: () => Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 12,
                  children: [const CircularProgressIndicator(), Text(context.l10n.vibeSearching)],
                ),
              ),
              error: (error, _) => Center(
                child: Padding(padding: const EdgeInsets.all(24), child: Text(error.toString())),
              ),
              data: (tracks) => tracks.isEmpty
                  ? Center(child: Text(context.l10n.vibeNoResults))
                  : ListView.builder(
                      padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom + 96),
                      itemCount: tracks.length + 1,
                      itemBuilder: (context, index) {
                        if (index == 0) {
                          return Padding(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                            child: FilledButton.icon(
                              onPressed: () => _playAll(tracks).catchError(GlobalSnackbar.error),
                              icon: const Icon(TablerIcons.player_play),
                              label: Text(context.l10n.vibePlayAll),
                            ),
                          );
                        }
                        final track = tracks[index - 1];
                        return TrackListTile(
                          key: ValueKey(track.id),
                          item: track,
                          index: index - 1,
                          allowDismiss: false,
                          parentPlayable: PrecalculatedPlayable(source: _source, tracks: tracks),
                        );
                      },
                    ),
            ),
    );
  }
}

const _recorder = MethodChannel("com.unicornsonlsd.finamp/recorder");
const _recordingSeconds = 10;

/// Listens to a song playing nearby and finds it in the library.
Future<void> identifySong(BuildContext context) async {
  if (!await Permission.microphone.request().isGranted) {
    GlobalSnackbar.message((context) => context.l10n.whatsThisSongNeedsMicrophone);
    return;
  }
  if (!context.mounted) return;
  await showDialog<void>(context: context, barrierDismissible: false, builder: (_) => const _IdentifyDialog());
}

class _IdentifyDialog extends StatefulWidget {
  const _IdentifyDialog();

  @override
  State<_IdentifyDialog> createState() => _IdentifyDialogState();
}

class _IdentifyDialogState extends State<_IdentifyDialog> {
  bool _listening = true;
  BaseItemDto? _match;
  String? _error;

  @override
  void initState() {
    super.initState();
    _identify();
  }

  Future<void> _identify() async {
    try {
      final path = await _recorder.invokeMethod<String>("record", {"seconds": _recordingSeconds});
      if (mounted) setState(() => _listening = false);
      final file = File(path!);
      final id = await AnalyzerService.identify(await file.readAsBytes());
      await file.delete();
      final tracks = id == null ? <BaseItemDto>[] : await _tracksInOrder([id]);
      if (!mounted) return;
      setState(() {
        _match = tracks.firstOrNull;
        if (_match == null) _error = context.l10n.whatsThisSongNoMatch;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final match = _match;
    return AlertDialog(
      title: Text(context.l10n.whatsThisSong),
      content: match != null
          ? ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(TablerIcons.music),
              title: Text(match.name ?? ""),
              subtitle: Text([match.albumArtist, match.album].nonNulls.join(" · ")),
            )
          : _error != null
          ? Text(_error!)
          : Row(
              spacing: 16,
              children: [
                const CircularProgressIndicator(),
                Expanded(child: Text(_listening ? context.l10n.whatsThisSongListening : context.l10n.whatsThisSongMatching)),
              ],
            ),
      actions: [
        TextButton(
          onPressed: _match == null && _error == null ? null : () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).closeButtonLabel),
        ),
        if (match != null)
          FilledButton.icon(
            onPressed: () {
              Navigator.of(context).pop();
              GetIt.instance<QueueService>()
                  .startPlayback(
                    items: [match],
                    source: QueueItemSource.fromBaseItem(match),
                    order: FinampPlaybackOrder.linear,
                  )
                  .catchError(GlobalSnackbar.error);
            },
            icon: const Icon(TablerIcons.player_play),
            label: Text(context.l10n.whatsThisSongPlay),
          ),
      ],
    );
  }
}
