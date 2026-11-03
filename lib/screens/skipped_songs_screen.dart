import 'package:finamp/components/confirmation_prompt_dialog.dart';
import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/services/skip_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

/// Songs that get skipped often, which mixes play less. Forgetting a song gives it a fresh start.
class SkippedSongsScreen extends StatefulWidget {
  const SkippedSongsScreen({super.key});

  static const routeName = "/settings/skipped";

  @override
  State<SkippedSongsScreen> createState() => _SkippedSongsScreenState();
}

class _SkippedSongsScreenState extends State<SkippedSongsScreen> {
  List<SkipRecord>? _records;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final records = await SkipService.often();
    if (mounted) setState(() => _records = records);
  }

  @override
  Widget build(BuildContext context) {
    final records = _records;
    final now = DateTime.now();
    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.skippedSongs),
        actions: [
          if (records?.isNotEmpty ?? false)
            TextButton(
              onPressed: () async {
                var confirmed = false;
                await showDialog<void>(
                  context: context,
                  builder: (context) => ConfirmationPromptDialog(
                    promptText: context.l10n.skippedSongsForgetAllPrompt,
                    confirmButtonText: context.l10n.skippedSongsForgetAll,
                    onConfirmed: () => confirmed = true,
                  ),
                );
                if (!confirmed) return;
                await SkipService.forgetAll();
                await _load();
              },
              child: Text(context.l10n.skippedSongsForgetAll),
            ),
        ],
      ),
      body: records == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(context.l10n.skippedSongsDescription),
                ),
                if (records.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(32),
                    child: Center(child: Text(context.l10n.skippedSongsNone)),
                  ),
                for (final record in records)
                  ListTile(
                    leading: const Icon(TablerIcons.player_skip_forward),
                    title: Text(record.name),
                    subtitle: Text(
                      [
                        if (record.artist != null) record.artist!,
                        context.l10n.skippedSongsTimes(SkipService.weightOf(record, now).round()),
                      ].join(" · "),
                    ),
                    trailing: IconButton(
                      tooltip: context.l10n.skippedSongsForget,
                      icon: const Icon(TablerIcons.restore),
                      onPressed: () async {
                        await SkipService.forget(record.trackId);
                        await _load();
                      },
                    ),
                  ),
              ],
            ),
    );
  }
}
