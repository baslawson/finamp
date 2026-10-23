import 'dart:async';

import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/services/dj_context.dart';
import 'package:flutter/material.dart';

/// Whether the DJ mentions the moment (time of day, driving, running, night mode) and the city for the weather.
class DjContextControls extends StatefulWidget {
  const DjContextControls({super.key});

  @override
  State<DjContextControls> createState() => _DjContextControlsState();
}

class _DjContextControlsState extends State<DjContextControls> {
  bool? _enabled;
  final _city = TextEditingController();
  String _savedCity = '';
  String? _weather;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _city.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final enabled = await DjContext.isEnabled();
    final city = await DjContext.city();
    if (!mounted) return;
    setState(() {
      _enabled = enabled;
      _savedCity = city;
      _city.text = city;
    });
  }

  Future<void> _saveCity() async {
    final city = _city.text.trim();
    if (city == _savedCity) return;
    await DjContext.setCity(city);
    _savedCity = city;
    if (!mounted) return;
    setState(() => _weather = null);
    if (city.isEmpty) return;
    final weather = await DjContext.weather();
    if (!mounted) return;
    setState(
      () => _weather = weather == null
          ? context.l10n.djWeatherNotFound
          : context.l10n.djWeatherNow(weather.place, weather.temperature, weather.sky),
    );
  }

  @override
  Widget build(BuildContext context) {
    final enabled = _enabled;
    if (enabled == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(context.l10n.djContextAware),
          subtitle: Text(context.l10n.djContextAwareHelp),
          value: enabled,
          onChanged: (value) {
            setState(() => _enabled = value);
            unawaited(DjContext.setEnabled(value));
          },
        ),
        if (enabled)
          // Its own storage key: the text field's scroll position would otherwise share the expanding section's
          // saved open/closed state and fail to restore.
          KeyedSubtree(
            key: const PageStorageKey('djWeatherCityField'),
            child: TextField(
              controller: _city,
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                labelText: context.l10n.djWeatherCity,
                helperText: _weather ?? context.l10n.djWeatherCityHelp,
                helperMaxLines: 3,
              ),
              onSubmitted: (_) => unawaited(_saveCity()),
              onTapOutside: (_) {
                FocusScope.of(context).unfocus();
                unawaited(_saveCity());
              },
            ),
          ),
      ],
    );
  }
}
