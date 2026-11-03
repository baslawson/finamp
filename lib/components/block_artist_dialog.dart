import 'dart:async';
import 'dart:math';

import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/l10n/app_localizations.dart';
import 'package:finamp/services/listening_preferences.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

/// How long to block an artist for.
enum BlockLength { day, week, month, threeMonths, forever }

/// When a block of [length] from [now] ends ([ListeningRest.forever] for good). Months are calendar months, ending on
/// the last day of a shorter one (31 January, a month: 28 February).
DateTime blockEnd(BlockLength length, DateTime now) => switch (length) {
  BlockLength.day => now.add(const Duration(days: 1)),
  BlockLength.week => now.add(const Duration(days: 7)),
  BlockLength.month => _monthsOn(now, 1),
  BlockLength.threeMonths => _monthsOn(now, 3),
  BlockLength.forever => ListeningRest.forever,
};

DateTime _monthsOn(DateTime now, int months) {
  final lastDay = DateTime(now.year, now.month + months + 1, 0).day;
  return DateTime(now.year, now.month + months, min(now.day, lastDay), now.hour, now.minute);
}

/// "Blocked until Tue 4 Nov, 18:00", or "Blocked for good".
String blockedText(BuildContext context, ListeningRest rest) {
  if (rest.isForever) return context.l10n.blockedForever;
  return context.l10n.blockedUntil(whenText(context, rest.until));
}

/// [at] as a date and time, in the listener's own format.
String whenText(BuildContext context, DateTime at) {
  final local = at.toLocal(), material = MaterialLocalizations.of(context);
  return "${material.formatMediumDate(local)}, ${material.formatTimeOfDay(TimeOfDay.fromDateTime(local), alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context))}";
}

/// Opens the choice of how long to block [artists] for (which of them, when there are several), blocks them and takes
/// their songs out of the queue where blocks apply. True once something was blocked or unblocked.
Future<bool> showBlockArtistDialog(BuildContext context, List<BlockableArtist> artists) async {
  if (artists.isEmpty) return false;
  await ListeningPreferences.ensureLoaded();
  if (!context.mounted) return false;
  final changed = await showDialog<bool>(
    context: context,
    builder: (_) => BlockArtistDialog(artists: artists),
  );
  return changed ?? false;
}

class BlockArtistDialog extends StatefulWidget {
  const BlockArtistDialog({super.key, required this.artists});

  /// The artists to choose from; the first is chosen to begin with.
  final List<BlockableArtist> artists;

  @override
  State<BlockArtistDialog> createState() => _BlockArtistDialogState();
}

class _BlockArtistDialogState extends State<BlockArtistDialog> {
  late final _chosen = {widget.artists.first};
  var _busy = false;

  Future<void> _block(DateTime until) async {
    final chosen = [
      for (final artist in widget.artists)
        if (_chosen.contains(artist)) artist,
    ];
    if (chosen.isEmpty) return;
    setState(() => _busy = true);
    // Only a new block takes songs out of the queue: one chosen to play though blocked stays when its time changes.
    final newly = [
      for (final artist in chosen)
        if (ListeningPreferences.blockOf(artist) == null) artist,
    ];
    try {
      await ListeningPreferences.blockArtists(chosen, until);
      final names = chosen.map((artist) => artist.name).join(", ");
      GlobalSnackbar.message(
        (context) => until == ListeningRest.forever
            ? AppLocalizations.of(context)!.blockedDoneForever(names)
            : AppLocalizations.of(context)!.blockedDone(names, whenText(context, until)),
        isConfirmation: true,
      );
      if (mounted) Navigator.of(context).pop(true);
      if (GetIt.instance.isRegistered<QueueService>()) {
        await GetIt.instance<QueueService>().leaveOutBlocked(artists: newly);
      }
    } catch (e) {
      GlobalSnackbar.error(e);
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _unblock(List<ListeningRest> blocks) async {
    setState(() => _busy = true);
    try {
      for (final block in blocks) {
        await ListeningPreferences.removeRest(block.key);
      }
      final names = blocks.map((block) => block.name).join(", ");
      GlobalSnackbar.message((context) => AppLocalizations.of(context)!.unblockedDone(names), isConfirmation: true);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      GlobalSnackbar.error(e);
      if (mounted) setState(() => _busy = false);
    }
  }

  /// A date and then a time, in the future; null when either is cancelled.
  Future<DateTime?> _pickCustom() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: DateTime(now.year + 5, now.month, now.day),
      initialDate: now.add(const Duration(days: 1)),
    );
    if (date == null || !mounted) return null;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(now.add(const Duration(hours: 1))),
    );
    if (time == null || !mounted) return null;
    final until = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    if (!until.isAfter(DateTime.now())) {
      GlobalSnackbar.message((context) => AppLocalizations.of(context)!.blockCustomPast);
      return null;
    }
    return until;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final several = widget.artists.length > 1;
    // With several, the chosen ones are unblocked.
    final blocks = [
      for (final artist in widget.artists)
        if (!several || _chosen.contains(artist)) ?ListeningPreferences.blockOf(artist),
    ];
    return AlertDialog(
      title: Text(several ? l10n.blockArtistsTitle : l10n.blockArtistTitle(widget.artists.single.name)),
      content: SizedBox(
        width: 450,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.blockArtistHelp),
              const SizedBox(height: 8),
              if (several)
                for (final artist in widget.artists)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _chosen.contains(artist),
                    title: Text(artist.name),
                    subtitle: switch (ListeningPreferences.blockOf(artist)) {
                      final block? => Text(blockedText(context, block)),
                      null => null,
                    },
                    onChanged: _busy
                        ? null
                        : (chosen) => setState(() => (chosen ?? false) ? _chosen.add(artist) : _chosen.remove(artist)),
                  )
              else if (blocks.firstOrNull case final block?)
                Text(blockedText(context, block), style: TextStyle(color: Theme.of(context).colorScheme.primary)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final length in BlockLength.values)
                    ActionChip(
                      label: Text(switch (length) {
                        BlockLength.day => l10n.blockForDay,
                        BlockLength.week => l10n.blockForWeek,
                        BlockLength.month => l10n.blockForMonth,
                        BlockLength.threeMonths => l10n.blockForThreeMonths,
                        BlockLength.forever => l10n.blockForever,
                      }),
                      onPressed: _busy || _chosen.isEmpty ? null : () => _block(blockEnd(length, DateTime.now())),
                    ),
                  ActionChip(
                    avatar: const Icon(Icons.event, size: 18),
                    label: Text(l10n.blockCustom),
                    onPressed: _busy || _chosen.isEmpty
                        ? null
                        : () async {
                            final until = await _pickCustom();
                            if (until != null) await _block(until);
                          },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        if (blocks.isNotEmpty)
          TextButton(onPressed: _busy ? null : () => unawaited(_unblock(blocks)), child: Text(l10n.unblock)),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
      ],
    );
  }
}
