import 'package:finamp/components/fun_heading.dart';
import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

/// Mix lengths offered, in minutes.
const mixLengths = [30, 60, 120];

/// Range of a custom mix length, in minutes.
const minCustomMixMinutes = 10;
const maxCustomMixMinutes = 360;

/// Rough average track length, to turn a mix length into a number of tracks.
const averageTrackMinutes = 4;

/// The first of [tracks] that fill [minutes] of music, or all of them without a length.
List<BaseItemDto> fillMixLength(List<BaseItemDto> tracks, int? minutes) {
  if (minutes == null) return tracks;
  final length = Duration(minutes: minutes);
  var total = Duration.zero;
  final kept = <BaseItemDto>[];
  for (final track in tracks) {
    if (total >= length) break;
    kept.add(track);
    total += track.runTimeTicksDuration() ?? const Duration(minutes: averageTrackMinutes);
  }
  return kept;
}

/// "45 min", "2 h" or "1 h 30 min".
String mixLengthLabel(BuildContext context, int minutes) {
  if (minutes < 60) return context.l10n.aiDjMinutes(minutes);
  final hours = context.l10n.aiDjHours(minutes ~/ 60);
  return minutes % 60 == 0 ? hours : "$hours ${context.l10n.aiDjMinutes(minutes % 60)}";
}

/// Chips for a mix length: the preset [mixLengths] and a custom length picked on scroll wheels.
/// With [anyLabel], a first chip for no particular length, which is a null [minutes].
class MixLengthChips extends StatelessWidget {
  const MixLengthChips({super.key, required this.minutes, required this.onChanged, this.anyLabel});

  final int? minutes;
  final ValueChanged<int?> onChanged;
  final String? anyLabel;

  Future<void> _pickCustomLength(BuildContext context) async {
    final start = ((minutes ?? 60).clamp(minCustomMixMinutes, maxCustomMixMinutes) / 5).round() * 5;
    var hours = start ~/ 60;
    var minuteStep = (start % 60) ~/ 5;
    int total() => (hours * 60 + minuteStep * 5).clamp(minCustomMixMinutes, maxCustomMixMinutes);
    final hourController = FixedExtentScrollController(initialItem: hours);
    final minuteController = FixedExtentScrollController(initialItem: minuteStep);
    final picked = await showDialog<int>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(context.l10n.aiDjCustomLength),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(mixLengthLabel(context, total()), style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 8),
              SizedBox(
                height: 160,
                child: Row(
                  children: [
                    Expanded(
                      child: _LengthWheel(
                        controller: hourController,
                        labels: [for (var h = 0; h <= maxCustomMixMinutes ~/ 60; h++) context.l10n.aiDjHours(h)],
                        onChanged: (index) => setDialogState(() => hours = index),
                      ),
                    ),
                    Expanded(
                      child: _LengthWheel(
                        controller: minuteController,
                        labels: [for (var m = 0; m < 60; m += 5) context.l10n.aiDjMinutes(m)],
                        onChanged: (index) => setDialogState(() => minuteStep = index),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text(context.l10n.aiDjCustomLengthTracks((total() / averageTrackMinutes).round())),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(total()),
              child: Text(MaterialLocalizations.of(context).okButtonLabel),
            ),
          ],
        ),
      ),
    );
    hourController.dispose();
    minuteController.dispose();
    if (picked != null) onChanged(picked);
  }

  @override
  Widget build(BuildContext context) {
    final custom = minutes != null && !mixLengths.contains(minutes);
    return Wrap(
      spacing: 8.0,
      runSpacing: 4.0,
      children: [
        if (anyLabel != null)
          SelectionPop(
            selected: minutes == null,
            child: ChoiceChip(label: Text(anyLabel!), selected: minutes == null, onSelected: (_) => onChanged(null)),
          ),
        for (final length in mixLengths)
          SelectionPop(
            selected: minutes == length,
            child: ChoiceChip(
              label: Text(mixLengthLabel(context, length)),
              selected: minutes == length,
              onSelected: (_) => onChanged(length),
            ),
          ),
        // Shows the chosen length once there is one; tapping it again changes it.
        SelectionPop(
          selected: custom,
          child: ChoiceChip(
            avatar: const Icon(TablerIcons.adjustments_horizontal),
            label: Text(custom ? mixLengthLabel(context, minutes!) : context.l10n.aiDjCustom),
            selected: custom,
            onSelected: (_) => _pickCustomLength(context),
          ),
        ),
      ],
    );
  }
}

/// A scroll wheel for one part (hours or minutes) of the custom mix length.
class _LengthWheel extends StatelessWidget {
  const _LengthWheel({required this.controller, required this.labels, required this.onChanged});

  final FixedExtentScrollController controller;
  final List<String> labels;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return CupertinoPicker.builder(
      scrollController: controller,
      itemExtent: 40,
      magnification: 1.15,
      useMagnifier: true,
      squeeze: 1.1,
      selectionOverlay: Container(
        margin: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(
          color: colorScheme.primary.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
        ),
      ),
      onSelectedItemChanged: onChanged,
      childCount: labels.length,
      itemBuilder: (context, index) =>
          Center(child: Text(labels[index], style: Theme.of(context).textTheme.titleLarge)),
    );
  }
}
