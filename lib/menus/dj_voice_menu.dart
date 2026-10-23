import 'package:finamp/components/ai_voice_provider_controls.dart';
import 'package:finamp/components/dj_voice_controls.dart';
import 'package:finamp/components/dj_voice_session_controls.dart';
import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/screens/dj_voice_settings_screen.dart';
import 'package:finamp/services/dj_voice_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

Future<void> showDjVoiceMenu(BuildContext context) async {
  final stationId = DjVoiceService.currentStationId;
  final stationName = DjVoiceService.currentStationName;
  final openSettings = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (_) => _DjVoiceMenu(stationId: stationId, stationName: stationName),
  );
  if ((openSettings ?? false) && context.mounted) {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: DjVoiceSettingsScreen.routeName),
        builder: (_) => DjVoiceSettingsScreen(stationId: stationId, stationName: stationName),
      ),
    );
  }
}

class _DjVoiceMenu extends StatefulWidget {
  const _DjVoiceMenu({this.stationId, this.stationName});
  final String? stationId, stationName;

  @override
  State<_DjVoiceMenu> createState() => _DjVoiceMenuState();
}

class _DjVoiceMenuState extends State<_DjVoiceMenu> {
  DjVoiceProfile? _profile;
  bool _hasOverride = false;
  Object? _loadError;
  Future<void> _pendingSave = Future.value();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final profile = await DjVoiceService.loadProfile(stationId: widget.stationId);
      final hasOverride = widget.stationId != null && await DjVoiceService.hasStationProfile(widget.stationId!);
      if (mounted) {
        setState(() {
          _profile = profile;
          _hasOverride = hasOverride;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _loadError = error);
    }
  }

  Future<void> _save(DjVoiceProfile profile) async {
    setState(() => _profile = profile);
    final save = _pendingSave.then((_) => DjVoiceService.saveProfile(profile, stationId: widget.stationId));
    _pendingSave = save.catchError((Object error) => GlobalSnackbar.error(error));
    await _pendingSave;
  }

  Future<void> _useStation(bool use) async {
    try {
      await _pendingSave;
      if (use) {
        final settings = _profile!.settings;
        await DjVoiceService.saveProfile(
          _profile!.copyWith(
            settings: (
              mode: DjVoiceMode.always,
              every: settings.every,
              character: settings.character,
              aiVoice: settings.aiVoice,
              volume: settings.volume,
            ),
          ),
          stationId: widget.stationId,
        );
      } else {
        await DjVoiceService.clearStationProfile(widget.stationId!);
      }
      await _load();
    } catch (error) {
      GlobalSnackbar.error(error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final profile = _profile;
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.stationId == null ? context.l10n.djVoice : context.l10n.djStationTitle(widget.stationName ?? ''),
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 16),
            const DjVoiceSessionControls(),
            if (_loadError != null)
              Text('$_loadError')
            else if (profile == null)
              const Center(child: CircularProgressIndicator())
            else ...[
              if (widget.stationId != null)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(context.l10n.djUseStationSettings),
                  subtitle: Text(context.l10n.djStationSettingsHelp),
                  value: _hasOverride,
                  onChanged: _useStation,
                ),
              if (widget.stationId == null || _hasOverride)
                DjVoiceProfileControls(profile: profile, onChanged: _save, station: widget.stationId != null),
              if (profile.settings.aiVoice) const AiVoiceProviderControls(compact: true),
            ],
            const SizedBox(height: 8),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(TablerIcons.settings),
              title: Text(context.l10n.settings),
              trailing: const Icon(TablerIcons.chevron_right),
              onTap: () async {
                await _pendingSave;
                if (context.mounted) Navigator.of(context).pop(true);
              },
            ),
          ],
        ),
      ),
    );
  }
}
