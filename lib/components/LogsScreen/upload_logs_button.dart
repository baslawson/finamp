import 'dart:async';

import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/screens/bug_reports_settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

/// Sends the logs to the server hub.
class UploadLogsButton extends StatefulWidget {
  const UploadLogsButton({super.key});

  @override
  State<UploadLogsButton> createState() => _UploadLogsButtonState();
}

class _UploadLogsButtonState extends State<UploadLogsButton> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: _busy
          ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(TablerIcons.cloud_upload),
      tooltip: context.l10n.uploadLogsNow,
      onPressed: _busy ? null : () => unawaited(uploadLogs((busy) => mounted ? setState(() => _busy = busy) : null)),
    );
  }
}
