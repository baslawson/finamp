import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/services/running_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:rxdart/rxdart.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// Running mode: music that follows your steps.
class RunningScreen extends StatefulWidget {
  const RunningScreen({super.key});

  static const routeName = "/running";

  @override
  State<RunningScreen> createState() => _RunningScreenState();
}

class _RunningScreenState extends State<RunningScreen> {
  bool _sensor = true;
  bool _manual = false;
  bool _starting = false;
  double _manualPace = RunningService.defaultPace;

  @override
  void initState() {
    super.initState();
    RunningService.sensorAvailable().then((available) {
      if (mounted) setState(() => _sensor = available);
    });
    WakelockPlus.enable();
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() => _starting = true);
    try {
      await RunningService.start(manualPace: _manual || !_sensor ? _manualPace : null);
    } on RunningException catch (e) {
      GlobalSnackbar.message(
        (context) => switch (e.problem) {
          RunningProblem.noTempos => context.l10n.runningNoTempos,
          RunningProblem.noSongs => context.l10n.runningNoSongs,
        },
      );
    } catch (e) {
      GlobalSnackbar.error(e);
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final textTheme = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.runningMode)),
      body:
          StreamBuilder<(bool, double, double?, double?)>(
            stream: Rx.combineLatest4(
              RunningService.active,
              RunningService.pace,
              RunningService.cadence,
              RunningService.currentTempo,
              (active, pace, cadence, tempo) => (active, pace, cadence, tempo),
            ),
            builder: (context, snapshot) {
              final (active, pace, cadence, tempo) = snapshot.data ?? (false, RunningService.defaultPace, null, null);
              final followsSteps = _sensor && !_manual;
              return ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  Text(l10n.runningDescription),
                  const SizedBox(height: 32),
                  Center(
                    child: Column(
                      children: [
                        Text(
                          (active || followsSteps ? pace : _manualPace).round().toString(),
                          style: textTheme.displayLarge?.copyWith(fontWeight: FontWeight.bold, color: colors.primary),
                        ),
                        Text(l10n.runningStepsPerMinute, style: textTheme.titleMedium),
                        const SizedBox(height: 16),
                        Wrap(
                          spacing: 24,
                          children: [
                            if (followsSteps)
                              _Stat(
                                icon: TablerIcons.shoe,
                                label: l10n.runningMeasured,
                                value: cadence == null ? "–" : cadence.round().toString(),
                              ),
                            _Stat(
                              icon: TablerIcons.metronome,
                              label: l10n.runningSongTempo,
                              value: tempo == null ? "–" : "${tempo.round()} BPM",
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  if (_sensor)
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(l10n.runningSetPaceManually),
                      subtitle: Text(l10n.runningSetPaceManuallyDescription),
                      value: _manual,
                      onChanged: (manual) {
                        setState(() => _manual = manual);
                        if (active && manual) RunningService.setManualPace(_manualPace);
                      },
                    )
                  else
                    Text(l10n.runningNoSensor, style: textTheme.bodySmall),
                  if (!followsSteps) ...[
                    Slider(
                      value: _manualPace,
                      min: 100,
                      max: 200,
                      divisions: 20,
                      label: _manualPace.round().toString(),
                      onChanged: (value) => setState(() => _manualPace = value),
                      onChangeEnd: (value) {
                        if (active) RunningService.setManualPace(value);
                      },
                    ),
                  ],
                  const SizedBox(height: 16),
                  active
                      ? OutlinedButton.icon(
                          onPressed: RunningService.stop,
                          icon: const Icon(TablerIcons.player_stop),
                          label: Text(l10n.runningStop),
                        )
                      : FilledButton.icon(
                          onPressed: _starting ? null : _start,
                          icon: _starting
                              ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(TablerIcons.run),
                          label: Text(_starting ? l10n.runningPreparing : l10n.runningStart),
                        ),
                ],
              );
            },
          ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.icon, required this.label, required this.value});

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(icon),
        Text(value, style: Theme.of(context).textTheme.titleLarge),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}
