import 'dart:convert';
import 'dart:io';

import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/extensions/localizations.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

/// Checks the GitHub releases of the Finamp+ fork for a newer version.
class UpdateCheckService {
  UpdateCheckService._();

  static const _latestReleaseUrl = "https://api.github.com/repos/baslawson/finamp/releases/latest";
  static const _dismissedKey = "updateCheckDismissedTag";
  static final _logger = Logger("UpdateCheckService");
  static bool _checked = false;

  /// Shows a message with a download button if a newer release exists. Runs once per app start,
  /// only for Android release builds, since those are what the fork publishes.
  static Future<void> checkOnce() async {
    if (_checked || !kReleaseMode || !Platform.isAndroid) return;
    _checked = true;
    try {
      final response = await http
          .get(Uri.parse(_latestReleaseUrl), headers: {"Accept": "application/vnd.github+json"})
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) {
        _logger.info("Update check got status ${response.statusCode}");
        return;
      }
      final release = jsonDecode(response.body) as Map<String, dynamic>;
      final tag = release["tag_name"] as String?;
      final pageUrl = release["html_url"] as String?;
      if (tag == null || pageUrl == null) return;

      final installed = (await PackageInfo.fromPlatform()).version;
      if (!isNewer(tag, installed)) return;
      final prefs = SharedPreferencesAsync();
      if (await prefs.getString(_dismissedKey) == tag) return;

      GlobalSnackbar.message(
        (context) => context.l10n.updateAvailable(tag),
        action: (context) => SnackBarAction(
          label: context.l10n.updateDownload,
          onPressed: () {
            prefs.setString(_dismissedKey, tag);
            launchUrl(Uri.parse(pageUrl), mode: LaunchMode.externalApplication);
          },
        ),
      );
    } catch (e) {
      // No network or GitHub unreachable, try again on the next start.
      _logger.info("Update check failed: $e");
    }
  }

  /// Whether the release [tag] (e.g. "v1.2.0" or "v1.2.0-search.1") is newer than the [installed] version.
  @visibleForTesting
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
