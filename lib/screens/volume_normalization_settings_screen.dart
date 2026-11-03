import 'dart:io';

import 'package:finamp/components/finamp_app_bar_back_button.dart';
import 'package:finamp/l10n/app_localizations.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:finamp/services/loudness_normalization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'analyzer_settings_screen.dart';

class VolumeNormalizationSettingsScreen extends ConsumerWidget {
  const VolumeNormalizationSettingsScreen({super.key});
  static const routeName = '/settings/volume-normalization';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final settings = ref.watch(finampSettingsProvider).valueOrNull ?? FinampSettingsHelper.finampSettings;
    final enabled = settings.volumeNormalizationActive;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.volumeNormalizationSettingsTitle),
        leading: FinampAppBarBackButton(),
        actions: [
          FinampSettingsHelper.makeSettingsResetButtonWithDialog(
            context,
            FinampSettingsHelper.resetNormalizationSettings,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 48),
        children: [
          SwitchListTile.adaptive(
            title: Text(l10n.volumeNormalizationSwitchTitle),
            subtitle: Text(l10n.normalizationDescription),
            value: enabled,
            onChanged: FinampSetters.setVolumeNormalizationActive,
          ),
          RadioGroup<int>(
            groupValue: LoudnessLevel.fromSetting(settings.normalizationLevel).index,
            onChanged: (value) {
              if (value != null && enabled) FinampSetters.setNormalizationLevel(value);
            },
            child: Column(
              children: [
                for (final level in LoudnessLevel.values)
                  RadioListTile<int>(
                    title: Text(switch (level) {
                      LoudnessLevel.quiet => l10n.normalizationQuiet,
                      LoudnessLevel.normal => l10n.normalizationNormal,
                      LoudnessLevel.loud => l10n.normalizationLoud,
                    }),
                    subtitle: Text(
                      level == LoudnessLevel.loud
                          ? l10n.normalizationLoudDescription
                          : l10n.normalizationNaturalDescription,
                    ),
                    value: level.index,
                    enabled: enabled && (Platform.isAndroid || level != LoudnessLevel.loud),
                  ),
              ],
            ),
          ),
          const Divider(),
          ListTile(
            title: Text(l10n.normalizationScope),
            subtitle: DropdownButton<VolumeNormalizationMode>(
              isExpanded: true,
              value: settings.volumeNormalizationMode,
              items: [
                for (final mode in VolumeNormalizationMode.values)
                  DropdownMenuItem(
                    value: mode,
                    child: Text(switch (mode) {
                      VolumeNormalizationMode.hybrid => l10n.normalizationAutomatic,
                      VolumeNormalizationMode.trackBased => l10n.normalizationTracks,
                      VolumeNormalizationMode.albumBased => l10n.normalizationAlbums,
                      VolumeNormalizationMode.albumOnly => l10n.normalizationAlbumsOnly,
                    }),
                  ),
              ],
              onChanged: enabled
                  ? (value) {
                      if (value != null) FinampSetters.setVolumeNormalizationMode(value);
                    }
                  : null,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(l10n.normalizationAutomaticDescription),
          ),
          ListTile(
            title: Text(l10n.analyzerSettings),
            subtitle: Text(l10n.normalizationAnalyzerDescription),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).pushNamed(AnalyzerSettingsScreen.routeName),
          ),
          if (!Platform.isAndroid)
            Padding(padding: const EdgeInsets.all(16), child: Text(l10n.normalizationPlatformLimit)),
        ],
      ),
    );
  }
}
