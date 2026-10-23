import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/services/analyzer_service.dart';
import 'package:finamp/services/radio_tuning.dart';
import 'package:flutter/material.dart';

/// A menu's own harmonic mixing switch, remembered on this device. Needs the analyzer, which knows each song's key
/// and tempo, so it's off and disabled until that's set up.
class HarmonicMixingSwitch extends StatefulWidget {
  const HarmonicMixingSwitch({super.key, required this.menu});

  final HarmonicMixingMenu menu;

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
      }
    }();
  }

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(context.l10n.harmonicMixing),
      subtitle: Text(_analyzer ? context.l10n.harmonicMixingMenuDescription : context.l10n.harmonicMixingNeedsAnalyzer),
      value: _analyzer && (_enabled ?? false),
      onChanged: !_analyzer || _enabled == null
          ? null
          : (enabled) {
              setState(() => _enabled = enabled);
              HarmonicMixing.setMenuEnabled(widget.menu, enabled).ignore();
            },
    );
  }
}
