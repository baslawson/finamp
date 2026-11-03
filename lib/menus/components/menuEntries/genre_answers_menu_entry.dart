import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/menus/components/menuEntries/menu_entry.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/analyzer_service.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:finamp/services/genre_fit.dart';
import 'package:finamp/services/genre_mix.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

/// Whether answers about genres can be given: they're kept by the analyzer, and genre mixes use them with "Match the
/// sound" on.
final _genreAnswersAvailableProvider = FutureProvider.autoDispose(
  (ref) async => await AnalyzerService.isConfigured() && await GenreFit.isEnabled(),
);

/// The genre mix a song in the queue (or, without one, the song playing) was picked for, if any.
final _genreMixProvider = FutureProvider.autoDispose.family<String?, FinampQueueItem?>(
  (ref, queueItem) => GenreMix.current(item: queueItem),
);

/// "Doesn't fit Rock": during a genre mix, says this song isn't the genre, so it leaves this mix and future ones, and
/// the genre's sound is learned from it.
class DoesntFitGenreMenuEntry extends ConsumerWidget implements HideableMenuEntry {
  const DoesntFitGenreMenuEntry({super.key, required this.item, this.queueItem});

  final BaseItemDto item;

  /// The song in the queue, to take out of it.
  final FinampQueueItem? queueItem;

  @override
  bool get isVisible => true;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final available = ref.watch(_genreAnswersAvailableProvider).valueOrNull ?? false;
    final genre = ref.watch(_genreMixProvider(queueItem)).valueOrNull;
    if (!available || genre == null || item.type != "Audio" || ref.watch(finampSettingsProvider.isOffline)) {
      return const SizedBox.shrink();
    }
    return MenuEntry(
      icon: TablerIcons.mood_empty,
      title: context.l10n.genreDoesntFit(GenreMix.displayName(genre)),
      onTap: () async {
        Navigator.pop(context); // close menu
        try {
          await GenreFit.teach(item.id.raw, genre, false);
        } catch (e) {
          GlobalSnackbar.error(e);
          return;
        }
        final queueService = GetIt.instance<QueueService>();
        final queued = queueItem;
        if (queued != null) {
          // The song playing is skipped (and stays in what's been played); a later one leaves the queue.
          if (queueService.getQueue().getOffsetForQueueItem(queued) == 0) {
            await queueService.skipByOffset(1);
          } else {
            await queueService.removeQueueItem(queued);
          }
        }
        GlobalSnackbar.message(
          (context) => context.l10n.genreDoesntFitDone(GenreMix.displayName(genre)),
          isConfirmation: true,
        );
      },
    );
  }
}

/// "Genre…": says which genres a song is and isn't, playing or not. Genre mixes follow the answers and learn each
/// genre's sound from them.
class GenreAnswersMenuEntry extends ConsumerWidget implements HideableMenuEntry {
  const GenreAnswersMenuEntry({super.key, required this.item});

  final BaseItemDto item;

  @override
  bool get isVisible => true;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final available = ref.watch(_genreAnswersAvailableProvider).valueOrNull ?? false;
    if (!available || item.type != "Audio") return const SizedBox.shrink();
    final offline = ref.watch(finampSettingsProvider.isOffline);
    return MenuEntry(
      icon: TablerIcons.tags,
      title: context.l10n.genreAnswersAction,
      enabled: !offline,
      tooltip: offline ? context.l10n.notAvailableInOfflineMode : null,
      onTap: () => showDialog<void>(
        context: context,
        builder: (_) => GenreAnswersDialog(item: item),
      ),
    );
  }
}

class GenreAnswersDialog extends StatefulWidget {
  const GenreAnswersDialog({super.key, required this.item});

  final BaseItemDto item;

  /// The genres to show: first the ones [answered] that aren't among the [choices] (such as Radio's picked genres
  /// together), so those answers can be changed too, then the [choices]; only the ones matching [search].
  static List<String> genresToShow({
    required List<String> choices,
    required Iterable<String> answered,
    String search = "",
  }) {
    final known = {for (final choice in choices) GenreFit.keyOf(choice)};
    final wanted = search.trim().toLowerCase();
    return [
      for (final genre in [
        for (final genre in answered)
          if (!known.contains(GenreFit.keyOf(genre))) genre,
        ...choices,
      ])
        if (wanted.isEmpty || GenreMix.displayName(genre).toLowerCase().contains(wanted)) genre,
    ];
  }

