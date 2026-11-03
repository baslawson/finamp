import 'dart:async';

import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/services/dj_voice_service.dart';
import 'package:finamp/services/dj_voice_preferences.dart';
import 'package:finamp/components/global_snackbar.dart';
import 'package:flutter/material.dart';

/// The same voice controls in Settings and the player's quick panel. Sliders
/// update their labels while dragging and persist once the drag ends.
class DjVoiceControls extends StatefulWidget {
  const DjVoiceControls({
    super.key,
    required this.settings,
    required this.onChanged,
    this.enabled = true,
    this.station = false,
    this.randomTiming = false,
    this.onRandomTimingChanged,
    this.showTiming = true,
    this.showVolume = true,
  });

  final DjVoiceSettings settings;
  final Future<void> Function(DjVoiceSettings settings) onChanged;
  final bool enabled;
  final bool station;
  final bool randomTiming;
  final Future<void> Function(bool)? onRandomTimingChanged;
  final bool showTiming;
  final bool showVolume;

  @override
  State<DjVoiceControls> createState() => _DjVoiceControlsState();
}

class _DjVoiceControlsState extends State<DjVoiceControls> {
  late DjVoiceSettings _draft = widget.settings;

  @override
  void didUpdateWidget(covariant DjVoiceControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.settings != widget.settings) _draft = widget.settings;
  }

  DjVoiceSettings _copy({DjVoiceMode? mode, int? every, double? volume}) => (
    mode: mode ?? _draft.mode,
    every: every ?? _draft.every,
    character: _draft.character,
    aiVoice: _draft.aiVoice,
    volume: volume ?? _draft.volume,
  );

  void _save(DjVoiceSettings settings) {
    setState(() => _draft = settings);
    unawaited(widget.onChanged(settings));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final textTheme = Theme.of(context).textTheme;
    final labels = {
      DjVoiceMode.off: l10n.djVoiceOff,
      if (!widget.station) DjVoiceMode.aiDjOnly: l10n.djVoiceAiDjOnly,
      DjVoiceMode.always: widget.station ? l10n.djVoiceOn : l10n.djVoiceAlways,
    };
    final selectedMode = widget.station && _draft.mode == DjVoiceMode.aiDjOnly ? DjVoiceMode.off : _draft.mode;
    final enabled = widget.enabled && selectedMode != DjVoiceMode.off;
    final frequency = l10n.djVoiceEvery(_draft.every);
    final volume = l10n.djVoiceVolume((_draft.volume * 100).round());
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.showTiming) ...[
          Text(l10n.djVoiceWhen, style: textTheme.titleMedium),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth < 360 || MediaQuery.textScalerOf(context).scale(14) > 18) {
                return DropdownButtonFormField<DjVoiceMode>(
                  initialValue: selectedMode,
                  key: ValueKey(selectedMode),
                  isExpanded: true,
                  decoration: InputDecoration(labelText: l10n.djVoiceWhen),
                  items: [
                    for (final entry in labels.entries) DropdownMenuItem(value: entry.key, child: Text(entry.value)),
                  ],
                  onChanged: !widget.enabled
                      ? null
                      : (mode) {
                          if (mode != null) _save(_copy(mode: mode));
                        },
                );
              }
              return SegmentedButton<DjVoiceMode>(
                segments: [
                  for (final entry in labels.entries) ButtonSegment(value: entry.key, label: Text(entry.value)),
                ],
                selected: {selectedMode},
                onSelectionChanged: !widget.enabled ? null : (selection) => _save(_copy(mode: selection.first)),
              );
            },
          ),
          const SizedBox(height: 16),
          if (widget.onRandomTimingChanged != null)
            SwitchListTile(
              key: const ValueKey('djRandomTiming'),
              contentPadding: EdgeInsets.zero,
              title: Text(l10n.djRandomTiming),
              subtitle: Text(l10n.djRandomTimingHelp),
              value: widget.randomTiming,
              onChanged: widget.enabled ? (value) => unawaited(widget.onRandomTimingChanged!(value)) : null,
            ),
          if (!widget.randomTiming) ...[
            Text(frequency, style: textTheme.titleMedium),
            Slider(
              key: const ValueKey('djVoiceEvery'),
              value: _draft.every.toDouble(),
              min: 1,
              max: 10,
              divisions: 9,
              label: frequency,
              semanticFormatterCallback: (value) => l10n.djVoiceEvery(value.round()),
              onChanged: enabled ? (value) => setState(() => _draft = _copy(every: value.round())) : null,
              onChangeEnd: enabled ? (value) => _save(_copy(every: value.round())) : null,
            ),
          ],
        ],
        if (widget.showVolume) ...[
          Text(volume, style: textTheme.titleMedium),
          Slider(
            key: const ValueKey('djVoiceVolume'),
            value: _draft.volume,
            min: 0.1,
            max: 1,
            divisions: 18,
            label: volume,
            semanticFormatterCallback: (value) => l10n.djVoiceVolume((value * 100).round()),
            onChanged: enabled ? (value) => setState(() => _draft = _copy(volume: value)) : null,
            onChangeEnd: enabled ? (value) => _save(_copy(volume: value)) : null,
          ),
        ],
      ],
    );
  }
}

