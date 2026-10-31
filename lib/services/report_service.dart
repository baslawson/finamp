import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:finamp/services/finamp_logs_helper.dart';
import 'package:finamp/services/server_hub_service.dart';
import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Sends the app's logs, and bug reports with a screenshot, to the server hub, so they can be read there instead of
/// being copied off the phone. The server keeps each user's newest 5 log uploads and bug reports for a week.
class ReportService {
  ReportService._();

  static const _autoKey = "reportsAutoUpload";
  static const _bugButtonKey = "reportsBugButton";
  static const _lastAutoKey = "reportsLastAutoUpload";
  static final _logger = Logger("ReportService");

  /// Whether the floating bug button shows.
  static final bugButton = ValueNotifier(false);

  /// After an error, this long passes before the upload, so the logs show what happened next too.
  @visibleForTesting
  static Duration settle = const Duration(seconds: 30);

  /// Automatic uploads are at most this often.
  @visibleForTesting
  static Duration spacing = const Duration(hours: 1);

  @visibleForTesting
  static Future<ServerHubService?> Function() connect = ServerHubService.connect;
  @visibleForTesting
  static Future<Uint8List> Function({Uint8List? screenshot, String? note}) archive = ({screenshot, note}) =>
      GetIt.instance<FinampLogsHelper>().reportArchive(screenshot: screenshot, note: note);
  @visibleForTesting
  static Future<bool> Function() unmetered = () async {
    final connections = await Connectivity().checkConnectivity();
    return connections.contains(ConnectivityResult.wifi) || connections.contains(ConnectivityResult.ethernet);
  };
  @visibleForTesting
  static DateTime Function() now = DateTime.now;

  static bool _started = false;
  static StreamSubscription<LogRecord>? _errors;
  static Timer? _pending;
  static Future<void>? _uploading;
  // Counts the times automatic uploads were turned off: an automatic upload queued before that doesn't go.
  static int _consent = 0;

  static SharedPreferencesAsync get _prefs => SharedPreferencesAsync();

  static Future<bool> autoUpload() async => await _prefs.getBool(_autoKey) ?? true;

  static Future<void> setAutoUpload(bool value) async {
    // At once, before saving: nothing automatic goes out after the user said no.
    if (!value) {
      _consent++;
      _pending?.cancel();
    }
    await _prefs.setBool(_autoKey, value);
  }

  static Future<void> setBugButton(bool value) async {
    await _prefs.setBool(_bugButtonKey, value);
    bugButton.value = value;
  }

  /// Once per app start: shows the bug button when it's on, uploads after errors, and once a day on Wi-Fi.
  static Future<void> start() async {
    if (_started) return;
    _started = true;
    bugButton.value = await _prefs.getBool(_bugButtonKey) ?? false;
    _errors = Logger.root.onRecord.listen((record) {
      // Its own failures don't start another upload.
      if (record.level >= Level.SEVERE && record.loggerName != _logger.name) _afterError();
    });
    final last = await _prefs.getInt(_lastAutoKey);
    if (await autoUpload() &&
        (last == null || now().difference(DateTime.fromMillisecondsSinceEpoch(last)) > const Duration(days: 1)) &&
        await unmetered()) {
      unawaited(_uploadAutomatically());
    }
  }

  @visibleForTesting
  static void reset() {
    _started = false;
    unawaited(_errors?.cancel());
    _errors = null;
    _pending?.cancel();
    _pending = null;
    _uploading = null;
    _consent = 0;
    bugButton.value = false;
  }

  static void _afterError() {
    if (_pending?.isActive ?? false) return;
    _pending = Timer(settle, () => unawaited(_uploadAutomatically()));
  }

  static Future<void> _uploadAutomatically() async {
    final consent = _consent;
    if (!await autoUpload() || consent != _consent) return;
    final last = await _prefs.getInt(_lastAutoKey);
    if (last != null && now().difference(DateTime.fromMillisecondsSinceEpoch(last)) < spacing) return;
    await _prefs.setInt(_lastAutoKey, now().millisecondsSinceEpoch);
    try {
      await _upload("logs", consent: consent);
    } catch (e) {
      _logger.info("Couldn't upload the logs automatically: $e");
    }
  }

  /// Uploads the logs. Throws with a reason when there's no server hub or it didn't take them.
  static Future<void> uploadLogs() => _upload("logs");

  /// Uploads a bug report: the [screenshot], the user's [note] and the logs.
  static Future<void> uploadBug(Uint8List screenshot, String note) =>
      _upload("bug", screenshot: screenshot, note: note);

  // One at a time: a second waits for the first, then goes.
  // An automatic upload carries the [consent] it was allowed under, and doesn't go when that changed meanwhile.
  static Future<void> _upload(String kind, {Uint8List? screenshot, String? note, int? consent}) async {
    // The account it was made in, before any wait: switched meanwhile, the hub refuses it instead of the report going
    // to the other account.
    final hub = await connect();
    if (hub == null) throw const ServerHubException("Set up the server hub first");
    for (var busy = _uploading; busy != null; busy = _uploading) {
      await busy.catchError((_) {});
    }
    if (consent != null && consent != _consent) return;
    final upload = _send(hub, kind, screenshot: screenshot, note: note, consent: consent);
    _uploading = upload;
    try {
      await upload;
    } finally {
      if (identical(_uploading, upload)) _uploading = null;
    }
  }

  static Future<void> _send(
    ServerHubService hub,
    String kind, {
    Uint8List? screenshot,
    String? note,
    int? consent,
  }) async {
    hub.checkAccount();
    final body = await archive(screenshot: screenshot, note: note);
    // Zipping takes a moment: turned off meanwhile, the logs stay here. Checked right before sending.
    if (consent != null && consent != _consent) return;
    await hub.request(
      "POST",
      "/api/reports/$kind",
      body: body,
      contentType: "application/zip",
      timeout: const Duration(minutes: 2),
    );
    _logger.info("Uploaded the ${kind == "bug" ? "bug report" : "logs"} to the server hub (${body.length} bytes)");
  }
}
