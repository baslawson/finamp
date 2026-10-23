import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/screens/headphone_eq_screen.dart';
import 'package:finamp/services/car_mode_service.dart';
import 'package:finamp/services/device_sound_profiles.dart';
import 'package:finamp/services/listening_preferences.dart';
import 'package:finamp/services/rolling_reserve_service.dart';
import 'package:flutter/material.dart';

class ListeningEnhancementsScreen extends StatefulWidget {
  const ListeningEnhancementsScreen({super.key});
  static const routeName = '/settings/listening-enhancements';
  @override
  State<ListeningEnhancementsScreen> createState() => _ListeningEnhancementsScreenState();
}

class _ListeningEnhancementsScreenState extends State<ListeningEnhancementsScreen> {
  bool _ready = false, _saving = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      await ListeningPreferences.ensureLoaded();
      await DeviceSoundProfiles.initialize();
      await RollingReserveService.initialize();
    } catch (e) {
      GlobalSnackbar.error(e);
    }
    if (mounted) setState(() => _ready = true);
  }

  Future<void> _save(Future<void> Function() action) async {
    setState(() => _saving = true);
    try {
      await action();
    } catch (e) {
      GlobalSnackbar.error(e);
    }
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(context.l10n.listeningEnhancements)),
    body: !_ready
        ? const Center(child: CircularProgressIndicator())
        : ListenableBuilder(
            listenable: Listenable.merge([
              DeviceSoundProfiles.changed,
              ListeningPreferences.changed,
              ListeningSession.excludeFromLearning,
              RollingReserveService.status,
            ]),
            builder: (context, _) => ListView(
              children: [
                SwitchListTile(
                  title: Text(context.l10n.listeningDontLearn),
                  subtitle: Text(context.l10n.listeningDontLearnDescription),
                  value: ListeningSession.excludeFromLearning.value,
                  onChanged: (v) => ListeningSession.excludeFromLearning.value = v,
                ),
                const Divider(),
                SwitchListTile(
                  title: Text(context.l10n.listeningDeviceProfiles),
                  subtitle: Text(context.l10n.listeningDeviceDescription),
                  value: DeviceSoundProfiles.enabled,
                  onChanged: _saving ? null : (v) => _save(() => DeviceSoundProfiles.setEnabled(v)),
                ),
                StreamBuilder<List<String>>(
                  stream: CarModeService.connectedChanges.stream,
                  initialData: CarModeService.connectedDevices,
                  builder: (context, snapshot) {
                    final connected = snapshot.data ?? [], devices = {...connected, ...DeviceSoundProfiles.devices};
                    return Column(
                      children: [
                        if (devices.isEmpty)
                          Padding(padding: const EdgeInsets.all(16), child: Text(context.l10n.listeningConnectDevice)),
                        for (final device in devices)
                          ListTile(
                            leading: Icon(
                              device == DeviceSoundProfiles.active ? Icons.volume_up : Icons.bluetooth_audio,
                            ),
                            title: Text(device),
                            subtitle: Text(
                              device == DeviceSoundProfiles.active
                                  ? context.l10n.listeningProfileActive
                                  : DeviceSoundProfiles.devices.contains(device)
                                  ? context.l10n.listeningProfileSaved
                                  : context.l10n.listeningProfileUnsaved,
                            ),
                            trailing: Wrap(
                              children: [
                                if (connected.contains(device))
                                  IconButton(
                                    tooltip: context.l10n.listeningSaveSound,
                                    icon: const Icon(Icons.save_outlined),
                                    onPressed: _saving ? null : () => _save(() => DeviceSoundProfiles.saveFor(device)),
                                  ),
                                if (DeviceSoundProfiles.devices.contains(device))
                                  IconButton(
                                    tooltip: context.l10n.listeningRemove,
                                    icon: const Icon(Icons.delete_outline),
                                    onPressed: _saving ? null : () => _save(() => DeviceSoundProfiles.remove(device)),
                                  ),
                              ],
                            ),
                          ),
                      ],
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.headphones),
                  title: Text(context.l10n.listeningFineTune),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).pushNamed(HeadphoneEqScreen.routeName),
                ),
                const Divider(),
                SwitchListTile(
                  title: Text(context.l10n.listeningReserve),
                  subtitle: Text(context.l10n.listeningReserveDescription),
                  value: RollingReserveService.enabled,
                  onChanged: _saving ? null : (v) => _save(() => RollingReserveService.configure(on: v)),
                ),
                if (RollingReserveService.enabled) ...[
                  ListTile(
                    title: Text(context.l10n.listeningReserveSongs),
                    trailing: DropdownButton<int>(
                      value: RollingReserveService.count,
                      items: [
                        for (final n in [1, 2, 3]) DropdownMenuItem(value: n, child: Text('$n')),
                      ],
                      onChanged: _saving ? null : (v) => _save(() => RollingReserveService.configure(songs: v)),
                    ),
                  ),
                  SwitchListTile(
                    title: Text(context.l10n.listeningWifiOnly),
                    value: RollingReserveService.wifiOnly,
                    onChanged: _saving ? null : (v) => _save(() => RollingReserveService.configure(wifi: v)),
                  ),
                  SwitchListTile(
                    title: Text(context.l10n.listeningReserveDj),
                    subtitle: Text(context.l10n.listeningReserveDjDescription),
                    value: RollingReserveService.includeDj,
                    onChanged: _saving ? null : (v) => _save(() => RollingReserveService.configure(voices: v)),
                  ),
                  ListTile(
                    leading: const Icon(Icons.offline_pin_outlined),
                    title: Text(
                      context.l10n.listeningReserveReady(
                        RollingReserveService.status.value.$1,
                        RollingReserveService.status.value.$2,
                      ),
                    ),
                    subtitle: Text(context.l10n.listeningReserveLimit),
                    trailing: RollingReserveService.status.value.$3
                        ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : null,
                  ),
                ],
                const Divider(),
                ListTile(
                  title: Text(context.l10n.listeningResting),
                  subtitle: Text(context.l10n.listeningRestDescription),
                ),
                for (final rest in ListeningPreferences.rests)
                  ListTile(
                    leading: Icon(rest.artist ? Icons.person_outline : Icons.music_note),
                    title: Text(rest.name),
                    subtitle: Text(
                      context.l10n.listeningRestUntil(
                        MaterialLocalizations.of(context).formatMediumDate(rest.until.toLocal()),
                      ),
                    ),
                    trailing: IconButton(
                      tooltip: context.l10n.listeningRemove,
                      icon: const Icon(Icons.close),
                      onPressed: _saving ? null : () => _save(() => ListeningPreferences.removeRest(rest.key)),
                    ),
                  ),
                const SizedBox(height: 40),
              ],
            ),
          ),
  );
}
