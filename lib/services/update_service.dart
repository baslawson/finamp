import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:crypto/crypto.dart';
import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/services/music_player_background_task.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

/// What Finamp+ does when a new version is out.
enum UpdateMode {
  /// Nothing; check by hand on the Updates page.
  off,

  /// A message, as before.
  notify,

  /// Downloads it (on Wi-Fi), then offers a one-tap install.
  ask,

  /// Downloads and installs it (on Wi-Fi), waiting until nothing is playing.
  auto,
}

enum UpdateStage { idle, checking, upToDate, available, downloading, ready, installing, failed }

/// A file of a release, with the checksum GitHub keeps for it.
class UpdateAsset {
  const UpdateAsset({required this.name, required this.url, required this.size, this.sha256});

  final String name, url;
  final int size;
  final String? sha256;
}

/// A Finamp+ release on GitHub.
class UpdateRelease {
  const UpdateRelease({
    required this.tag,
    required this.name,
    required this.notes,
    required this.pageUrl,
    required this.assets,
  });

  final String tag, name, notes, pageUrl;
  final List<UpdateAsset> assets;

  static UpdateRelease? fromJson(Map<String, dynamic> json) {
    final tag = json["tag_name"], page = json["html_url"];
    if (tag is! String || page is! String) return null;
    return UpdateRelease(
      tag: tag,
      name: json["name"] is String && (json["name"] as String).isNotEmpty ? json["name"] as String : tag,
      notes: json["body"] is String ? json["body"] as String : "",
      pageUrl: page,
      assets: [
        for (final asset in (json["assets"] as List?) ?? const [])
          if (asset is Map &&
              asset["name"] is String &&
              asset["browser_download_url"] is String &&
              asset["size"] is int)
            UpdateAsset(
              name: asset["name"] as String,
              url: asset["browser_download_url"] as String,
              size: asset["size"] as int,
              sha256: asset["digest"] is String && (asset["digest"] as String).startsWith("sha256:")
                  ? (asset["digest"] as String).substring(7).toLowerCase()
                  : null,
            ),
      ],
    );
  }
}

class UpdateState {
  const UpdateState(this.stage, {this.release, this.received = 0, this.total = 0, this.message});

  final UpdateStage stage;
  final UpdateRelease? release;
  final int received, total;
  final String? message;
}

/// Finamp+ updating itself from the fork's GitHub releases: checking, downloading the right APK and checking its
/// checksum, and handing it to Android to install. Android only accepts it when it's signed like this app.
class UpdateService {
  UpdateService._();

  static const _latestReleaseUrl = "https://api.github.com/repos/baslawson/finamp/releases/latest";
  static const _modeKey = "updateMode";
  static const _backgroundKey = "updateBackgroundCheck";
  static const _skippedKey = "updateCheckDismissedTag";
  static const _lastVersionKey = "updateLastVersion";
  static const _askedNotificationsKey = "updateAskedNotifications";
  static const _channel = MethodChannel("com.unicornsonlsd.finamp/updates");
  static final _logger = Logger("UpdateService");

  static final state = ValueNotifier(const UpdateState(UpdateStage.idle));

  /// Only Android release builds update themselves: those are what the fork publishes.
  @visibleForTesting
  static bool enabled = kReleaseMode && Platform.isAndroid;
  @visibleForTesting
  static bool android = Platform.isAndroid;
  @visibleForTesting
  static http.Client Function() client = http.Client.new;
  @visibleForTesting
  static Future<Directory> Function() folder = () async => Directory("${(await getTemporaryDirectory()).path}/updates");
  @visibleForTesting
  static Future<String> Function() installedVersion = () async => (await PackageInfo.fromPlatform()).version;
  @visibleForTesting
  static bool Function() playing = () =>
      GetIt.instance.isRegistered<MusicPlayerBackgroundTask>() &&
      GetIt.instance<MusicPlayerBackgroundTask>().playbackState.value.playing;
  @visibleForTesting
  static Stream<bool> Function() playingChanges = () =>
      GetIt.instance<MusicPlayerBackgroundTask>().playbackState.map((state) => state.playing).distinct();
  @visibleForTesting
  static Future<bool> Function() unmetered = () async {
    final connections = await Connectivity().checkConnectivity();
    return connections.contains(ConnectivityResult.wifi) || connections.contains(ConnectivityResult.ethernet);
  };
  @visibleForTesting
  static Duration installResultWait = const Duration(minutes: 3);
  @visibleForTesting
  static Duration responseWait = const Duration(seconds: 30);
  /// How often a dropped download resumes before it fails, waiting a little longer each time.
  @visibleForTesting
  static int downloadRetries = 3;
  @visibleForTesting
  static Duration retryWait = const Duration(seconds: 5);

