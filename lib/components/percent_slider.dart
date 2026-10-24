import 'package:finamp/components/fun_heading.dart';
import 'package:flutter/material.dart';

/// A setting in percent: its [title] with the value in a bold badge, a [description], the slider and what each end
/// means.
class PercentSlider extends StatelessWidget {
  const PercentSlider({
    super.key,
    required this.title,
    required this.description,
    required this.percentage,
    required this.percentLabel,
    required this.icon,
    required this.low,
    required this.high,
    required this.onChanged,
    this.onChangeEnd,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
  });

  final String title, description;
  final int percentage;

  /// The value as shown and read out, such as "75%".
  final String Function(int percentage) percentLabel;
  final IconData icon;

  /// What 0% and 100% mean.
  final String low, high;
  final ValueChanged<int> onChanged;
  final ValueChanged<int>? onChangeEnd;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
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
                Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium)),
                PercentBadge(label: percentLabel(percentage), icon: icon),
              ],
            ),
          ),
          Text(description, style: Theme.of(context).textTheme.bodySmall),
          Slider(
            value: percentage.toDouble(),
            max: 100,
            divisions: 100,
            label: percentLabel(percentage),
            semanticFormatterCallback: (value) => percentLabel(value.round()),
            onChanged: (value) => onChanged(value.round()),
            onChangeEnd: onChangeEnd == null ? null : (value) => onChangeEnd!(value.round()),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(child: Text(low)),
              Expanded(child: Text(high, textAlign: TextAlign.end)),
            ],
          ),
        ],
      ),
    );
  }
}

/// A percentage in a bold badge in the accent colour.
class PercentBadge extends StatelessWidget {
  const PercentBadge({super.key, required this.label, required this.icon});

  final String label;
  final IconData icon;

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
          Icon(icon, size: 18.0, color: scheme.onPrimaryContainer),
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
