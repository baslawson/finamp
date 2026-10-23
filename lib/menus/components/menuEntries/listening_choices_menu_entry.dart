import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/menus/components/menuEntries/menu_entry.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/screens/listening_enhancements_screen.dart';
import 'package:finamp/services/artist_spacing.dart';
import 'package:finamp/services/listening_preferences.dart';
import 'package:flutter/material.dart';

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
                  for (final rest in ListeningPreferences.rests.where(
                    (r) =>
                        r.key == 'track:${widget.item.id.raw}' ||
                        r.key == 'artist:${ArtistSpacing.artistKey(widget.item)}',
                  ))
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        context.l10n.listeningRestUntil(
                          MaterialLocalizations.of(context).formatMediumDate(rest.until.toLocal()),
                        ),
                        style: TextStyle(color: Theme.of(context).colorScheme.primary),
                      ),
                    ),
                  for (final artist in [false, if (ArtistSpacing.artistKey(widget.item) != null) true]) ...[
                    Text(
                      artist ? context.l10n.listeningRestArtist : context.l10n.listeningRestSong,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final days in [1, 7, 30])
                          ActionChip(
                            label: Text(context.l10n.listeningRestDays(days)),
                            onPressed: _busy
                                ? null
                                : () => _save(() => ListeningPreferences.rest(widget.item, artist: artist, days: days)),
                          ),
                      ],
                    ),
                  ],
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
