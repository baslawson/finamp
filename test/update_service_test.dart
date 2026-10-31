import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:finamp/services/update_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

/// Settings whose saves of [held] wait for [release], as a slow disk would.
final class _SlowPrefs extends InMemorySharedPreferencesAsync {
  _SlowPrefs() : super.empty();

  String? held;
  final release = Completer<void>();

  @override
  Future<bool> setString(String key, String value, SharedPreferencesOptions options) async {
    if (key == held) await release.future;
    return super.setString(key, value, options);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel("com.unicornsonlsd.finamp/updates");
  final apk = utf8.encode("pretend this is an APK");
  late Directory dir;
  late List<MethodCall> calls;
  late Map<String, Object?> native;
  late List<String> fetched;
  late String? digest;
  late StreamController<bool> playingChanges;
  var isPlaying = false;
  late int notificationRequests;

  Map<String, Object?> release({String tag = "v1.6.72"}) => {
    "tag_name": tag,
    "name": "Finamp+ ${tag.substring(1)}",
    "body": "What's new",
    "html_url": "https://github.com/baslawson/finamp/releases/tag/$tag",
    "assets": [
      {
        "name": "finamp-plus-$tag.apk",
        "browser_download_url": "https://example.com/universal.apk",
        "size": apk.length,
        "digest": digest == null ? null : "sha256:$digest",
      },
      {
        "name": "finamp-plus-$tag-arm64.apk",
        "browser_download_url": "https://example.com/arm64.apk",
        "size": apk.length,
        "digest": digest == null ? null : "sha256:$digest",
      },
    ],
  };

  setUp(() async {
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    dir = await Directory.systemTemp.createTemp("finamp-updates");
    calls = [];
    fetched = [];
    digest = sha256.convert(apk).toString();
    isPlaying = false;
    playingChanges = StreamController<bool>.broadcast();
    native = {
      "canInstall": true,
      "abis": ["arm64-v8a", "armeabi-v7a"],
      "lastResult": null,
    };
    UpdateService.reset();
    UpdateService.android = true;
    UpdateService.installResultWait = const Duration(seconds: 2);
    UpdateService.folder = () async => dir;
    UpdateService.installedVersion = () async => "1.6.71";
    UpdateService.playing = () => isPlaying;
    UpdateService.playingChanges = () => playingChanges.stream;
    UpdateService.unmetered = () async => true;
    notificationRequests = 0;
    UpdateService.requestNotifications = () async => notificationRequests++;
    UpdateService.client = () => MockClient((request) async {
      fetched.add(request.url.toString());
      if (request.url.host == "api.github.com") return http.Response(jsonEncode(release()), 200);
      return http.Response.bytes(apk, 200);
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        "info" => {"canInstall": native["canInstall"], "abis": native["abis"]},
        "lastResult" => native["lastResult"],
        _ => null,
      };
    });
  });

