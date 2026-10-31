import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/services/analyzer_service.dart';
import 'package:finamp/services/genre_fit.dart';
import 'package:flutter/material.dart';

/// "Match the sound" for genre mixes, shared by Smart Shuffle and Radio and remembered on this device. Needs the
/// analyzer, which listens to each song, so it's off and disabled until that's set up.
class GenreFitSwitch extends StatefulWidget {
  const GenreFitSwitch({super.key});

  @override
  State<GenreFitSwitch> createState() => _GenreFitSwitchState();
}

class _GenreFitSwitchState extends State<GenreFitSwitch> {
  /// Null while loading.
  bool? _enabled;
  bool _analyzer = false;

  @override
  void initState() {
    super.initState();
    () async {
      final analyzer = await AnalyzerService.isConfigured();
      final enabled = await GenreFit.isEnabled();
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
      title: Text(context.l10n.genreFitTitle),
      subtitle: Text(_analyzer ? context.l10n.genreFitDescription : context.l10n.genreFitNeedsAnalyzer),
      value: _analyzer && (_enabled ?? false),
      onChanged: !_analyzer || _enabled == null
          ? null
          : (enabled) {
              setState(() => _enabled = enabled);
              GenreFit.setEnabled(enabled).ignore();
            },
    );
  }
}
