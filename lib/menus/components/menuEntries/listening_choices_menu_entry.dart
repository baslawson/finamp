import 'package:finamp/components/block_artist_dialog.dart';
import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/menus/components/menuEntries/menu_entry.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/screens/listening_enhancements_screen.dart';
import 'package:finamp/services/listening_preferences.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

class ListeningChoicesMenuEntry extends StatelessWidget implements HideableMenuEntry {
  const ListeningChoicesMenuEntry({super.key, required this.item});
  final BaseItemDto item;
  @override
  bool get isVisible => true;
  @override
  Widget build(BuildContext context) => MenuEntry(
    icon: Icons.tune,
    title: context.l10n.listeningSongOptions,
    onTap: () => showDialog<void>(
      context: context,
      builder: (_) => ListeningChoicesDialog(item: item),
    ),
  );
}

class ListeningChoicesDialog extends StatefulWidget {
  const ListeningChoicesDialog({super.key, required this.item});
  final BaseItemDto item;
  @override
  State<ListeningChoicesDialog> createState() => _ListeningChoicesDialogState();
}

class _ListeningChoicesDialogState extends State<ListeningChoicesDialog> {
  bool _ready = false, _busy = false;
  @override
  void initState() {
    super.initState();
    ListeningPreferences.ensureLoaded()
        .then((_) {
          if (mounted) setState(() => _ready = true);
        })
        .catchError((Object e) => GlobalSnackbar.error(e));
  }

  Future<void> _save(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      GlobalSnackbar.error(e);
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.item.name ?? context.l10n.listeningSongOptions),
    content: !_ready
        ? const SizedBox(height: 80, child: Center(child: CircularProgressIndicator()))
        : SizedBox(
            width: 450,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DropdownButton<SongTransition>(
                    isExpanded: true,
                    itemHeight: null,
                    value: ListeningPreferences.transition(widget.item.id.raw),
                    items: [
                      for (final mode in SongTransition.values)
                        DropdownMenuItem(
                          value: mode,
                          child: Text(switch (mode) {
                            SongTransition.automatic => context.l10n.listeningTransitionAuto,
                            SongTransition.fullEnding => context.l10n.listeningTransitionFull,
                            SongTransition.shortFade => context.l10n.listeningTransitionShort,
                            SongTransition.gapless => context.l10n.listeningTransitionGapless,
                          }),
                        ),
                    ],
                    onChanged: _busy
                        ? null
                        : (v) => _save(() => ListeningPreferences.setTransition(widget.item.id.raw, v!)),
                  ),
                  Text(context.l10n.listeningTransitionDescription),
                  const SizedBox(height: 16),
                  Text(context.l10n.listeningRestDescription),
                  for (final rest in ListeningPreferences.restsFor(widget.item))
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        rest.artist
                            ? "${rest.name}: ${blockedText(context, rest)}"
                            : context.l10n.listeningRestUntil(whenText(context, rest.until)),
                        style: TextStyle(color: Theme.of(context).colorScheme.primary),
                      ),
                    ),
                  Text(context.l10n.listeningRestSong, style: Theme.of(context).textTheme.titleSmall),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final days in [1, 7, 30])
                        ActionChip(
                          label: Text(context.l10n.listeningRestDays(days)),
                          onPressed: _busy
                              ? null
                              : () => _save(() async {
                                  await ListeningPreferences.rest(widget.item, artist: false, days: days);
                                  if (GetIt.instance.isRegistered<QueueService>()) {
                                    await GetIt.instance<QueueService>().leaveOutBlocked(track: widget.item.id);
                                  }
                                }),
                        ),
                    ],
                  ),
                  if (ListeningPreferences.artistsOf(widget.item) case final artists when artists.isNotEmpty)
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: TextButton.icon(
                        icon: const Icon(Icons.block),
                        label: Text(context.l10n.blockSongArtist),
                        onPressed: _busy
                            ? null
                            : () async {
                                await showBlockArtistDialog(context, artists);
                                if (mounted) setState(() {});
                              },
                      ),
                    ),
                  TextButton(
                    onPressed: () {
                      Navigator.of(context).pop();
                      Navigator.of(context).pushNamed(ListeningEnhancementsScreen.routeName);
                    },
                    child: Text(context.l10n.listeningManage),
                  ),
                ],
              ),
            ),
          ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: Text(MaterialLocalizations.of(context).closeButtonLabel),
      ),
    ],
  );
}
