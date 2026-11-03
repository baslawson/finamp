import 'dart:async';

import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/services/alarm_service.dart';
import 'package:finamp/services/current_track_metadata_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

/// Shown while the alarm plays: wake up, snooze or stop.
class AlarmRingingScreen extends ConsumerStatefulWidget {
  const AlarmRingingScreen({super.key});

  static const routeName = "/alarm/ringing";

  @override
  ConsumerState<AlarmRingingScreen> createState() => _AlarmRingingScreenState();
}

class _AlarmRingingScreenState extends ConsumerState<AlarmRingingScreen> {
  late final Timer _clock;
  DateTime _now = DateTime.now();
  bool _handled = false;

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(seconds: 10), (_) => setState(() => _now = DateTime.now()));
  }

  @override
  void dispose() {
    _clock.cancel();
    // Leaving the screen any other way counts as being awake.
    if (!_handled) unawaited(AlarmService.wakeUp());
    super.dispose();
  }

  Future<void> _act(Future<void> Function() action) async {
    _handled = true;
    await action();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final track = ref.watch(currentTrackProvider).valueOrNull?.baseItem;
    final textTheme = Theme.of(context).textTheme;
    final time = TimeOfDay.fromDateTime(_now).format(context);

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const Spacer(),
              Icon(TablerIcons.sun_high, size: 64, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 16),
              Text(time, style: textTheme.displayLarge?.copyWith(fontWeight: FontWeight.bold)),
              Text(context.l10n.alarmGoodMorning, style: textTheme.headlineSmall),
              const SizedBox(height: 24),
              if (track != null) ...[
                Text(track.name ?? "", style: textTheme.titleLarge, textAlign: TextAlign.center, maxLines: 2),
                Text(
                  track.albumArtist ?? track.artists?.firstOrNull ?? "",
                  style: textTheme.titleMedium,
                  textAlign: TextAlign.center,
                ),
              ],
              const Spacer(),
              SizedBox(
                width: double.infinity,
                height: 64,
                child: FilledButton.icon(
                  onPressed: () => _act(AlarmService.wakeUp),
                  icon: const Icon(TablerIcons.mood_smile),
                  label: Text(context.l10n.alarmImUp, style: const TextStyle(fontSize: 20)),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                spacing: 12,
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 56,
                      child: FilledButton.tonalIcon(
                        onPressed: () => _act(() async {
                          final next = await AlarmService.snooze();
                          GlobalSnackbar.message(
                            (context) => context.l10n.alarmSnoozedUntil(TimeOfDay.fromDateTime(next).format(context)),
                          );
                        }),
                        icon: const Icon(TablerIcons.zzz),
                        label: Text(context.l10n.alarmSnooze(AlarmService.snoozeMinutes)),
                      ),
                    ),
                  ),
                  Expanded(
                    child: SizedBox(
                      height: 56,
                      child: OutlinedButton.icon(
                        onPressed: () => _act(AlarmService.stop),
                        icon: const Icon(TablerIcons.player_stop),
                        label: Text(context.l10n.alarmStop),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
