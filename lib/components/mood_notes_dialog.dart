import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/services/mood_notes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

/// "Songs left out (3)": opens the songs said not to fit an AI DJ mix. Hidden while there are none.
class MoodNotesButton extends StatefulWidget {
  const MoodNotesButton({super.key});

  @override
  State<MoodNotesButton> createState() => _MoodNotesButtonState();
}

class _MoodNotesButtonState extends State<MoodNotesButton> {
  int _count = 0;

  @override
  void initState() {
    super.initState();
    MoodNotes.changed.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    MoodNotes.changed.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final count = (await MoodNotes.load()).length;
    if (mounted) setState(() => _count = count);
  }

  @override
  Widget build(BuildContext context) {
    if (_count == 0) return const SizedBox.shrink();
    return TextButton.icon(
      icon: const Icon(TablerIcons.mood_off),
      label: Text(context.l10n.moodNotesButton(_count)),
      onPressed: () => showDialog<void>(context: context, builder: (_) => const MoodNotesDialog()),
    );
  }
}

/// The songs said not to fit an AI DJ mix, each with what that mix was asked for, to remove one or all.
class MoodNotesDialog extends StatefulWidget {
  const MoodNotesDialog({super.key});

  @override
  State<MoodNotesDialog> createState() => _MoodNotesDialogState();
}

class _MoodNotesDialogState extends State<MoodNotesDialog> {
  List<MoodNote>? _notes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final notes = (await MoodNotes.load()).reversed.toList();
    if (mounted) setState(() => _notes = notes);
  }

  @override
  Widget build(BuildContext context) {
    final notes = _notes;
    return AlertDialog(
      title: Text(context.l10n.moodNotesTitle),
      content: SizedBox(
        width: 450,
        child: notes == null
            ? const SizedBox(height: 80, child: Center(child: CircularProgressIndicator()))
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 8.0,
                children: [
                  Text(context.l10n.moodNotesHelp),
                  if (notes.isEmpty) Text(context.l10n.moodNotesEmpty),
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final note in notes)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(note.artist.isEmpty ? note.title : "${note.title} · ${note.artist}"),
                            subtitle: Text(context.l10n.moodNotesFor(note.request)),
                            trailing: IconButton(
                              tooltip: context.l10n.moodNotesRemove,
                              icon: const Icon(TablerIcons.x),
                              onPressed: () async {
                                await MoodNotes.remove(note.trackId);
                                await _load();
                              },
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
      ),
      actions: [
        if (notes?.isNotEmpty ?? false)
          TextButton(
            onPressed: () async {
              await MoodNotes.clear();
              await _load();
            },
            child: Text(context.l10n.moodNotesClear),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).closeButtonLabel),
        ),
      ],
    );
  }
}
