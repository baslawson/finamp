import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/services/crossfade_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

/// Sets how long songs overlap.
class CrossfadeSettingsScreen extends StatefulWidget {
  const CrossfadeSettingsScreen({super.key});

  static const routeName = "/settings/crossfade";

  @override
  State<CrossfadeSettingsScreen> createState() => _CrossfadeSettingsScreenState();
}

class _CrossfadeSettingsScreenState extends State<CrossfadeSettingsScreen> {
  CrossfadeSettings? _settings;

  @override
  void initState() {
    super.initState();
    CrossfadeService.loadSettings().then((settings) {
      if (mounted) setState(() => _settings = settings);
    });
  }

  Future<void> _save(CrossfadeSettings settings) async {
    setState(() => _settings = settings);
    await CrossfadeService.saveSettings(settings);
  }

  @override
  Widget build(BuildContext context) {
    final settings = _settings;
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.crossfade)),
      body: settings == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                Text(context.l10n.crossfadeDescription),
                const SizedBox(height: 16),
                Text(context.l10n.crossfadeLength(settings.seconds), style: textTheme.titleMedium),
                Slider(
                  value: settings.seconds.toDouble(),
                  max: CrossfadeService.maxSeconds.toDouble(),
                  divisions: CrossfadeService.maxSeconds,
                  onChanged: (seconds) => setState(
                    () => _settings = (seconds: seconds.round(), keepAlbumsGapless: settings.keepAlbumsGapless),
                  ),
                  onChangeEnd: (seconds) =>
                      _save((seconds: seconds.round(), keepAlbumsGapless: settings.keepAlbumsGapless)),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(context.l10n.crossfadeKeepAlbums),
                  subtitle: Text(context.l10n.crossfadeKeepAlbumsSubtitle),
                  value: settings.keepAlbumsGapless,
                  onChanged: settings.seconds == 0
                      ? null
                      : (keep) => _save((seconds: settings.seconds, keepAlbumsGapless: keep)),
                ),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: settings.seconds == 0
                      ? null
                      : () async {
                          if (!await CrossfadeService.tryNow()) {
                            GlobalSnackbar.message((context) => context.l10n.crossfadeTryNowUnavailable);
                          }
                        },
                  icon: const Icon(TablerIcons.player_track_next),
                  label: Text(context.l10n.crossfadeTryNow),
                ),
                const SizedBox(height: 8),
                Text(context.l10n.crossfadeDjTransitionsNote, style: textTheme.bodySmall),
              ],
            ),
    );
  }
}
