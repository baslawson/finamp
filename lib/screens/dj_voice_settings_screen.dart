import 'dart:async';

import 'package:finamp/components/ai_usage_panel.dart';
import 'package:finamp/components/ai_voice_provider_controls.dart';
import 'package:finamp/components/dj_context_controls.dart';
import 'package:finamp/components/dj_news_controls.dart';
import 'package:finamp/components/dj_voice_controls.dart';
import 'package:finamp/components/dj_voice_session_controls.dart';
import 'package:finamp/components/dj_voice_studio_controls.dart';
import 'package:finamp/components/dj_show_controls.dart';
import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/services/ai_service.dart';
import 'package:finamp/services/dj_intro_timing.dart';
import 'package:finamp/services/dj_station_ids.dart';
import 'package:finamp/services/dj_voice_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

/// Sets when the DJ talks and how it sounds.
class DjVoiceSettingsScreen extends StatefulWidget {
  const DjVoiceSettingsScreen({super.key, this.stationId, this.stationName});
  final String? stationId, stationName;

  static const routeName = "/settings/djvoice";

  @override
  State<DjVoiceSettingsScreen> createState() => _DjVoiceSettingsScreenState();
}

class _DjVoiceSettingsScreenState extends State<DjVoiceSettingsScreen> {
  DjVoiceProfile? _profile;
  bool _hasOverride = false;
  bool _aiConfigured = true;
  bool _hitThePost = true;
  bool _stationIds = true;
  bool _previewing = false;
  Future<void> _pendingSave = Future.value();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final profile = await DjVoiceService.loadProfile(stationId: widget.stationId);
    final hasOverride = widget.stationId != null && await DjVoiceService.hasStationProfile(widget.stationId!);
    final configured = await AiService.isConfigured();
    final hitThePost = await DjIntroTiming.isEnabled();
    final stationIds = await DjStationIds.isEnabled();
    if (!mounted) return;
    setState(() {
      _profile = profile;
      _hasOverride = hasOverride;
      _aiConfigured = configured;
      _hitThePost = hitThePost;
      _stationIds = stationIds;
    });
  }

  Future<void> _save(DjVoiceSettings settings) => _saveProfile(_profile!.copyWith(settings: settings));

  Future<void> _saveProfile(DjVoiceProfile profile) async {
    setState(() {
      _profile = profile;
      if (widget.stationId != null) _hasOverride = true;
    });
    final save = _pendingSave
        .catchError((Object _) {})
        .then((_) => DjVoiceService.saveProfile(profile, stationId: widget.stationId));
    _pendingSave = save;
    try {
      await save;
    } catch (error) {
      GlobalSnackbar.error(error);
    }
  }

  Future<void> _useStation(bool use) async {
    if (use) {
      final settings = _profile!.settings;
      await _saveProfile(
        _profile!.copyWith(
          settings: (
            mode: DjVoiceMode.always,
            every: settings.every,
            character: settings.character,
            aiVoice: settings.aiVoice,
            volume: settings.volume,
          ),
        ),
      );
    } else {
      try {
        await _pendingSave.catchError((Object _) {});
        await DjVoiceService.clearStationProfile(widget.stationId!);
        await _load();
      } catch (error) {
        GlobalSnackbar.error(error);
      }
    }
  }

  Future<void> _preview() async {
    final sample = context.l10n.djVoiceSample;
    setState(() => _previewing = true);
    try {
      await _pendingSave;
      if (!mounted) return;
      await DjVoiceService.preview(sample, profile: _profile);
    } catch (e) {
      GlobalSnackbar.error(e);
    } finally {
      if (mounted) setState(() => _previewing = false);
    }
  }

  String _characterName(DjVoiceCharacter character) => switch (character) {
    DjVoiceCharacter.energetic => context.l10n.djVoiceEnergetic,
    DjVoiceCharacter.chill => context.l10n.djVoiceChill,
    DjVoiceCharacter.deep => context.l10n.djVoiceDeep,
    DjVoiceCharacter.bright => context.l10n.djVoiceBright,
    DjVoiceCharacter.aussieMale => context.l10n.djVoiceAussieMale,
    DjVoiceCharacter.aussieFemale => context.l10n.djVoiceAussieFemale,
    DjVoiceCharacter.actionHero => context.l10n.djVoiceActionHero,
    DjVoiceCharacter.tycoon => context.l10n.djVoiceTycoon,
    DjVoiceCharacter.pirate => context.l10n.djVoicePirate,
    DjVoiceCharacter.trailer => context.l10n.djVoiceTrailer,
    DjVoiceCharacter.documentary => context.l10n.djVoiceDocumentary,
    DjVoiceCharacter.sports => context.l10n.djVoiceSports,
    DjVoiceCharacter.herald => context.l10n.djVoiceHerald,
    DjVoiceCharacter.robot => context.l10n.djVoiceRobot,
    DjVoiceCharacter.lateNight => context.l10n.djVoiceLateNight,
    DjVoiceCharacter.morningShow => context.l10n.djVoiceMorningShow,
    DjVoiceCharacter.oldTimeRadio => context.l10n.djVoiceOldTimeRadio,
    DjVoiceCharacter.clubMc => context.l10n.djVoiceClubMc,
    DjVoiceCharacter.meditation => context.l10n.djVoiceMeditation,
    DjVoiceCharacter.librarian => context.l10n.djVoiceLibrarian,
    DjVoiceCharacter.british => context.l10n.djVoiceBritish,
    DjVoiceCharacter.irish => context.l10n.djVoiceIrish,
    DjVoiceCharacter.scottish => context.l10n.djVoiceScottish,
    DjVoiceCharacter.southern => context.l10n.djVoiceSouthern,
    DjVoiceCharacter.dutch => context.l10n.djVoiceDutch,
    DjVoiceCharacter.byTimeOfDay => context.l10n.djVoiceByTimeOfDay,
  };

  Widget _section({
    required String id,
    required IconData icon,
    required String title,
    required String subtitle,
    required List<Widget> children,
  }) => Card(
    key: ValueKey(id),
    margin: const EdgeInsets.only(bottom: 12),
    clipBehavior: Clip.antiAlias,
    child: ExpansionTile(
      key: PageStorageKey(id),
      maintainState: true,
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
      childrenPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      children: [Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children)],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final profile = _profile;
    final settings = profile?.settings;
    final rotationFavourites = profile?.rotationFavourites ?? const <DjVoiceCharacter>{};
    final rotates = profile != null && profile.rotate && profile.settings.aiVoice && rotationFavourites.length >= 2;
    final singleCharacter = profile?.singleCharacter;
    final textTheme = Theme.of(context).textTheme;
    DjVoiceSettings copy({DjVoiceMode? mode, int? every, DjVoiceCharacter? character, bool? aiVoice, double? volume}) =>
        (
          mode: mode ?? settings!.mode,
          every: every ?? settings!.every,
          character: character ?? settings!.character,
          aiVoice: aiVoice ?? settings!.aiVoice,
          volume: volume ?? settings!.volume,
        );

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.stationId == null ? context.l10n.djVoice : context.l10n.djStationTitle(widget.stationName ?? ''),
        ),
      ),
      body: settings == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  margin: const EdgeInsets.only(bottom: 16),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(context.l10n.djSettingsSession, style: textTheme.titleMedium),
                        const DjVoiceSessionControls(),
                      ],
                    ),
                  ),
                ),
                if (widget.stationId != null)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(context.l10n.djUseStationSettings),
                    subtitle: Text(context.l10n.djStationSettingsHelp),
                    value: _hasOverride,
                    onChanged: _useStation,
                  ),
                if (widget.stationId == null || _hasOverride) ...[
                  _section(
                    id: 'djSettingsTiming',
                    icon: Icons.schedule,
                    title: context.l10n.djSettingsTiming,
                    subtitle: context.l10n.djSettingsTimingHelp,
                    children: [
                      Text(context.l10n.djVoiceDescription),
                      if (!_aiConfigured)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(context.l10n.djVoiceNoAiKey, style: textTheme.bodySmall),
                        ),
                      const SizedBox(height: 16),
                      DjVoiceProfileControls(
                        profile: profile!,
                        onChanged: _saveProfile,
                        station: widget.stationId != null,
                        showLevels: false,
                        showPresets: false,
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(context.l10n.djHitThePost),
                        subtitle: Text(context.l10n.djHitThePostHelp),
                        value: _hitThePost,
                        onChanged: (value) {
                          setState(() => _hitThePost = value);
                          unawaited(DjIntroTiming.setEnabled(value));
                        },
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(context.l10n.djStationIds),
                        subtitle: Text(context.l10n.djStationIdsHelp),
                        value: _stationIds,
                        onChanged: (value) {
                          setState(() => _stationIds = value);
                          unawaited(DjStationIds.setEnabled(value));
                        },
                      ),
                      const DjContextControls(),
                      const DjNewsControls(),
                    ],
                  ),
                  _section(
                    id: 'djSettingsVoice',
                    icon: Icons.record_voice_over,
                    title: context.l10n.djSettingsVoice,
                    subtitle: context.l10n.djSettingsVoiceHelp,
                    children: [
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(context.l10n.djVoiceAiVoice),
                        subtitle: Text(context.l10n.djVoiceAiVoiceHelp),
                        value: settings.aiVoice,
                        onChanged: (aiVoice) => _save(copy(aiVoice: aiVoice)),
                      ),
                      if (settings.aiVoice) ...[
                        Text(context.l10n.djVoiceCharacter, style: textTheme.titleMedium),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          children: [
                            for (final character in DjVoiceCharacter.values)
                              ChoiceChip(
                                label: Text(_characterName(character)),
                                selected: !rotates && singleCharacter == character,
                                onSelected: (_) =>
                                    _saveProfile(profile.copyWith(settings: copy(character: character), rotate: false)),
                              ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 16),
                      OutlinedButton.icon(
                        onPressed: _previewing ? null : _preview,
                        icon: _previewing
                            ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(TablerIcons.microphone_2),
                        label: Text(context.l10n.djVoiceTry),
                      ),
                    ],
                  ),
                  _section(
                    id: 'djSettingsApi',
                    icon: Icons.cloud_outlined,
                    title: context.l10n.djVoiceApi,
                    subtitle: context.l10n.djSettingsApiHelp,
                    children: [const AiVoiceProviderControls(showHeading: false)],
                  ),
                  _section(
                    id: 'djSettingsUsage',
                    icon: Icons.query_stats_outlined,
                    title: context.l10n.aiUsage,
                    subtitle: context.l10n.aiUsageHelp,
                    children: const [AiUsagePanel()],
                  ),
                  _section(
                    id: 'djSettingsLevels',
                    icon: Icons.volume_up_outlined,
                    title: context.l10n.djSettingsLevels,
                    subtitle: context.l10n.djSettingsLevelsHelp,
                    children: [
                      DjVoiceProfileControls(
                        profile: profile,
                        onChanged: _saveProfile,
                        station: widget.stationId != null,
                        showTiming: false,
                        showPresets: false,
                      ),
                    ],
                  ),
                  _section(
                    id: 'djSettingsStudio',
                    icon: Icons.compare_arrows,
                    title: context.l10n.djVoiceStudio,
                    subtitle: context.l10n.djVoiceStudioHelp,
                    children: [DjVoiceStudioControls(profile: profile, characterName: _characterName)],
                  ),
                  _section(
                    id: 'djSettingsShow',
                    icon: Icons.radio,
                    title: context.l10n.djShowSettings,
                    subtitle: context.l10n.djShowSettingsHelp,
                    children: [
                      DjShowControls(profile: profile, onChanged: _saveProfile, characterName: _characterName),
                    ],
                  ),
                  if (settings.aiVoice)
                    _section(
                      id: 'djSettingsFavorites',
                      icon: Icons.favorite_outline,
                      title: context.l10n.djFavouriteVoices,
                      subtitle: context.l10n.djSettingsFavouritesHelp,
                      children: [
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(context.l10n.djRotateFavourites),
                          subtitle: Text(
                            profile.show.duoChance > 0 ? context.l10n.djRotateCoHostHelp : context.l10n.djRotateHelp,
                          ),
                          value: rotates,
                          onChanged: rotationFavourites.length < 2
                              ? null
                              : (rotate) => _saveProfile(profile.copyWith(rotate: rotate)),
                        ),
                        Wrap(
                          spacing: 8,
                          children: [
                            for (final character in DjVoiceCharacter.values.where(
                              (value) => value != DjVoiceCharacter.byTimeOfDay,
                            ))
                              FilterChip(
                                key: ValueKey('djFavourite-${character.name}'),
                                label: Text(
                                  profile.isCoHost(character)
                                      ? context.l10n.djFavouriteCoHost(_characterName(character))
                                      : _characterName(character),
                                ),
                                selected: rotationFavourites.contains(character),
                                onSelected: profile.isCoHost(character)
                                    ? null
                                    : (selected) {
                                        final voices = {...profile.favourites};
                                        selected ? voices.add(character) : voices.remove(character);
                                        _saveProfile(
                                          profile.copyWith(
                                            favourites: voices.toList(),
                                            rotate: voices.length >= 2 && profile.rotate,
                                          ),
                                        );
                                      },
                              ),
                          ],
                        ),
                      ],
                    ),
                  _section(
                    id: 'djSettingsPresets',
                    icon: Icons.tune,
                    title: context.l10n.djListeningPresets,
                    subtitle: context.l10n.djSettingsPresetsHelp,
                    children: [DjListeningPresetsControls(profile: profile, onChanged: _saveProfile)],
                  ),
                ],
              ],
            ),
    );
  }
}
