import 'dart:io';

import 'package:flutter/services.dart';

/// Reads the band levels the audio chain measures (Android only).
class SpectrumReader {
  SpectrumReader._();

  static const _channel = MethodChannel("com.unicornsonlsd.finamp/visualizer");
  static const bands = 32;

  /// Whether this platform measures band levels at all; elsewhere [read] is always silent.
  static bool get available => Platform.isAndroid;

  // The visualizer screen and party TV screens can both be showing: measuring stops when the last one goes.
  static int _users = 0;

  static Future<void> setEnabled(bool enabled) async {
    final was = _users > 0;
    _users = enabled ? _users + 1 : (_users - 1).clamp(0, 1 << 30);
    if (!available || was == _users > 0) return;
    try {
      await _channel.invokeMethod("setEnabled", {"enabled": _users > 0});
    } catch (_) {}
  }

  static Future<List<double>> read() async {
    if (!available) return List.filled(bands, 0);
    try {
      return ((await _channel.invokeMethod<List<dynamic>>("bands")) ?? const [])
          .map((value) => (value as num).toDouble())
          .toList();
    } catch (_) {
      return List.filled(bands, 0);
    }
  }
}
