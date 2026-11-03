import 'package:finamp/components/percent_slider.dart';
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
    return PercentSlider(
      padding: padding,
      title: l10n.shuffleRandomnessTitle,
      description: l10n.shuffleRandomnessDescription,
      percentage: percentage,
      percentLabel: l10n.shuffleRandomnessPercent,
      icon: TablerIcons.arrows_shuffle,
      low: l10n.shuffleRandomnessOrdered,
      high: l10n.shuffleRandomnessRandom,
      onChanged: FinampSetters.setShuffleRandomness,
    );
  }
}
