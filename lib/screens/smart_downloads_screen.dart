import 'package:finamp/components/AlbumScreen/download_dialog.dart';
import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:finamp/services/smart_downloads_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

/// Lets the user keep their most relevant music offline within a storage limit.
class SmartDownloadsScreen extends ConsumerStatefulWidget {
  const SmartDownloadsScreen({super.key});

  static const routeName = "/downloads/smart";

  @override
  ConsumerState<SmartDownloadsScreen> createState() => _SmartDownloadsScreenState();
}

class _SmartDownloadsScreenState extends ConsumerState<SmartDownloadsScreen> {
  static const _limits = [1, 2, 4, 8, 16, 32, 64, 128];

  SmartDownloadsSettings? _settings;
  bool _updating = false;
  String? _summary;

  @override
  void initState() {
    super.initState();
    SmartDownloadsService.loadSettings().then((settings) {
      if (mounted) setState(() => _settings = settings);
    });
  }

  void _change(SmartDownloadsSettings settings) {
    setState(() => _settings = settings);
    SmartDownloadsService.saveSettings(settings);
  }

  Future<void> _update() async {
    setState(() => _updating = true);
    try {
      final result = await SmartDownloadsService.update(_settings!);
      if (!mounted) return;
      setState(
        () => _summary = context.l10n.smartDownloadsSummary(
          result.tracks,
          (result.bytes / 1000 / 1000 / 1000).toStringAsFixed(1),
        ),
      );
      if (!result.alreadyDownloaded) {
        final stub = DownloadStub.fromItem(type: DownloadItemType.collection, item: result.playlist);
        await DownloadDialog.show(context, stub, null, trackCount: result.tracks);
      } else {
        GlobalSnackbar.message((context) => context.l10n.smartDownloadsSynced, isConfirmation: true);
      }
    } catch (e) {
      GlobalSnackbar.error(e);
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  String _sourceName(SmartDownloadSource source) => switch (source) {
    SmartDownloadSource.favorites => context.l10n.smartDownloadsFavorites,
    SmartDownloadSource.mostPlayed => context.l10n.smartDownloadsMostPlayed,
    SmartDownloadSource.recentlyPlayed => context.l10n.smartDownloadsRecentlyPlayed,
    SmartDownloadSource.recentlyAdded => context.l10n.smartDownloadsRecentlyAdded,
  };

  @override
  Widget build(BuildContext context) {
    final settings = _settings;
    final offline = ref.watch(finampSettingsProvider.isOffline);
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.smartDownloads)),
      body: settings == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                Text(context.l10n.smartDownloadsDescription(SmartDownloadsService.playlistName)),
                const SizedBox(height: 16),
                Text(context.l10n.smartDownloadsLimit, style: textTheme.titleMedium),
                Slider(
                  value: _limits.indexOf(settings.limitGigabytes).clamp(0, _limits.length - 1).toDouble(),
                  max: _limits.length - 1.0,
                  divisions: _limits.length - 1,
                  label: "${settings.limitGigabytes} GB",
                  onChanged: (value) =>
                      _change((limitGigabytes: _limits[value.round()], sources: settings.sources)),
                ),
                Center(child: Text("${settings.limitGigabytes} GB", style: textTheme.headlineSmall)),
                const SizedBox(height: 16),
                Text(context.l10n.smartDownloadsSources, style: textTheme.titleMedium),
                for (final source in SmartDownloadSource.values)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(_sourceName(source)),
                    value: settings.sources.contains(source),
                    onChanged: (enabled) => _change((
                      limitGigabytes: settings.limitGigabytes,
                      sources: enabled!
                          ? {...settings.sources, source}
                          : settings.sources.where((other) => other != source).toSet(),
                    )),
                  ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _updating || offline || settings.sources.isEmpty ? null : _update,
                  icon: _updating
                      ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(TablerIcons.refresh),
                  label: Text(context.l10n.smartDownloadsUpdate),
                ),
                if (_summary != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_summary!)),
                const SizedBox(height: 24),
              ],
            ),
    );
  }
}

/// Opens the smart downloads screen from the downloads screen's app bar.
class SmartDownloadsButton extends StatelessWidget {
  const SmartDownloadsButton({super.key});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: context.l10n.smartDownloads,
      icon: const Icon(TablerIcons.sparkles),
      onPressed: () => Navigator.of(context).pushNamed(SmartDownloadsScreen.routeName),
    );
  }
}
