import 'dart:async';

import 'package:finamp/components/finamp_app_bar_back_button.dart';
import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/services/update_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

/// The installed version, and checking for, downloading and installing a newer Finamp+.
class UpdatesSettingsScreen extends StatefulWidget {
  const UpdatesSettingsScreen({super.key});
  static const routeName = "/settings/updates";

  @override
  State<UpdatesSettingsScreen> createState() => _UpdatesSettingsScreenState();
}

class _UpdatesSettingsScreenState extends State<UpdatesSettingsScreen> with WidgetsBindingObserver {
  Map<String, dynamic> _info = {};
  UpdateMode _mode = UpdateMode.ask;
  bool _background = true;

  static const _obtainium = "dev.imranr.obtainium";

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_load());
    if (UpdateService.state.value.stage == UpdateStage.idle) unawaited(UpdateService.check(manual: true));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Back from Android's "Install unknown apps" switch.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_load());
  }

  Future<void> _load() async {
    final info = await UpdateService.info();
    final mode = await UpdateService.mode();
    final background = await UpdateService.background();
    if (!mounted) return;
    setState(() {
      _info = info;
      _mode = mode;
      _background = background;
    });
  }

  String _date(Object? millis) =>
      millis is int ? DateFormat.yMMMd().format(DateTime.fromMillisecondsSinceEpoch(millis)) : "";

  String _installer(BuildContext context) => switch (_info["installer"]) {
    _obtainium => "Obtainium",
    "com.android.vending" => "Google Play",
    final String name when name == "com.baslawson.finampplus" => context.l10n.updateInstalledBySelf,
    final String name => name,
    _ => context.l10n.updateInstalledByUnknown,
  };

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.updates), leading: const FinampAppBarBackButton()),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 200),
        children: [
          Text(
            context.l10n.updateVersion(_info["version"] as String? ?? "", "${_info["build"] ?? ""}"),
            style: textTheme.titleLarge,
          ),
          if (_info.isNotEmpty) ...[
            Text(context.l10n.updateDates(_date(_info["installedAt"]), _date(_info["updatedAt"]))),
            Text(context.l10n.updateInstalledBy(_installer(context))),
          ],
          const SizedBox(height: 16),
          ValueListenableBuilder(valueListenable: UpdateService.state, builder: (context, state, _) => _status(state)),
          if (_info.isNotEmpty && _info["canInstall"] != true) ...[
            const SizedBox(height: 8),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(TablerIcons.shield_lock),
              title: Text(context.l10n.updateAllowInstall),
              subtitle: Text(context.l10n.updateAllowInstallHelp),
              onTap: () => unawaited(UpdateService.openInstallSettings()),
            ),
          ],
          const Divider(height: 32),
          Text(context.l10n.updateModeTitle, style: textTheme.titleMedium),
          RadioGroup<UpdateMode>(
            groupValue: _mode,
            onChanged: (value) {
              if (value == null) return;
              setState(() => _mode = value);
              unawaited(UpdateService.setMode(value));
            },
            child: Column(
              children: [
                for (final mode in UpdateMode.values)
                  RadioListTile<UpdateMode>(
                    contentPadding: EdgeInsets.zero,
                    value: mode,
                    title: Text(switch (mode) {
                      UpdateMode.off => context.l10n.updateModeOff,
                      UpdateMode.notify => context.l10n.updateModeNotify,
                      UpdateMode.ask => context.l10n.updateModeAsk,
                      UpdateMode.auto => context.l10n.updateModeAuto,
                    }),
                    subtitle: Text(switch (mode) {
                      UpdateMode.off => context.l10n.updateModeOffHelp,
                      UpdateMode.notify => context.l10n.updateModeNotifyHelp,
                      UpdateMode.ask => context.l10n.updateModeAskHelp,
                      UpdateMode.auto => context.l10n.updateModeAutoHelp,
                    }),
                  ),
              ],
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(context.l10n.updateBackground),
            subtitle: Text(context.l10n.updateBackgroundHelp),
            value: _background,
            onChanged: _mode == UpdateMode.off
                ? null
                : (value) {
                    setState(() => _background = value);
                    unawaited(UpdateService.setBackground(value));
                  },
          ),
          if (_info["installer"] == _obtainium) ...[
            const SizedBox(height: 8),
            Text(context.l10n.updateObtainiumHint, style: textTheme.bodySmall),
          ],
        ],
      ),
    );
  }

  Widget _status(UpdateState state) {
    final release = state.release;
    final textTheme = Theme.of(context).textTheme;
    final mb = NumberFormat("0.0");
    String size(int bytes) => mb.format(bytes / (1024 * 1024));
    final check = OutlinedButton.icon(
      onPressed: () => unawaited(UpdateService.check(manual: true)),
      icon: const Icon(TablerIcons.refresh),
      label: Text(context.l10n.updateCheckNow),
    );
    return switch (state.stage) {
      UpdateStage.idle || UpdateStage.checking => Row(
        children: [
          const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 12),
          Text(context.l10n.updateChecking),
        ],
      ),
      UpdateStage.upToDate => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(context.l10n.updateUpToDate, style: textTheme.titleMedium),
          const SizedBox(height: 8),
          check,
        ],
      ),
      UpdateStage.failed => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(context.l10n.updateFailed, style: textTheme.titleMedium),
          if (state.message != null) Text(state.message!),
          const SizedBox(height: 8),
          if (release != null && UpdateService.isNewer(release.tag, _info["version"] as String? ?? ""))
            FilledButton.icon(
              onPressed: () => unawaited(UpdateService.downloadAndInstall(release)),
              icon: const Icon(TablerIcons.download),
              label: Text(context.l10n.updateTryAgain),
            )
          else
            check,
        ],
      ),
      UpdateStage.available || UpdateStage.downloading || UpdateStage.ready || UpdateStage.installing => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(context.l10n.updateNewVersion(release!.tag), style: textTheme.titleMedium),
          if (release.name != release.tag) Text(release.name),
          if (release.notes.trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            SelectableText(release.notes.replaceAll("**", "").trim(), style: textTheme.bodySmall),
          ],
          const SizedBox(height: 12),
          if (state.stage == UpdateStage.downloading) ...[
            LinearProgressIndicator(value: state.total > 0 ? state.received / state.total : null),
            const SizedBox(height: 4),
            Text(context.l10n.updateDownloading(size(state.received), size(state.total))),
          ] else if (state.stage == UpdateStage.installing)
            Text(context.l10n.updateInstalling)
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: _info["canInstall"] == true
                      ? () => unawaited(UpdateService.downloadAndInstall(release))
                      : null,
                  icon: const Icon(TablerIcons.download),
                  label: Text(
                    state.stage == UpdateStage.ready ? context.l10n.updateInstall : context.l10n.updateDownloadInstall,
                  ),
                ),
                OutlinedButton(
                  onPressed: () => unawaited(UpdateService.skip(release)),
                  child: Text(context.l10n.updateSkip),
                ),
                TextButton(
                  onPressed: () => launchUrl(Uri.parse(release.pageUrl), mode: LaunchMode.externalApplication),
                  child: Text(context.l10n.updateReleasePage),
                ),
              ],
            ),
        ],
      ),
    };
  }
}
