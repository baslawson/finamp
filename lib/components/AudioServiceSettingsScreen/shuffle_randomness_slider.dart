import 'package:finamp/l10n/app_localizations.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
          Text(l10n.shuffleRandomness(percentage), style: Theme.of(context).textTheme.titleMedium),
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