  tearDown(() async {
    UpdateService.reset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    await playingChanges.close();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  List<String> methods() => [for (final call in calls) call.method];

  test("newer versions compare by number, not text", () {
    expect(UpdateService.isNewer("v1.6.72", "1.6.71"), isTrue);
    expect(UpdateService.isNewer("v1.10.0", "1.9.9"), isTrue);
    expect(UpdateService.isNewer("v1.6.71", "1.6.71"), isFalse);
    expect(UpdateService.isNewer("v1.6.70", "1.6.71"), isFalse);
    expect(UpdateService.isNewer("nightly", "1.6.71"), isFalse);
  });

  test("an ARM64 phone gets the ARM64 APK, others the universal one", () {
    final parsed = UpdateRelease.fromJson(release())!;
    expect(UpdateService.assetFor(parsed, ["arm64-v8a"])!.name, "finamp-plus-v1.6.72-arm64.apk");
    expect(UpdateService.assetFor(parsed, ["x86_64"])!.name, "finamp-plus-v1.6.72.apk");
    expect(parsed.assets.first.sha256, digest);
  });

  test("a download matching GitHub's checksum is ready to install", () async {
    final parsed = UpdateRelease.fromJson(release())!;
    final file = await UpdateService.download(parsed);
    expect(file, isNotNull);
    expect(await file!.readAsBytes(), apk);
    expect(fetched.last, "https://example.com/arm64.apk");
    expect(UpdateService.state.value.stage, UpdateStage.ready);
  });

  test("a download that can't be written fails instead of escaping", () async {
    // Where the download is written, something that can't be written to.
    final parsed = UpdateRelease.fromJson(release())!;
    await Directory("${dir.path}/finamp-plus-v1.6.72-arm64.apk.part").create();
    UpdateService.client = () => MockClient.streaming((request, body) async {
      return http.StreamedResponse(Stream.fromFuture(Future.delayed(const Duration(milliseconds: 50), () => apk)), 200);
    });
    final file = await UpdateService.download(parsed);
    expect(file, isNull);
    expect(UpdateService.state.value.stage, UpdateStage.failed);
  });

  test("music starting while the APK is checked waits for the next pause", () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      // Music starts during the first check of the APK only.
      if (call.method == "problem" && !calls.any((earlier) => earlier != call && earlier.method == "problem")) {
        isPlaying = true;
      }
      return switch (call.method) {
        "info" => {"canInstall": native["canInstall"], "abis": native["abis"]},
        "lastResult" => native["lastResult"],
        _ => null,
      };
    });
    await UpdateService.setMode(UpdateMode.auto);
    await UpdateService.runAutomatically();
    await pumpEventQueue();
    expect(methods(), contains("problem"));
    expect(methods(), isNot(contains("install")));
    expect(UpdateService.state.value.stage, UpdateStage.ready);
    isPlaying = false;
    playingChanges.add(false);
    await pumpEventQueue();
    expect(methods(), contains("install"));
  });

  test("updates switched off while the APK is checked don't install", () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == "problem") unawaited(UpdateService.setMode(UpdateMode.notify));
      return switch (call.method) {
        "info" => {"canInstall": native["canInstall"], "abis": native["abis"]},
        "lastResult" => native["lastResult"],
        _ => null,
      };
    });
    await UpdateService.setMode(UpdateMode.auto);
    await UpdateService.runAutomatically();
    await pumpEventQueue();
    expect(methods(), contains("problem"));
    expect(methods(), isNot(contains("install")));
  });

  test("a download not matching the checksum is thrown away", () async {
    digest = sha256.convert(utf8.encode("something else")).toString();
    final file = await UpdateService.download(UpdateRelease.fromJson(release())!);
    expect(file, isNull);
    expect(UpdateService.state.value.stage, UpdateStage.failed);
    expect(dir.listSync(), isEmpty);
  });

  test("a skipped version is offered only when checking by hand", () async {
    await UpdateService.skip(UpdateRelease.fromJson(release())!);
    expect(await UpdateService.check(), isNull);
    expect(UpdateService.state.value.stage, UpdateStage.upToDate);
    expect(await UpdateService.check(manual: true), isNotNull);
    expect(UpdateService.state.value.stage, UpdateStage.available);
  });

  test("Tell me only checks", () async {
    await UpdateService.setMode(UpdateMode.notify);
    await UpdateService.runAutomatically();
    expect(UpdateService.state.value.stage, UpdateStage.available);
    expect(fetched.where((url) => url.endsWith(".apk")), isEmpty);
  });

  test("Off doesn't even check", () async {
    await UpdateService.setMode(UpdateMode.off);
    await UpdateService.runAutomatically();
    expect(fetched, isEmpty);
  });

  test("Download and ask downloads once and doesn't install by itself", () async {
    await UpdateService.runAutomatically();
    expect(UpdateService.state.value.stage, UpdateStage.ready);
    await UpdateService.runAutomatically();
    expect(fetched.where((url) => url.endsWith(".apk")).length, 1);
    expect(methods(), isNot(contains("install")));
  });

  test("without the install permission or on mobile data it only tells", () async {
    native["canInstall"] = false;
    await UpdateService.runAutomatically();
    UpdateService.unmetered = () async => false;
    native["canInstall"] = true;
    await UpdateService.runAutomatically();
    expect(fetched.where((url) => url.endsWith(".apk")), isEmpty);
    expect(UpdateService.state.value.stage, UpdateStage.available);
  });

  test("Install automatically installs silently when nothing is playing", () async {
    await UpdateService.setMode(UpdateMode.auto);
    native["lastResult"] = {"status": "cancelled"};
    await UpdateService.runAutomatically();
    final install = calls.singleWhere((call) => call.method == "install");
    expect((install.arguments as Map)["silent"], isTrue);
  });

  test("Install automatically waits for the music to pause", () async {
    await UpdateService.setMode(UpdateMode.auto);
    native["lastResult"] = {"status": "cancelled"};
    isPlaying = true;
    await UpdateService.runAutomatically();
    expect(methods(), isNot(contains("install")));
    playingChanges.add(true);
    await pumpEventQueue();
    expect(methods(), isNot(contains("install")));
    isPlaying = false;
    playingChanges.add(false);
    await pumpEventQueue();
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    expect(methods().where((method) => method == "install").length, 1);
  });

  test("leaving Install automatically while it waits for a pause doesn't install", () async {
    await UpdateService.setMode(UpdateMode.auto);
    isPlaying = true;
    await UpdateService.runAutomatically();
    await UpdateService.setMode(UpdateMode.ask);
    isPlaying = false;
    playingChanges.add(false);
    await pumpEventQueue();
    expect(methods(), isNot(contains("install")));
  });

  test("a mode changed during the download is the one that counts", () async {
    await UpdateService.setMode(UpdateMode.auto);
    final downloading = Completer<void>();
    UpdateService.client = () => MockClient((request) async {
      fetched.add(request.url.toString());
      if (request.url.host == "api.github.com") return http.Response(jsonEncode(release()), 200);
      await downloading.future;
      return http.Response.bytes(apk, 200);
    });
    final run = UpdateService.runAutomatically();
    await pumpEventQueue();
    await UpdateService.setMode(UpdateMode.ask);
    downloading.complete();
    await run;
    expect(UpdateService.state.value.stage, UpdateStage.ready);
    expect(methods(), isNot(contains("install")));
  });

  test("turning on the daily check asks for notifications", () async {
    await UpdateService.setBackground(false);
    expect(notificationRequests, 0);
    await UpdateService.setBackground(true);
    expect(notificationRequests, 1);
  });

  test("one download or install at a time, whoever starts it", () async {
    final downloading = Completer<void>();
    UpdateService.client = () => MockClient((request) async {
      fetched.add(request.url.toString());
      if (request.url.host == "api.github.com") return http.Response(jsonEncode(release()), 200);
      await downloading.future;
      return http.Response.bytes(apk, 200);
    });
    final parsed = UpdateRelease.fromJson(release())!;
    final first = UpdateService.download(parsed);
    expect(await UpdateService.download(parsed), isNull);
    expect(await UpdateService.check(), isNull);
    await UpdateService.runAutomatically();
    downloading.complete();
    expect(await first, isNotNull);
    expect(fetched.where((url) => url.endsWith(".apk")).length, 1);
    expect(fetched.where((url) => url.contains("api.github.com")), isEmpty);
  });

  test("a check answering after a download started leaves it downloading", () async {
    final answering = Completer<void>();
    final downloading = Completer<void>();
    UpdateService.client = () => MockClient((request) async {
      fetched.add(request.url.toString());
      if (request.url.host == "api.github.com") {
        await answering.future;
        return http.Response(jsonEncode(release()), 200);
      }
      await downloading.future;
      return http.Response.bytes(apk, 200);
    });
    final late = UpdateService.check(manual: true);
    await pumpEventQueue();
    final download = UpdateService.download(UpdateRelease.fromJson(release())!);
    await pumpEventQueue();
    answering.complete();
    expect(await late, isNull);
    expect(UpdateService.state.value.stage, UpdateStage.downloading);
    downloading.complete();
    expect(await download, isNotNull);
  });

  test("skipping the version waiting for a pause stops its install at once", () async {
    await UpdateService.setMode(UpdateMode.auto);
    isPlaying = true;
    await UpdateService.runAutomatically();
    final skipping = UpdateService.skip(UpdateRelease.fromJson(release())!);
    isPlaying = false;
    playingChanges.add(false);
    await skipping;
    await pumpEventQueue();
    expect(methods(), isNot(contains("install")));
  });

  test("a version skipped during its automatic download isn't installed", () async {
    await UpdateService.setMode(UpdateMode.auto);
    final downloading = Completer<void>();
    UpdateService.client = () => MockClient((request) async {
      fetched.add(request.url.toString());
      if (request.url.host == "api.github.com") return http.Response(jsonEncode(release()), 200);
      await downloading.future;
      return http.Response.bytes(apk, 200);
    });
    final run = UpdateService.runAutomatically();
    await pumpEventQueue();
    await UpdateService.skip(UpdateRelease.fromJson(release())!);
    downloading.complete();
    await run;
    expect(methods(), isNot(contains("install")));
  });

  test("skipping the version stops a waiting install even before the skip is saved", () async {
    final prefs = _SlowPrefs();
    SharedPreferencesAsyncPlatform.instance = prefs;
    await UpdateService.setMode(UpdateMode.auto);
    isPlaying = true;
    await UpdateService.runAutomatically();
    prefs.held = "updateCheckDismissedTag";
    final skipping = UpdateService.skip(UpdateRelease.fromJson(release())!);
    isPlaying = false;
    playingChanges.add(false);
    await pumpEventQueue();
    prefs.release.complete();
    await skipping;
    await pumpEventQueue();
    expect(methods(), isNot(contains("install")));
  });

  test("a version skipped while its download's install decision is made isn't installed", () async {
    final prefs = _SlowPrefs();
    SharedPreferencesAsyncPlatform.instance = prefs;
    await UpdateService.setMode(UpdateMode.auto);
    final downloading = Completer<void>();
    UpdateService.client = () => MockClient((request) async {
      fetched.add(request.url.toString());
      if (request.url.host == "api.github.com") return http.Response(jsonEncode(release()), 200);
      await downloading.future;
      return http.Response.bytes(apk, 200);
    });
    final run = UpdateService.runAutomatically();
    await pumpEventQueue();
    prefs.held = "updateCheckDismissedTag";
    final skipping = UpdateService.skip(UpdateRelease.fromJson(release())!);
    downloading.complete();
    await run;
    prefs.release.complete();
    await skipping;
    expect(methods(), isNot(contains("install")));
  });

  test("switching updates off stops a waiting install even before the setting is saved", () async {
    final prefs = _SlowPrefs();
    SharedPreferencesAsyncPlatform.instance = prefs;
    await UpdateService.setMode(UpdateMode.auto);
    isPlaying = true;
    await UpdateService.runAutomatically();
    prefs.held = "updateMode";
    // Switched off, its save still under way, when the music pauses.
    final off = UpdateService.setMode(UpdateMode.off);
    isPlaying = false;
    playingChanges.add(false);
    await pumpEventQueue();
    prefs.release.complete();
    await off;
    await pumpEventQueue();
    expect(methods(), isNot(contains("install")));
  });

  test("a mode changed during the check is the one that counts", () async {
    final answering = Completer<void>();
    UpdateService.client = () => MockClient((request) async {
      fetched.add(request.url.toString());
      if (request.url.host == "api.github.com") {
        await answering.future;
        return http.Response(jsonEncode(release()), 200);
      }
      return http.Response.bytes(apk, 200);
    });
    final run = UpdateService.runAutomatically();
    await pumpEventQueue();
    await UpdateService.setMode(UpdateMode.notify);
    answering.complete();
    await run;
    expect(fetched.where((url) => url.endsWith(".apk")), isEmpty);
  });

  test("a server that never answers ends the download", () async {
    UpdateService.responseWait = const Duration(milliseconds: 200);
    UpdateService.client = () => MockClient((request) => Completer<http.Response>().future);
    expect(await UpdateService.download(UpdateRelease.fromJson(release())!), isNull);
    expect(UpdateService.state.value.stage, UpdateStage.failed);
    UpdateService.responseWait = const Duration(seconds: 30);
  });

  test("no room for the download fails instead of hanging", () async {
    UpdateService.folder = () async => throw const FileSystemException("No space left on device");
    expect(await UpdateService.download(UpdateRelease.fromJson(release())!), isNull);
    expect(UpdateService.state.value.stage, UpdateStage.failed);
    expect(UpdateService.state.value.message, contains("No space left"));
  });

  test("the first start asks for notifications once, for the daily check", () async {
    UpdateService.enabled = true;
    await UpdateService.start();
    await UpdateService.runAutomatically();
    expect(notificationRequests, 1);
    UpdateService.reset();
    await UpdateService.start();
    await UpdateService.runAutomatically();
    expect(notificationRequests, 1);
    UpdateService.enabled = false;
  });

  test("Android refusing the download shows why", () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == "problem" ? "The download isn't signed like this Finamp+." : null;
    });
    final file = File("${dir.path}/x.apk")..writeAsBytesSync(apk);
    await UpdateService.install(file, UpdateRelease.fromJson(release())!);
    expect(UpdateService.state.value.stage, UpdateStage.failed);
    expect(UpdateService.state.value.message, "The download isn't signed like this Finamp+.");
    expect(methods(), isNot(contains("install")));
  });

  test("the daily check follows the mode and switch", () async {
    UpdateService.enabled = true;
    await UpdateService.setMode(UpdateMode.off);
    expect((calls.last.arguments as Map)["check"], isFalse);
    await UpdateService.setMode(UpdateMode.ask);
    expect((calls.last.arguments as Map)["check"], isTrue);
    await UpdateService.setBackground(false);
    expect((calls.last.arguments as Map)["check"], isFalse);
    UpdateService.enabled = false;
  });

  test("at start, old and unfinished downloads go and a newer one stays", () async {
    UpdateService.enabled = true;
    for (final name in [
      "old.apk",
      "finamp-plus-v1.6.71-arm64.apk",
      "finamp-plus-v1.6.72-arm64.apk",
      "finamp-plus-v1.6.73-arm64.apk.part",
    ]) {
      File("${dir.path}/$name").writeAsBytesSync(apk);
    }
    await SharedPreferencesAsync().setString("updateMode", "off");
    await UpdateService.start();
    expect([for (final entry in dir.listSync()) entry.uri.pathSegments.last], ["finamp-plus-v1.6.72-arm64.apk"]);
    UpdateService.enabled = false;
  });
}
