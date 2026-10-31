import 'package:finamp/components/percent_slider.dart';
import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/services/analyzer_service.dart';
import 'package:finamp/services/radio_tuning.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

/// A menu's own harmonic mixing switch, remembered on this device. Needs the analyzer, which knows each song's key
/// and tempo, so it's off and disabled until that's set up. While it's on, the harmonic strength shows under it.
/// [onChanged] is told whether harmonic mixing is in effect once loaded and on every change. Without [showStrength]
/// the menu shows the strength itself.
class HarmonicMixingSwitch extends StatefulWidget {
  const HarmonicMixingSwitch({super.key, required this.menu, this.onChanged, this.showStrength = true});

  final HarmonicMixingMenu menu;
  final ValueChanged<bool>? onChanged;
  final bool showStrength;

  @override
  State<HarmonicMixingSwitch> createState() => _HarmonicMixingSwitchState();
}

class _HarmonicMixingSwitchState extends State<HarmonicMixingSwitch> {
  /// Null while loading.
  bool? _enabled;
  bool _analyzer = false;

  @override
  void initState() {
    super.initState();
    () async {
      final analyzer = await AnalyzerService.isConfigured();
      final enabled = await HarmonicMixing.menuEnabled(widget.menu);
      if (mounted) {
        setState(() {
          _analyzer = analyzer;
          _enabled = enabled;
        });
        widget.onChanged?.call(analyzer && enabled);
      }
    }();
  }

  @override
  Widget build(BuildContext context) {
    final on = _analyzer && (_enabled ?? false);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _switch(context),
        if (on && widget.showStrength) const HarmonicStrengthSlider(padding: EdgeInsets.only(bottom: 8)),
      ],
    );
  }

  Widget _switch(BuildContext context) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(context.l10n.harmonicMixing),
      subtitle: Text(_analyzer ? context.l10n.harmonicMixingMenuDescription : context.l10n.harmonicMixingNeedsAnalyzer),
      value: _analyzer && (_enabled ?? false),
      onChanged: !_analyzer || _enabled == null
          ? null
          : (enabled) {
              setState(() => _enabled = enabled);
              widget.onChanged?.call(enabled);
              HarmonicMixing.setMenuEnabled(widget.menu, enabled).ignore();
            },
    );
  }
}

/// "Harmonic strength", shared by Radio and every harmonic mix: how closely each song follows on in key and tempo.
/// [onChangeEnd] is told the new value once it's saved.
class HarmonicStrengthSlider extends StatelessWidget {
  const HarmonicStrengthSlider({
    super.key,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    this.onChangeEnd,
  });

  final EdgeInsetsGeometry padding;
  final ValueChanged<int>? onChangeEnd;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return ValueListenableBuilder(
      valueListenable: HarmonicMixing.strength,
      builder: (context, strength, _) => PercentSlider(
        padding: padding,
        title: l10n.harmonicStrengthTitle,
        description: l10n.harmonicStrengthDescription,
        percentage: strength,
        percentLabel: l10n.shuffleRandomnessPercent,
        icon: TablerIcons.wave_sine,
        low: l10n.harmonicStrengthLoose,
        high: l10n.harmonicStrengthStrict,
        // Shown straight away and saved when let go.
        onChanged: (value) => HarmonicMixing.strength.value = value,
        onChangeEnd: (value) async {
          await HarmonicMixing.setStrength(value);
          onChangeEnd?.call(value);
        },
      ),
    );
  }
}
