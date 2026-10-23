import 'dart:async';

import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/services/ai_service.dart';
import 'package:finamp/services/dj_recordings.dart';
import 'package:finamp/services/dj_voice_service.dart';
import 'package:finamp/services/dj_voice_studio.dart';
import 'package:flutter/material.dart';

/// Per-character routing and fair, same-text auditions. No API request occurs
/// until the listener presses a provider's audition button.
class DjVoiceStudioControls extends StatefulWidget {
  const DjVoiceStudioControls({super.key, required this.profile, required this.characterName});
  final DjVoiceProfile profile;
  final String Function(DjVoiceCharacter) characterName;
  @override
  State<DjVoiceStudioControls> createState() => _DjVoiceStudioControlsState();
}

class _DjVoiceStudioControlsState extends State<DjVoiceStudioControls> {
  DjVoiceStudioSettings? _studio;
  AiSpeechSettings? _defaults;
  final _sample = TextEditingController();
  final _auditions = <String, DjAudioClip>{};
  bool _saving = false, _playing = false;
  int _revision = 0;
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_sample.text.isEmpty) {
      _sample.text = context.l10n.djVoiceSample;
    }
  }

  Future<void> _load() async {
    final studio = await DjVoiceStudioSettings.load(), defaults = await AiService.getSpeechSettings();
    if (mounted) {
      setState(() {
        _studio = studio;
        _defaults = defaults;
      });
    }
  }

  @override
  void dispose() {
    _revision++;
    _sample.dispose();
    for (final clip in _auditions.values) {
      unawaited(DjReplayStore.discard(clip.file));
    }
    super.dispose();
  }

  Future<void> _save(DjVoiceStudioSettings studio) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await DjVoiceService.saveStudioSettings(studio);
      if (mounted) setState(() => _studio = studio);
    } catch (error) {
      GlobalSnackbar.error(error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  DjVoiceCharacter get _character => widget.profile.settings.character;
  Future<void> _select(AiProvider? provider) async {
    final character = _character, studio = _studio!;
    final defaults = await AiService.getSpeechSettings();
    if (!mounted || _saving || _playing) return;
    final existing = studio.routes[character];
    final backup = provider != null && existing != null
        ? existing.apply(defaults).selectPrimary(provider).fallbacks.firstOrNull
        : defaults.order.where((v) => v != provider).firstOrNull;
    await _save(
      studio.withRoute(
        character,
        provider == null ? null : DjVoiceRoute(provider, backup: backup == provider ? null : backup),
      ),
    );
  }

  Future<void> _audition(AiProvider provider) async {
    final text = _sample.text.trim();
    if (text.isEmpty || _playing || _saving) return;
    final character = _character.at(DateTime.now()), settings = widget.profile.settings;
    final profile = widget.profile.copyWith(
      rotate: false,
      settings: (
        mode: settings.mode,
        every: settings.every,
        character: character,
        aiVoice: true,
        volume: settings.volume,
      ),
    );
    final revision = ++_revision;
    bool wanted() => mounted && revision == _revision;
    setState(() => _playing = true);
    try {
      final speech = await AiService.getSpeechSettings();
      final studio = await DjVoiceStudioSettings.load();
      final key =
          '${provider.name}:${character.name}:${speech.boost}:${AiService.speechRevision}:${studio.toJson()}:$text';
      var clip = _auditions[key];
      if (clip == null) {
        final file = await DjVoiceService.record(
          text,
          profile: profile,
          character: character,
          provider: provider,
          stillWanted: wanted,
          throwOnError: true,
        );
        if (file == null) return;
        if (!wanted()) {
          await DjReplayStore.discard(file);
          return;
        }
        clip = DjAudioClip(file, text);
        // A small bounded cache makes repeat comparisons free of new API calls.
        if (_auditions.length >= 4) {
          final old = _auditions.remove(_auditions.keys.first)!;
          await DjReplayStore.discard(old.file);
        }
        _auditions[key] = clip;
      }
      if (wanted()) await DjVoiceService.previewRecording(clip, profile: profile);
    } catch (error) {
      if (mounted) GlobalSnackbar.error(error);
    } finally {
      if (mounted) setState(() => _playing = false);
    }
  }

  Future<void> _editPronunciation([DjPronunciation? original]) async {
    final name = TextEditingController(text: original?.name), spoken = TextEditingController(text: original?.spoken);
    final form = GlobalKey<FormState>();
    final result = await showDialog<DjPronunciation>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.djPronunciation),
        content: SingleChildScrollView(
          child: Form(
            key: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: name,
                  maxLength: 80,
                  decoration: InputDecoration(labelText: context.l10n.djOriginalName),
                  validator: (value) => value == null || value.trim().isEmpty ? context.l10n.djTextRequired : null,
                ),
                TextFormField(
                  controller: spoken,
                  maxLength: 120,
                  decoration: InputDecoration(labelText: context.l10n.djSayAs),
                  validator: (value) => value == null || value.trim().isEmpty ? context.l10n.djTextRequired : null,
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(context.l10n.genericCancel)),
          TextButton(
            onPressed: () {
              if (form.currentState!.validate()) {
                Navigator.pop(context, DjPronunciation(name.text.trim(), spoken.text.trim()));
              }
            },
            child: Text(context.l10n.save),
          ),
        ],
      ),
    );
    // Dialog fields may still be mounted during their dismissal animation.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    name.dispose();
    spoken.dispose();
    if (result == null || !mounted) return;
    final values =
        _studio!.pronunciations
            .where((v) => v != original && v.name.toLowerCase() != result.name.toLowerCase())
            .toList()
          ..add(result);
    await _save(_studio!.withPronunciations(values));
  }

  @override
  Widget build(BuildContext context) {
    final studio = _studio, defaults = _defaults;
    if (studio == null || defaults == null) return const LinearProgressIndicator();
    final route = studio.routes[_character], busy = _saving || _playing;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          context.l10n.djCharacterApi(widget.characterName(_character)),
          style: Theme.of(context).textTheme.titleMedium,
        ),
        Text(context.l10n.djCharacterApiHelp),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          key: ValueKey('djRoute-${_character.name}-${route?.primary.name}'),
          initialValue: route?.primary.name ?? 'default',
          isExpanded: true,
          decoration: InputDecoration(labelText: context.l10n.djPreferredApi),
          items: [
            DropdownMenuItem(value: 'default', child: Text(context.l10n.djUseDefaultApi)),
            for (final provider in AiSpeechSettings.supported)
              DropdownMenuItem(value: provider.name, child: Text(provider.displayName)),
          ],
          onChanged: busy
              ? null
              : (value) => _select(AiSpeechSettings.supported.where((v) => v.name == value).firstOrNull),
        ),
        if (route != null) ...[
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            key: ValueKey('djBackup-${_character.name}-${route.backup?.name}'),
            initialValue: route.backup?.name ?? 'none',
            isExpanded: true,
            decoration: InputDecoration(labelText: context.l10n.djBackupApi),
            items: [
              DropdownMenuItem(value: 'none', child: Text(context.l10n.djNoBackup)),
              for (final provider in AiSpeechSettings.supported.where((v) => v != route.primary))
                DropdownMenuItem(value: provider.name, child: Text(provider.displayName)),
            ],
            onChanged: busy
                ? null
                : (value) => _save(
                    studio.withRoute(
                      _character,
                      DjVoiceRoute(
                        route.primary,
                        backup: AiSpeechSettings.supported.where((v) => v.name == value).firstOrNull,
                      ),
                    ),
                  ),
          ),
        ],
        const Divider(height: 32),
        Text(context.l10n.djCompareVoices, style: Theme.of(context).textTheme.titleMedium),
        Text(context.l10n.djCompareHelp),
        TextField(
          // Do not share the enclosing ExpansionTile's saved boolean state
          // with this field's scroll position when it is rebuilt.
          key: const PageStorageKey('djComparisonText'),
          controller: _sample,
          maxLength: 240,
          minLines: 2,
          maxLines: 4,
          enabled: !busy,
          decoration: InputDecoration(labelText: context.l10n.djComparisonText),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final provider in AiSpeechSettings.supported)
              OutlinedButton.icon(
                key: ValueKey('djAudition-${provider.name}'),
                onPressed: busy ? null : () => _audition(provider),
                icon: const Icon(Icons.play_arrow),
                label: Text(context.l10n.djHearProvider(provider.displayName)),
              ),
          ],
        ),
        const Divider(height: 32),
        Text(context.l10n.djPronunciation, style: Theme.of(context).textTheme.titleMedium),
        Text(context.l10n.djPronunciationHelp),
        for (final entry in studio.pronunciations)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(entry.name),
            subtitle: Text(entry.spoken),
            onTap: busy ? null : () => _editPronunciation(entry),
            trailing: IconButton(
              tooltip: context.l10n.featureRemove,
              icon: const Icon(Icons.delete_outline),
              onPressed: busy
                  ? null
                  : () => _save(studio.withPronunciations(studio.pronunciations.where((v) => v != entry).toList())),
            ),
          ),
        TextButton.icon(
          key: const ValueKey('djAddPronunciation'),
          onPressed: busy || studio.pronunciations.length >= 100 ? null : _editPronunciation,
          icon: const Icon(Icons.add),
          label: Text(context.l10n.djAddPronunciation),
        ),
        if (busy) const LinearProgressIndicator(),
      ],
    );
  }
}