  static bool _started = false;
  static Future<void>? _running;
  static Timer? _timer;
  static StreamSubscription<bool>? _waitingForPause;
  // The wait that may still install, after it stopped listening.
  static StreamSubscription<bool>? _waitingFor;

  static SharedPreferencesAsync get _prefs => SharedPreferencesAsync();

  // The mode and skipped version as the user last chose them, set the moment they choose (before saving), so the
  // last look before an automatic install waits for nothing that could change meanwhile.
  static UpdateMode? _mode;
  static String? _skipped;
  static bool _skippedLoaded = false;

  static Future<UpdateMode> mode() async {
    if (_mode case final known?) return known;
    final name = await _prefs.getString(_modeKey);
    return _mode ??= UpdateMode.values.where((mode) => mode.name == name).firstOrNull ?? UpdateMode.ask;
  }

  static Future<void> setMode(UpdateMode value) async {
    _mode = value;
    // Only "Install automatically" installs by itself: an install waiting for a pause stops at once.
    if (value != UpdateMode.auto) _stopWaiting();
    await _prefs.setString(_modeKey, value.name);
    await _configure();
  }

  /// Whether Android checks once a day while Finamp+ is closed.
  static Future<bool> background() async => await _prefs.getBool(_backgroundKey) ?? true;

  static Future<void> setBackground(bool value) async {
    await _prefs.setBool(_backgroundKey, value);
    await _configure();
    // The daily check tells by notification.
    if (value && android) await requestNotifications();
  }

  @visibleForTesting
  static Future<void> Function() requestNotifications = () => Permission.notification.request();

  static Future<String?> skipped() async {
    if (_skippedLoaded) return _skipped;
    final saved = await _prefs.getString(_skippedKey);
    if (!_skippedLoaded) {
      _skipped = saved;
      _skippedLoaded = true;
    }
    return _skipped;
  }

  static Future<void> skip(UpdateRelease release) async {
    _skipped = release.tag;
    _skippedLoaded = true;
    // At once: a pause while this is saved mustn't install the version being skipped.
    _stopWaiting();
    await _prefs.setString(_skippedKey, release.tag);
    await _configure();
    state.value = UpdateState(UpdateStage.upToDate, release: release);
  }

  static Future<void> _configure() async {
    if (!android) return;
    try {
      await _channel.invokeMethod("configure", {
        "check": enabled && await background() && await mode() != UpdateMode.off,
        "skipped": await skipped(),
      });
    } catch (e) {
      _logger.info("Couldn't set up the daily update check: $e");
    }
  }

  /// What Android knows about this install: version, build, dates, who installed it, and whether Finamp+ may
  /// install updates.
  static Future<Map<String, dynamic>> info() async {
    if (!android) return {};
    try {
      return Map<String, dynamic>.from(await _channel.invokeMethod<Map<Object?, Object?>>("info") ?? {});
    } catch (e) {
      return {};
    }
  }

  static Future<void> openInstallSettings() => _channel.invokeMethod("openInstallSettings");

  /// Once per app start: says when it was just updated, cleans up old downloads, then checks now and every 12 hours.
  static Future<void> start() async {
    if (_started || !enabled) return;
    _started = true;
    await _cleanUp();
    await _announceUpdate();
    await _configure();
    // The daily check is on from the start and tells by notification: Android 13 and later ask once.
    if (await background() && await mode() != UpdateMode.off && await _prefs.getBool(_askedNotificationsKey) != true) {
      await _prefs.setBool(_askedNotificationsKey, true);
      await requestNotifications();
    }
    unawaited(runAutomatically());
    _timer = Timer.periodic(const Duration(hours: 12), (_) => unawaited(runAutomatically()));
  }

  @visibleForTesting
  static void reset() {
    _started = false;
    _running = null;
    _timer?.cancel();
    _timer = null;
    _stopWaiting();
    _mode = null;
    _skipped = null;
    _skippedLoaded = false;
    state.value = const UpdateState(UpdateStage.idle);
  }

  /// Whether [release] may install by itself right now. Decided without waiting, right before installing.
  static Future<bool> _mayInstallAutomatically(UpdateRelease release) async {
    // Loaded first; after these, the answer comes from what the user last chose, not from a read still under way.
    await mode();
    await skipped();
    return _allowsAutomatic(release);
  }

