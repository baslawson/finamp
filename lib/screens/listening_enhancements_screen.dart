import 'package:finamp/components/block_artist_dialog.dart';
import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/screens/headphone_eq_screen.dart';
import 'package:finamp/services/car_mode_service.dart';
import 'package:finamp/services/device_sound_profiles.dart';
import 'package:finamp/services/list_duplicates.dart';
import 'package:finamp/services/listening_preferences.dart';
import 'package:finamp/services/played_recently.dart';
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
      await PlayedRecently.ensureLoaded();
      await ListDuplicates.ensureLoaded();
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

  /// Asks for a custom number of hours to leave heard songs out for.
  Future<void> _chooseCustomHours() async {
    final hours = await showDialog<int>(context: context, builder: (_) => const _CustomHoursDialog());
    if (hours != null) await _save(() => PlayedRecently.setHours(hours));
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
              PlayedRecently.changed,
              ListDuplicates.changed,
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
                SwitchListTile(
                  title: Text(context.l10n.noRepeatsTitle),
                  subtitle: Text(context.l10n.noRepeatsDescription),
                  value: PlayedRecently.isOn,
                  onChanged: _saving ? null : (v) => _save(() => PlayedRecently.setOn(v)),
                ),
                if (PlayedRecently.isOn)
                  ListTile(
                    title: Text(context.l10n.noRepeatsFor),
                    subtitle: Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          for (final hours in PlayedRecently.presets)
                            ChoiceChip(
                              label: Text(context.l10n.noRepeatsHours(hours)),
                              selected: PlayedRecently.hours == hours,
                              onSelected: _saving ? null : (_) => _save(() => PlayedRecently.setHours(hours)),
                            ),
                          ChoiceChip(
                            label: Text(
                              PlayedRecently.presets.contains(PlayedRecently.hours)
                                  ? context.l10n.noRepeatsCustom
                                  : "${context.l10n.noRepeatsCustom}: ${context.l10n.noRepeatsHours(PlayedRecently.hours)}",
                            ),
                            selected: !PlayedRecently.presets.contains(PlayedRecently.hours),
                            onSelected: _saving ? null : (_) => _chooseCustomHours(),
                          ),
                        ],
                      ),
                    ),
                  ),
                ListTile(
                  title: Text(
                    context.l10n.noRepeatsHeardCount(
                      PlayedRecently.heardCount,
                      context.l10n.noRepeatsHours(PlayedRecently.hours),
                    ),
                  ),
                  trailing: TextButton(
                    onPressed: _saving || PlayedRecently.heardCount == 0 ? null : () => _save(PlayedRecently.clear),
                    child: Text(context.l10n.noRepeatsClear),
                  ),
                ),
                const Divider(),
                ListTile(
                  title: Text(context.l10n.oneVersionTitle),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(context.l10n.oneVersionDescription),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          for (final (mode, label) in [
                            (ListDuplicatesMode.off, context.l10n.oneVersionOff),
                            (ListDuplicatesMode.playlists, context.l10n.oneVersionPlaylists),
                            (ListDuplicatesMode.everyList, context.l10n.oneVersionEveryList),
                          ])
                            ChoiceChip(
                              label: Text(label),
                              selected: ListDuplicates.mode == mode,
                              onSelected: _saving ? null : (_) => _save(() => ListDuplicates.setMode(mode)),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                const Divider(),
                ListTile(
                  title: Text(context.l10n.listeningResting),
                  subtitle: Text(context.l10n.listeningRestDescription),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(context.l10n.listeningBlockScope),
                      Wrap(
                        spacing: 8,
                        children: [
                          for (final (everywhere, label) in [
                            (false, context.l10n.listeningBlockMixes),
                            (true, context.l10n.listeningBlockEverything),
                          ])
                            ChoiceChip(
                              label: Text(label),
                              selected: ListeningPreferences.everywhere == everywhere,
                              onSelected: _saving
                                  ? null
                                  : (_) => _save(() => ListeningPreferences.setEverywhere(everywhere)),
                            ),
                        ],
                      ),
                      Text(context.l10n.listeningBlockScopeHelp, style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
                for (final rest
                    in ListeningPreferences.rests..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase())))
                  ListTile(
                    leading: Icon(rest.artist ? Icons.person_off_outlined : Icons.music_note),
                    title: Text(rest.name),
                    subtitle: Text(
                      rest.artist
                          ? blockedText(context, rest)
                          : context.l10n.listeningRestUntil(whenText(context, rest.until)),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (rest.artist)
                          IconButton(
                            tooltip: context.l10n.listeningChangeTime,
                            icon: const Icon(Icons.edit_calendar),
                            onPressed: _saving
                                ? null
                                : () async {
                                    await showBlockArtistDialog(context, [(name: rest.name, id: rest.artistId)]);
                                    if (mounted) setState(() {});
                                  },
                          ),
                        IconButton(
                          tooltip: rest.artist ? context.l10n.unblock : context.l10n.listeningRemove,
                          icon: const Icon(Icons.close),
                          onPressed: _saving ? null : () => _save(() => ListeningPreferences.removeRest(rest.key)),
                        ),
                      ],
                    ),
                  ),
                if (ListeningPreferences.rests.length > 1)
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: TextButton(
                        onPressed: _saving ? null : () => _save(ListeningPreferences.clearRests),
                        child: Text(context.l10n.listeningClearAll),
                      ),
                    ),
                  ),
                const SizedBox(height: 40),
              ],
            ),
          ),
  );
}

/// A number of hours, from 1 to [PlayedRecently.maxHours]. Its own state owns the text field, so it's only disposed
/// once the dialog has finished closing.
class _CustomHoursDialog extends StatefulWidget {
  const _CustomHoursDialog();

  @override
  State<_CustomHoursDialog> createState() => _CustomHoursDialogState();
}

class _CustomHoursDialogState extends State<_CustomHoursDialog> {
  late final _field = TextEditingController(text: "${PlayedRecently.hours}");

  int? get _hours {
    final value = int.tryParse(_field.text.trim());
    return value != null && value >= 1 && value <= PlayedRecently.maxHours ? value : null;
  }

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(context.l10n.noRepeatsFor),
    content: TextField(
      controller: _field,
      autofocus: true,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(labelText: context.l10n.noRepeatsCustomLabel(PlayedRecently.maxHours)),
      onChanged: (_) => setState(() {}),
      onSubmitted: (_) {
        if (_hours case final hours?) Navigator.pop(context, hours);
      },
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
      ),
      TextButton(
        onPressed: _hours == null ? null : () => Navigator.pop(context, _hours),
        child: Text(MaterialLocalizations.of(context).okButtonLabel),
      ),
    ],
  );
}
