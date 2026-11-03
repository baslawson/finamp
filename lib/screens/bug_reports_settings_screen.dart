import 'dart:async';

import 'package:finamp/components/finamp_app_bar_back_button.dart';
import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/services/report_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

/// Sending logs and bug reports to the server hub.
class BugReportsSettingsScreen extends StatefulWidget {
  const BugReportsSettingsScreen({super.key});
  static const routeName = "/settings/bug-reports";

  @override
  State<BugReportsSettingsScreen> createState() => _BugReportsSettingsScreenState();
}

class _BugReportsSettingsScreenState extends State<BugReportsSettingsScreen> {
  bool _auto = true;
  bool _uploading = false;

  @override
  void initState() {
    super.initState();
    unawaited(ReportService.autoUpload().then((value) => mounted ? setState(() => _auto = value) : null));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.bugReports), leading: const FinampAppBarBackButton()),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 200),
        children: [
          ListTile(
            leading: const Icon(TablerIcons.cloud_upload),
            title: Text(context.l10n.uploadLogsNow),
            subtitle: Text(context.l10n.uploadLogsNowHelp),
            trailing: _uploading
                ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : null,
            onTap: _uploading
                ? null
                : () => unawaited(uploadLogs((busy) => mounted ? setState(() => _uploading = busy) : null)),
          ),
          SwitchListTile(
            secondary: const Icon(TablerIcons.refresh_alert),
            title: Text(context.l10n.uploadLogsAutomatically),
            subtitle: Text(context.l10n.uploadLogsAutomaticallyHelp),
            value: _auto,
            onChanged: (value) {
              setState(() => _auto = value);
              unawaited(ReportService.setAutoUpload(value));
            },
          ),
          ValueListenableBuilder(
            valueListenable: ReportService.bugButton,
            builder: (context, shown, _) => SwitchListTile(
              secondary: const Icon(TablerIcons.bug),
              title: Text(context.l10n.bugButton),
              subtitle: Text(context.l10n.bugButtonHelp),
              value: shown,
              onChanged: (value) => unawaited(ReportService.setBugButton(value)),
            ),
          ),
        ],
      ),
    );
  }
}

/// Uploads the logs now, saying how it went. [busy] hears when it starts and ends.
Future<void> uploadLogs([void Function(bool busy)? busy]) async {
  busy?.call(true);
  try {
    await ReportService.uploadLogs();
    GlobalSnackbar.message((context) => context.l10n.logsUploaded, isConfirmation: true);
  } catch (e) {
    GlobalSnackbar.error(e);
  } finally {
    busy?.call(false);
  }
}