  /// [_mayInstallAutomatically] once the settings are loaded, without waiting.
  static bool _allowsAutomatic(UpdateRelease release) => _mode == UpdateMode.auto && _skipped != release.tag;

  static void _cancelWaiting() {
    unawaited(_waitingForPause?.cancel());
    _waitingForPause = null;
  }

  static void _stopWaiting() {
    _cancelWaiting();
    _waitingFor = null;
  }

  /// Removes unfinished downloads and those of versions already installed; a newer one stays, ready to install.
  static Future<void> _cleanUp() async {
    try {
      final dir = await folder();
      if (!await dir.exists()) return;
      final installed = await installedVersion();
      for (final entry in await dir.list().toList()) {
        final name = entry.uri.pathSegments.lastWhere((segment) => segment.isNotEmpty);
        if (entry is File && name.endsWith(".apk") && isNewer(name, installed)) continue;
        await entry.delete(recursive: true);
      }
    } catch (e) {
      _logger.info("Couldn't remove old update downloads: $e");
    }
  }

  static Future<void> _announceUpdate() async {
    final installed = await installedVersion();
    final last = await _prefs.getString(_lastVersionKey);
    await _prefs.setString(_lastVersionKey, installed);
    if (last == null || !isNewer(installed, last)) return;
    GlobalSnackbar.message(
      (context) => context.l10n.updateInstalled(installed),
      action: (context) => SnackBarAction(
        label: context.l10n.updateWhatsNew,
        onPressed: () => launchUrl(
          Uri.parse("https://github.com/baslawson/finamp/releases/tag/v$installed"),
          mode: LaunchMode.externalApplication,
        ),
      ),
    );
  }

  /// A download or install is under way: one at a time, whether started here or automatically.
  static bool get _busy => state.value.stage == UpdateStage.downloading || state.value.stage == UpdateStage.installing;

