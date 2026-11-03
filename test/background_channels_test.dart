import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Playback can start the app without its screen (a Bluetooth or system play button). Channels registered only
// in MainActivity are then missing, so these must be in BackgroundChannels, which every engine gets.
const _neededWithoutScreen = [
  "audio_devices",
  "client_certificate",
  "crossfade",
  "dj_voice",
  "downloads_service",
  "home_widget",
  "night_mode",
  "notify",
  "set_native_theme",
  "steps",
  "updates",
  "visualizer",
];

const _kotlin = "android/app/src/main/kotlin/com/unicornsonlsd/finamp";

void main() {
  final background = File("$_kotlin/BackgroundChannels.kt").readAsStringSync();
  final activity = File("$_kotlin/MainActivity.kt").readAsStringSync();

  Set<String> channels(String source) =>
      RegExp(r'"com\.unicornsonlsd\.finamp/([a-z_]+)"').allMatches(source).map((match) => match.group(1)!).toSet();

  test("channels playback uses work without the app's screen", () {
    expect(channels(background), containsAll(_neededWithoutScreen));
  });

  test("every channel the app calls is registered once on Android", () {
    final used = <String>{};
    for (final file in Directory("lib").listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith(".dart")) continue;
      used.addAll(
        RegExp(
          r'''(?:Method|Event)Channel\(\s*["']com\.unicornsonlsd\.finamp/([a-z_]+)''',
        ).allMatches(file.readAsStringSync()).map((match) => match.group(1)!),
      );
    }
    final inBackground = channels(background), inActivity = channels(activity);
    expect(used, isNotEmpty);
    for (final channel in used) {
      expect(inBackground.contains(channel) || inActivity.contains(channel), isTrue, reason: "$channel isn't registered");
      expect(inBackground.contains(channel) && inActivity.contains(channel), isFalse, reason: "$channel is registered twice");
    }
  });

  test("every engine gets the background channels", () {
    expect(File("android/app/src/main/AndroidManifest.xml").readAsStringSync(), contains('android:name=".FinampApplication"'));
    expect(File("$_kotlin/FinampApplication.kt").readAsStringSync(), contains("BackgroundChannels.register"));
    final plugin = File(
      "packages/just_audio/android/src/main/java/com/ryanheise/just_audio/JustAudioPlugin.java",
    ).readAsStringSync();
    expect(plugin, contains("hook.onAttached(applicationContext, messenger)"));
  });
}