  @override
  State<GenreAnswersDialog> createState() => _GenreAnswersDialogState();
}

class _GenreAnswersDialogState extends State<GenreAnswersDialog> {
  List<GenreChoice>? _choices;

  /// The genres answered about when the dialog opened, which stay listed while their answers change.
  Iterable<String> _answered = const [];

  /// The answers so far, by genre key ([GenreFit.keyOf]).
  Map<String, bool> _answers = {};
  String _search = "";
  Object? _error;

  /// Genres being saved, which can't be changed again until they are.
  final Set<String> _saving = {};

  @override
  void initState() {
    super.initState();
    () async {
      try {
        final (choices, answers) = (
          await loadGenreChoices(),
          await AnalyzerService.genreLabelsOfSong(widget.item.id.raw),
        );
        if (mounted) {
          setState(() {
            _choices = choices.choices;
            _answers = answers;
            _answered = answers.keys.toList();
          });
        }
      } catch (e) {
        if (mounted) setState(() => _error = e);
      }
    }();
  }

  /// Cycles the answer for [genre]: none, it is, it isn't, none again.
  Future<void> _cycle(String genre) async {
    final key = GenreFit.keyOf(genre);
    final next = switch (_answers[key]) {
      null => true,
      true => false,
      false => null,
    };
    final before = _answers[key];
    setState(() {
      _saving.add(key);
      next == null ? _answers.remove(key) : _answers[key] = next;
    });
    try {
      await GenreFit.teach(widget.item.id.raw, genre, next);
    } catch (e) {
      GlobalSnackbar.error(e);
      if (mounted) setState(() => before == null ? _answers.remove(key) : _answers[key] = before);
    } finally {
      if (mounted) setState(() => _saving.remove(key));
    }
  }

  @override
  Widget build(BuildContext context) {
    final tags = widget.item.genres ?? const <String>[];
    final choices = _choices;
    final shown = GenreAnswersDialog.genresToShow(
      choices: [...?choices?.map((choice) => choice.name)],
      answered: _answered,
      search: _search,
    );
    return AlertDialog(
      title: Text(context.l10n.genreAnswersTitle(widget.item.name ?? "")),
      content: SizedBox(
        width: 450,
        child: _error != null
            ? Text(context.l10n.genreAnswersUnavailable)
            : choices == null
            ? const SizedBox(height: 80, child: Center(child: CircularProgressIndicator()))
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 8.0,
                children: [
                  Text(context.l10n.genreAnswersHelp),
                  if (tags.isNotEmpty)
                    Text(
                      context.l10n.genreAnswersTagged(tags.join(", ")),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  if (choices.length > 12)
                    TextField(
                      decoration: InputDecoration(
                        prefixIcon: const Icon(TablerIcons.search),
                        hintText: context.l10n.genreAnswersSearch,
                        isDense: true,
                      ),
                      onChanged: (value) => setState(() => _search = value),
                    ),
                  Flexible(
                    child: SingleChildScrollView(
                      child: Wrap(
                        spacing: 8.0,
                        runSpacing: 4.0,
                        children: [for (final genre in shown) _chip(context, genre)],
                      ),
                    ),
                  ),
                ],
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

  Widget _chip(BuildContext context, String genre) {
    final key = GenreFit.keyOf(genre);
    final name = GenreMix.displayName(genre);
    final answer = _answers[key];
    final scheme = ColorScheme.of(context);
    return FilterChip(
      label: Text(name),
      selected: answer != null,
      showCheckmark: false,
      avatar: answer == null ? null : Icon(answer ? TablerIcons.check : TablerIcons.x, size: 18.0),
      selectedColor: answer == false ? scheme.errorContainer : null,
      tooltip: switch (answer) {
        null => context.l10n.genreAnswersNone(name),
        true => context.l10n.genreAnswersIs(name),
        false => context.l10n.genreAnswersIsnt(name),
      },
      onSelected: _saving.contains(key) ? null : (_) => _cycle(genre),
    );
  }
}