  /// Checks GitHub for a newer release. [manual] checks show the result even for a skipped version. Nothing to do
  /// while a download or install is under way.
  static Future<UpdateRelease?> check({bool manual = false}) async {
    if (_busy) return null;
    state.value = const UpdateState(UpdateStage.checking);
    final web = client();
    try {
      final response = await web
          .get(Uri.parse(_latestReleaseUrl), headers: {"Accept": "application/vnd.github+json"})
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) throw HttpException("GitHub answered ${response.statusCode}");
      final release = UpdateRelease.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
      if (release == null) throw const FormatException("GitHub's answer has no release");
      final newer = isNewer(release.tag, await installedVersion());
      final skippedIt = !manual && await skipped() == release.tag;
      // Another check started a download meanwhile: that one counts.
      if (_busy) return null;
      state.value = UpdateState(newer && !skippedIt ? UpdateStage.available : UpdateStage.upToDate, release: release);
      return newer && !skippedIt ? release : null;
    } catch (e) {
      // No network or GitHub unreachable: try again later.
      _logger.info("Update check failed: $e");
      if (!_busy) state.value = UpdateState(UpdateStage.failed, message: manual ? "$e" : null);
      return null;
    } finally {
      web.close();
    }
  }

  /// The APK for this phone: the smaller ARM64 one where it runs, otherwise the one for every phone.
  @visibleForTesting
  static UpdateAsset? assetFor(UpdateRelease release, List<String> abis) {
    final apks = release.assets.where((asset) => asset.name.endsWith(".apk")).toList();
    final arm64 = apks.where((asset) => asset.name.endsWith("-arm64.apk")).firstOrNull;
    final universal = apks.where((asset) => !asset.name.endsWith("-arm64.apk")).firstOrNull;
    if (abis.contains("arm64-v8a") && arm64 != null) return arm64;
    return universal ?? arm64;
  }

  /// Downloads the release's APK for this phone and checks it against GitHub's checksum. An [automatic] download
  /// is on Wi-Fi only, so it doesn't resume once the phone has moved to mobile data.
  static Future<File?> download(UpdateRelease release, {bool automatic = false}) async {
    if (_busy) return null;
    // Claimed before anything is awaited, so a second download can't start meanwhile.
    state.value = UpdateState(UpdateStage.downloading, release: release);
    File? part;
    final web = client();
    try {
      final abis = ((await info())["abis"] as List?)?.whereType<String>().toList() ?? const <String>[];
      final asset = assetFor(release, abis);
      if (asset == null) throw const HttpException("The release has no app to install.");
      state.value = UpdateState(UpdateStage.downloading, release: release, total: asset.size);
      final dir = await folder();
      await dir.create(recursive: true);
      final file = File("${dir.path}/${asset.name}");
      part = File("${file.path}.part");
      // Written chunk by chunk and awaited, so a full or unwritable disk fails here instead of escaping later.
      final out = await part.open(mode: FileMode.write);
      var digest = _DigestSink();
      var hasher = sha256.startChunkedConversion(digest);
      var received = 0, shown = 0;
      try {
        // A dropped connection carries on from where it stopped, a few times, instead of failing the update.
        for (var attempt = 0; ; attempt++) {
          try {
            final request = http.Request("GET", Uri.parse(asset.url));
            if (received > 0) request.headers["Range"] = "bytes=$received-";
            // A server that never answers ends the download instead of leaving it waiting.
            final response = await web.send(request).timeout(responseWait);
            if (received > 0 && response.statusCode == 200) {
              // The whole file again rather than the rest: start over.
              hasher.close();
              digest = _DigestSink();
              hasher = sha256.startChunkedConversion(digest);
              await out.setPosition(0);
              await out.truncate(0);
              received = shown = 0;
            } else if (response.statusCode != (received > 0 ? 206 : 200)) {
              throw _GiveUp(HttpException("GitHub answered ${response.statusCode}"));
            }
            await for (final chunk in response.stream.timeout(const Duration(seconds: 60))) {
              await out.writeFrom(chunk);
              hasher.add(chunk);
              received += chunk.length;
              // About every 1 %, not every chunk.
              if (received - shown > asset.size ~/ 100) {
                shown = received;
                state.value = UpdateState(UpdateStage.downloading, release: release, received: received, total: asset.size);
              }
            }
            if (received >= asset.size) break;
            throw HttpException("The download stopped at $received of ${asset.size} bytes");
          } on _GiveUp catch (e) {
            throw e.error;
          } catch (e) {
            if (attempt >= downloadRetries || e is FileSystemException) rethrow;
            _logger.info("Update download interrupted at $received of ${asset.size} bytes, resuming: $e");
            await Future<void>.delayed(retryWait * (attempt + 1));
            // Checked right before resuming: the phone may have moved to mobile data while it waited.
            if (automatic && !await unmetered()) rethrow;
          }
        }
      } finally {
        hasher.close();
        await out.close();
      }
      if (received != asset.size) throw HttpException("The download stopped at $received of ${asset.size} bytes");
      if (asset.sha256 != null && digest.value.toString() != asset.sha256) {
        throw const HttpException("The download doesn't match GitHub's checksum");
      }
      await part.rename(file.path);
      state.value = UpdateState(UpdateStage.ready, release: release);
      return file;
    } catch (e) {
      _logger.warning("Update download failed: $e");
      try {
        if (await part?.exists() ?? false) await part!.delete();
      } catch (_) {}
      state.value = UpdateState(UpdateStage.failed, release: release, message: "$e");
      return null;
    } finally {
      web.close();
    }
  }

  /// Hands the APK to Android. With [silent], Android 12 and later skip the confirmation once Finamp+ installed
  /// itself before. On success Android closes Finamp+ and starts the new version.
  static Future<void> install(File file, UpdateRelease release, {bool silent = false}) async {
    if (state.value.stage == UpdateStage.installing) return;
    state.value = UpdateState(UpdateStage.installing, release: release);
    try {
      final problem = await _channel.invokeMethod<String>("problem", {"path": file.path});
      if (problem != null) throw StateError(problem);
      if (silent) {
        // Checking the APK took a moment: the user may have stopped or skipped it, or the music started again.
        if (!_allowsAutomatic(release)) {
          state.value = UpdateState(UpdateStage.ready, release: release);
          return;
        }
        if (playing()) {
          state.value = UpdateState(UpdateStage.ready, release: release);
          return await _installWhenQuiet(file, release);
        }
      }
      await _channel.invokeMethod("install", {"path": file.path, "silent": silent});
      // Android answers on its own time (after the user confirms, or not): look for it.
      final deadline = DateTime.now().add(installResultWait);
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(seconds: 1));
        final result = await _channel.invokeMethod<Map<Object?, Object?>>("lastResult");
        switch (result?["status"]) {
          case "cancelled":
            state.value = UpdateState(UpdateStage.ready, release: release);
            return;
          case "failed":
            throw StateError((result?["message"] as String?) ?? "Android didn't install it");
        }
      }
      // Still waiting for the user: they can install it from here again.
      if (state.value.stage == UpdateStage.installing) state.value = UpdateState(UpdateStage.ready, release: release);
    } catch (e) {
      _logger.warning("Update install failed: $e");
      state.value = UpdateState(
        UpdateStage.failed,
        release: release,
        message: e is StateError ? e.message : (e is PlatformException ? e.message : "$e"),
      );
    }
  }

  /// Downloads (when needed) and installs [release], from the Updates page.
  static Future<void> downloadAndInstall(UpdateRelease release) async {
    // Installing it now: an automatic install waiting for a pause isn't needed any more.
    _stopWaiting();
    final file = await _downloaded(release) ?? await download(release);
    if (file != null) await install(file, release);
  }

  static Future<File?> _downloaded(UpdateRelease release) async {
    final asset = assetFor(
      release,
      ((await info())["abis"] as List?)?.whereType<String>().toList() ?? const <String>[],
    );
    if (asset == null) return null;
    final file = File("${(await folder()).path}/${asset.name}");
    return await file.exists() ? file : null;
  }

  /// The regular check, done the way the update mode says. One at a time.
  static Future<void> runAutomatically() => _running ??= _runAutomatically().whenComplete(() => _running = null);

  static Future<void> _runAutomatically() async {
    if (await mode() == UpdateMode.off) return;
    final release = await check();
    if (release == null) return;
    // As it is now: it may have changed during the check.
    final chosen = await mode();
    if (chosen == UpdateMode.off) return;
    // Large downloads wait for Wi-Fi; on mobile data the message lets the user decide.
    final canInstall = (await info())["canInstall"] == true;
    if (chosen == UpdateMode.notify || !canInstall || !await unmetered()) return _offer(release);
    // Downloaded at an earlier check (and not installed yet): not again.
    final file = await _downloaded(release) ?? await download(release, automatic: true);
    if (file == null) return;
    // The version may have been skipped during the download, or the mode changed.
    if (!await _mayInstallAutomatically(release)) {
      if (_mode != UpdateMode.off && _skipped != release.tag) _offerInstall(release, file);
      return;
    }
    return _installWhenQuiet(file, release);
  }

  /// Installs [release] by itself now, or at the next pause: installing closes Finamp+, never in the middle of a song.
  static Future<void> _installWhenQuiet(File file, UpdateRelease release) async {
    if (!playing()) return install(file, release, silent: true);
    _cancelWaiting();
    late final StreamSubscription<bool> waiting;
    waiting = playingChanges().listen((isPlaying) async {
      if (isPlaying) return;
      _cancelWaiting();
      // Switching the mode away or skipping the version also stops this wait at once.
      if (await _mayInstallAutomatically(release) && identical(_waitingFor, waiting)) {
        await install(file, release, silent: true);
      }
    });
    _waitingForPause = _waitingFor = waiting;
  }

  static void _offer(UpdateRelease release) {
    GlobalSnackbar.message(
      (context) => context.l10n.updateAvailable(release.tag),
      action: (context) => SnackBarAction(
        label: context.l10n.updateView,
        onPressed: () => GlobalSnackbar.navigatorState?.pushNamed("/settings/updates"),
      ),
    );
  }

  static void _offerInstall(UpdateRelease release, File file) {
    GlobalSnackbar.message(
      (context) => context.l10n.updateReady(release.tag),
      action: (context) =>
          SnackBarAction(label: context.l10n.updateInstall, onPressed: () => unawaited(install(file, release))),
    );
  }

  /// Whether the release [tag] (e.g. "v1.2.0" or "v1.2.0-search.1") is newer than the [installed] version.
  static bool isNewer(String tag, String installed) {
    final remote = _parse(tag);
    final local = _parse(installed);
    if (remote == null || local == null) return false;
    for (var i = 0; i < 3; i++) {
      if (remote[i] != local[i]) return remote[i] > local[i];
    }
    return false;
  }

  static List<int>? _parse(String version) {
    final match = RegExp(r"(\d+)\.(\d+)\.(\d+)").firstMatch(version);
    if (match == null) return null;
    return [for (var group = 1; group <= 3; group++) int.parse(match.group(group)!)];
  }
}

/// An answer that retrying won't change.
class _GiveUp implements Exception {
  const _GiveUp(this.error);

  final Object error;
}

class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
