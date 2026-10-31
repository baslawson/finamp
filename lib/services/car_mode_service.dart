import 'dart:async';
import 'dart:io';

import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/screens/car_mode_screen.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

typedef CarModeSettings = ({bool autoOpen, String? carDevice});

/// Opens the car mode player when the phone connects to the car's Bluetooth.
class CarModeService {
  CarModeService._();

  static final _logger = Logger("CarModeService");
  static const _devices = EventChannel("com.unicornsonlsd.finamp/audio_devices");
  static const _autoOpenKey = "carModeAutoOpen";
  static const _deviceKey = "carModeDevice";

  static CarModeSettings _settings = (autoOpen: false, carDevice: null);
  static List<String> _connected = [];
  static StreamSubscription<dynamic>? _subscription;

  /// Bluetooth audio outputs connected right now.
  static List<String> get connectedDevices => _connected;

  /// Whether the phone is connected to the car chosen in car mode settings.
  static bool get inCar => _settings.carDevice != null && _connected.contains(_settings.carDevice);
  static final connectedChanges = StreamController<List<String>>.broadcast();

  static Future<CarModeSettings> loadSettings() async {
    final prefs = SharedPreferencesAsync();
    return (autoOpen: await prefs.getBool(_autoOpenKey) ?? false, carDevice: await prefs.getString(_deviceKey));
  }

  static Future<void> saveSettings(CarModeSettings settings) async {
    final prefs = SharedPreferencesAsync();
    await prefs.setBool(_autoOpenKey, settings.autoOpen);
    if (settings.carDevice == null) {
      await prefs.remove(_deviceKey);
    } else {
      await prefs.setString(_deviceKey, settings.carDevice!);
    }
    _settings = settings;
  }

  static Future<void> initialize() async {
    if (!Platform.isAndroid) return;
    _settings = await loadSettings();
    _subscription = _devices.receiveBroadcastStream().listen((event) {
      final devices = (event as List).cast<String>();
      final added = devices.where((device) => !_connected.contains(device)).toList();
      _connected = devices;
      connectedChanges.add(devices);
      if (_settings.autoOpen && _settings.carDevice != null && added.contains(_settings.carDevice)) {
        _logger.info("Connected to ${_settings.carDevice}, opening car mode");
        open();
      }
    }, onError: (Object e) => _logger.warning("Audio device updates failed", e));
  }

  static Future<void> dispose() async => _subscription?.cancel();

  static bool _isOpen = false;

  /// Shows the car mode player, unless it's already showing.
  static void open() {
    final navigator = GlobalSnackbar.rawMaterialAppNavigatorKey.currentState;
    if (navigator == null || _isOpen) return;
    _isOpen = true;
    unawaited(navigator.pushNamed(CarModeScreen.routeName).whenComplete(() => _isOpen = false));
  }
}
