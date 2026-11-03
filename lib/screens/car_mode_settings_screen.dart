import 'dart:async';

import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/screens/car_mode_screen.dart';
import 'package:finamp/services/car_mode_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

/// Picks the car's Bluetooth device, so car mode opens when the phone connects to it.
class CarModeSettingsScreen extends StatefulWidget {
  const CarModeSettingsScreen({super.key});

  static const routeName = "/settings/carmode";

  @override
  State<CarModeSettingsScreen> createState() => _CarModeSettingsScreenState();
}

class _CarModeSettingsScreenState extends State<CarModeSettingsScreen> {
  CarModeSettings? _settings;
  List<String> _connected = CarModeService.connectedDevices;
  StreamSubscription<List<String>>? _subscription;

  @override
  void initState() {
    super.initState();
    CarModeService.loadSettings().then((settings) {
      if (mounted) setState(() => _settings = settings);
    });
    _subscription = CarModeService.connectedChanges.stream.listen((devices) {
      if (mounted) setState(() => _connected = devices);
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  Future<void> _save(CarModeSettings settings) async {
    setState(() => _settings = settings);
    await CarModeService.saveSettings(settings);
  }

  @override
  Widget build(BuildContext context) {
    final settings = _settings;
    if (settings == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final devices = {
      ...?(settings.carDevice == null ? null : [settings.carDevice!]),
      ..._connected,
    }.toList();

    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.carMode)),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          Text(context.l10n.carModeDescription),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: () => Navigator.of(context).pushNamed(CarModeScreen.routeName),
            icon: const Icon(TablerIcons.car),
            label: Text(context.l10n.carModeOpen),
          ),
          const Divider(height: 32),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(context.l10n.carModeAutoOpen),
            subtitle: Text(context.l10n.carModeAutoOpenDescription),
            value: settings.autoOpen,
            onChanged: (autoOpen) => _save((autoOpen: autoOpen, carDevice: settings.carDevice)),
          ),
          const SizedBox(height: 8),
          Text(context.l10n.carModeDevice, style: Theme.of(context).textTheme.titleMedium),
          if (devices.isEmpty)
            Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Text(context.l10n.carModeNoDevices)),
          RadioGroup<String>(
            groupValue: settings.carDevice,
            onChanged: (device) => _save((autoOpen: settings.autoOpen || device != null, carDevice: device)),
            child: Column(
              children: [
                for (final device in devices)
                  RadioListTile<String>(
                    contentPadding: EdgeInsets.zero,
                    value: device,
                    title: Text(device),
                    subtitle: _connected.contains(device) ? Text(context.l10n.carModeConnected) : null,
                  ),
              ],
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
