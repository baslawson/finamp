import 'package:finamp/components/fun_heading.dart';
import 'package:finamp/l10n/app_localizations.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

class ShuffleRandomnessSlider extends ConsumerWidget {
  const ShuffleRandomnessSlider({super.key, this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 8)});

  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final percentage = ref.watch(
      finampSettingsProvider.select(
        (value) => (value.valueOrNull ?? FinampSettingsHelper.finampSettings).shuffleRandomness.clamp(0, 100),
      ),
    );
    return Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The percentage stands out as a badge, read out together with its title.
          MergeSemantics(
            child: Row(
              spacing: 12.0,
              children: [
                Expanded(child: Text(l10n.shuffleRandomnessTitle, style: Theme.of(context).textTheme.titleMedium)),
                _PercentBadge(percentage: percentage, label: l10n.shuffleRandomnessPercent(percentage)),
              ],
            ),
          ),
          Text(l10n.shuffleRandomnessDescription, style: Theme.of(context).textTheme.bodySmall),
          Slider(
            value: percentage.toDouble(),
            max: 100,
            divisions: 100,
            label: l10n.shuffleRandomnessPercent(percentage),
            semanticFormatterCallback: (value) => l10n.shuffleRandomnessPercent(value.round()),
            onChanged: (value) => FinampSetters.setShuffleRandomness(value.round()),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(child: Text(l10n.shuffleRandomnessOrdered)),
              Expanded(child: Text(l10n.shuffleRandomnessRandom, textAlign: TextAlign.end)),
            ],
          ),
        ],
      ),
    );
  }
}

/// The randomness percentage in a bold badge in the accent colour.
class _PercentBadge extends StatelessWidget {
  const _PercentBadge({required this.percentage, required this.label});

  final int percentage;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14.0, vertical: 4.0),
      decoration: BoxDecoration(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(999)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 6.0,
        children: [
          Icon(TablerIcons.arrows_shuffle, size: 18.0, color: scheme.onPrimaryContainer),
          Text(
            label,
            style: TextTheme.of(context).headlineSmall?.copyWith(
              color: scheme.onPrimaryContainer,
              fontFamily: headingFontFamily,
              fontWeight: FontWeight.w900,
              // Digits of even width, so the badge doesn't jiggle while dragging.
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