class DjVoiceProfileControls extends StatelessWidget {
  const DjVoiceProfileControls({
    super.key,
    required this.profile,
    required this.onChanged,
    this.station = false,
    this.showTiming = true,
    this.showLevels = true,
    this.showPresets = true,
  });
  final DjVoiceProfile profile;
  final Future<void> Function(DjVoiceProfile) onChanged;
  final bool station;
  final bool showTiming, showLevels, showPresets;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      DjVoiceControls(
        showTiming: showTiming,
        showVolume: showLevels,
        settings: profile.settings,
        station: station,
        randomTiming: profile.randomTiming,
        onRandomTimingChanged: (value) => onChanged(profile.copyWith(randomTiming: value)),
        onChanged: (settings) => onChanged(profile.copyWith(settings: settings)),
      ),
      if (showTiming) ...[
        const SizedBox(height: 12),
        DropdownButtonFormField<DjAnnouncementLength>(
          key: ValueKey(profile.length),
          initialValue: profile.length,
          isExpanded: true,
          decoration: InputDecoration(labelText: context.l10n.djAnnouncementLength),
          items: [
            DropdownMenuItem(value: DjAnnouncementLength.brief, child: Text(context.l10n.djLengthBrief)),
            DropdownMenuItem(value: DjAnnouncementLength.normal, child: Text(context.l10n.djLengthNormal)),
            DropdownMenuItem(value: DjAnnouncementLength.chatty, child: Text(context.l10n.djLengthChatty)),
          ],
          onChanged: (length) {
            if (length != null) unawaited(onChanged(profile.copyWith(length: length)));
          },
        ),
        const SizedBox(height: 8),
        Text(context.l10n.djLengthHelp, style: Theme.of(context).textTheme.bodySmall),
      ],
      if (showLevels) ...[const SizedBox(height: 16), _DjMusicSlider(profile: profile, onChanged: onChanged)],
      if (showPresets) ...[
        const SizedBox(height: 12),
        DjListeningPresetsControls(profile: profile, onChanged: onChanged),
      ],
    ],
  );
}

class _DjMusicSlider extends StatefulWidget {
  const _DjMusicSlider({required this.profile, required this.onChanged});
  final DjVoiceProfile profile;
  final Future<void> Function(DjVoiceProfile) onChanged;
  @override
  State<_DjMusicSlider> createState() => _DjMusicSliderState();
}

class _DjMusicSliderState extends State<_DjMusicSlider> {
  late double _value = widget.profile.musicUnderVoice;
  @override
  void didUpdateWidget(covariant _DjMusicSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.profile.musicUnderVoice != widget.profile.musicUnderVoice) _value = widget.profile.musicUnderVoice;
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(context.l10n.djMusicUnderVoice((_value * 100).round()), style: Theme.of(context).textTheme.titleMedium),
      Slider(
        key: const ValueKey('djMusicUnderVoice'),
        value: _value,
        min: 0,
        max: 1,
        divisions: 100,
        label: '${(_value * 100).round()}%',
        semanticFormatterCallback: (value) => context.l10n.djMusicUnderVoice((value * 100).round()),
        onChanged: (value) => setState(() => _value = value),
        onChangeEnd: (value) => unawaited(widget.onChanged(widget.profile.copyWith(musicUnderVoice: value))),
      ),
      Text(context.l10n.djMusicUnderVoiceHelp, style: Theme.of(context).textTheme.bodySmall),
    ],
  );
}

class DjListeningPresetsControls extends StatefulWidget {
  const DjListeningPresetsControls({super.key, required this.profile, required this.onChanged});
  final DjVoiceProfile profile;
  final Future<void> Function(DjVoiceProfile) onChanged;
  @override
  State<DjListeningPresetsControls> createState() => _DjListeningPresetsControlsState();
}

class _DjListeningPresetsControlsState extends State<DjListeningPresetsControls> {
  Map<DjListeningEnvironment, DjListeningPreset> _presets = {
    DjListeningEnvironment.car: DjListeningPreset.car,
    DjListeningEnvironment.headphones: DjListeningPreset.headphones,
  };
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final presets = await DjVoicePreferences.loadListeningPresets();
    if (mounted) setState(() => _presets = presets);
  }

  Future<void> _save(DjListeningEnvironment environment) async {
    setState(() => _busy = true);
    try {
      final presets = {..._presets, environment: DjListeningPreset.fromProfile(widget.profile)};
      await DjVoicePreferences.saveListeningPresets(presets);
      if (mounted) setState(() => _presets = presets);
    } catch (error) {
      GlobalSnackbar.error(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(context.l10n.djListeningPresets, style: Theme.of(context).textTheme.titleMedium),
      Wrap(
        spacing: 8,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final environment in DjListeningEnvironment.values)
            OutlinedButton.icon(
              onPressed: _busy ? null : () => widget.onChanged(_presets[environment]!.apply(widget.profile)),
              icon: Icon(environment == DjListeningEnvironment.car ? Icons.directions_car : Icons.headphones),
              label: Text(
                environment == DjListeningEnvironment.car ? context.l10n.djPresetCar : context.l10n.djPresetHeadphones,
              ),
            ),
          PopupMenuButton<DjListeningEnvironment>(
            enabled: !_busy,
            tooltip: context.l10n.djSavePreset,
            onSelected: _save,
            icon: const Icon(Icons.save_outlined),
            itemBuilder: (_) => [
              PopupMenuItem(value: DjListeningEnvironment.car, child: Text(context.l10n.djSaveCarPreset)),
              PopupMenuItem(value: DjListeningEnvironment.headphones, child: Text(context.l10n.djSaveHeadphonesPreset)),
            ],
          ),
        ],
      ),
      Text(context.l10n.djListeningPresetsHelp, style: Theme.of(context).textTheme.bodySmall),
    ],
  );
}
