import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/services/night_mode_service.dart';
import 'package:flutter/material.dart';

/// Turns night mode on and sets the hours it's active.
class NightModeSettingsScreen extends StatefulWidget {
  const NightModeSettingsScreen({super.key});

  static const routeName = "/settings/nightmode";

  @override
  State<NightModeSettingsScreen> createState() => _NightModeSettingsScreenState();
}

class _NightModeSettingsScreenState extends State<NightModeSettingsScreen> {
  NightModeSettings? _settings;

  @override
  void initState() {
    super.initState();
    NightModeService.loadSettings().then((settings) {
      if (mounted) setState(() => _settings = settings);
    });
  }

  Future<void> _save(NightModeSettings settings) async {
    setState(() => _settings = settings);
    await NightModeService.saveSettings(settings);
  }

  Future<int?> _pickTime(int minute) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: minute ~/ 60, minute: minute % 60),
    );
    return picked == null ? null : picked.hour * 60 + picked.minute;
  }

  @override
  Widget build(BuildContext context) {
    final settings = _settings;
    String format(int minute) => TimeOfDay(hour: minute ~/ 60, minute: minute % 60).format(context);

    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.nightMode)),
      body: settings == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                Text(context.l10n.nightModeDescription),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(context.l10n.nightMode),
                  subtitle: StreamBuilder<bool>(
                    stream: NightModeService.active.stream,
                    initialData: NightModeService.isActive,
                    builder: (context, active) =>
                        Text(active.data! ? context.l10n.nightModeActiveNow : context.l10n.nightModeInactiveNow),
                  ),
                  value: settings.enabled,
                  onChanged: (enabled) =>
                      _save((enabled: enabled, startMinute: settings.startMinute, endMinute: settings.endMinute)),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(context.l10n.nightModeStart),
                  trailing: Text(format(settings.startMinute), style: Theme.of(context).textTheme.titleMedium),
                  onTap: () async {
                    final start = await _pickTime(settings.startMinute);
                    if (start != null) {
                      await _save((enabled: settings.enabled, startMinute: start, endMinute: settings.endMinute));
                    }
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(context.l10n.nightModeEnd),
                  trailing: Text(format(settings.endMinute), style: Theme.of(context).textTheme.titleMedium),
                  onTap: () async {
                    final end = await _pickTime(settings.endMinute);
                    if (end != null) {
                      await _save((enabled: settings.enabled, startMinute: settings.startMinute, endMinute: end));
                    }
                  },
                ),
                const SizedBox(height: 24),
              ],
            ),
    );
  }
}
