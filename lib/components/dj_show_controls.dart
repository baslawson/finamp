import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/services/dj_recordings.dart';
import 'package:finamp/services/dj_show_audio.dart';
import 'package:finamp/services/dj_voice_service.dart';
import 'package:finamp/services/radio_preferences.dart';
import 'package:flutter/material.dart';

class DjShowControls extends StatefulWidget {
  const DjShowControls({super.key, required this.profile, required this.onChanged, required this.characterName});
  final DjVoiceProfile profile;
  final Future<void> Function(DjVoiceProfile) onChanged;
  final String Function(DjVoiceCharacter) characterName;
  @override
  State<DjShowControls> createState() => _DjShowControlsState();
}

class _DjShowControlsState extends State<DjShowControls> {
  late final _name = TextEditingController(text: widget.profile.show.stationName);
  late final _intro = TextEditingController(text: widget.profile.show.intro);
  late final _jingle = TextEditingController(text: widget.profile.show.jingleText);
  bool _busy = false;
  double? _duoDrag, _jingleDrag;
  @override
  void dispose() {
    _name.dispose();
    _intro.dispose();
    _jingle.dispose();
    super.dispose();
  }

  Future<void> _save(DjShowSettings show) => widget.onChanged(widget.profile.copyWith(show: show));
  DjShowSettings _edited() => widget.profile.show.copyWith(
    stationName: _name.text.trim(),
    intro: _intro.text.trim(),
    jingleText: _jingle.text.trim(),
  );

  Future<void> _storeJingle({required bool import}) async {
    if (_busy) return;
    final scope = RadioPreferencesStore.scope, profile = widget.profile;
    final show = _edited();
    final formatMessage = context.l10n.djJingleFormat;
    final requiredMessage = context.l10n.djTextRequired;
    File? recording;
    String? id;
    setState(() => _busy = true);
    try {
      List<int> bytes;
      if (import) {
        final result = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['wav']);
        if (result == null || result.files.isEmpty) return;
        final file = result.files.single;
        if (file.size > 2 * 1024 * 1024) throw FormatException(formatMessage);
        if (file.bytes != null) {
          bytes = file.bytes!;
        } else if (file.path != null) {
          final source = File(file.path!);
          if (await source.length() > 2 * 1024 * 1024) throw FormatException(formatMessage);
          bytes = await source.readAsBytes();
        } else {
          throw FormatException(formatMessage);
        }
      } else {
        if (show.jingleText.isEmpty) throw FormatException(requiredMessage);
        recording = await DjVoiceService.record(
          show.jingleText,
          profile: profile,
          throwOnError: true,
          stillWanted: () => mounted && scope == RadioPreferencesStore.scope,
        );
        if (recording == null) return;
        bytes = await recording.readAsBytes();
      }
      id = await DjJingleStore.save(bytes, scope: scope);
      if (!mounted || scope != RadioPreferencesStore.scope) {
        await DjJingleStore.remove(id, scope: scope);
        id = null;
        return;
      }
      await _save(show.copyWith(jingleId: id));
      await DjVoiceService.discardUnusedJingle(profile.show.jingleId, scope: scope);
      await DjVoiceService.discardUnusedJingle(id, scope: scope);
    } catch (error) {
      if (mounted) GlobalSnackbar.error(error);
    } finally {
      if (recording != null) await DjReplayStore.discard(recording);
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _removeJingle() async {
    final id = widget.profile.show.jingleId, scope = RadioPreferencesStore.scope;
    setState(() => _busy = true);
    try {
      await _save(_edited().copyWith(jingleId: ''));
      await DjVoiceService.discardUnusedJingle(id, scope: scope);
    } catch (error) {
      if (mounted) GlobalSnackbar.error(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _previewJingle() async {
    final scope = RadioPreferencesStore.scope, profile = widget.profile;
    setState(() => _busy = true);
    File? copy;
    final missingMessage = context.l10n.djJingleMissing;
    try {
      final bytes = await DjJingleStore.read(profile.show.jingleId, scope: scope);
      if (bytes == null) throw FormatException(missingMessage);
      if (!mounted || scope != RadioPreferencesStore.scope) return;
      final temp = await Directory.systemTemp.createTemp('finamp-jingle-preview-');
      copy = await File('${temp.path}/jingle.wav').writeAsBytes(bytes);
      await DjVoiceService.previewRecording(DjAudioClip(copy, profile.show.jingleText), profile: profile);
    } catch (error) {
      if (mounted) GlobalSnackbar.error(error);
    } finally {
      if (copy != null) {
        await DjReplayStore.discard(copy);
        await copy.parent.delete().catchError((_) => copy!.parent);
      }
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final show = widget.profile.show;
    final style = Theme.of(context).textTheme.titleMedium;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(context.l10n.djTwoHosts),
          subtitle: Text(context.l10n.djTwoHostsHelp),
          value: show.duoChance > 0,
          onChanged: _busy || !widget.profile.settings.aiVoice
              ? null
              : (value) => _save(show.copyWith(duoChance: value ? 25 : 0)),
        ),
        if (show.duoChance > 0) ...[
          DropdownButtonFormField<DjVoiceCharacter>(
            key: ValueKey('djCoHost-${show.coHost.name}'),
            initialValue: show.coHost,
            isExpanded: true,
            decoration: InputDecoration(labelText: context.l10n.djCoHost),
            items: [
              for (final character in DjVoiceCharacter.values.where((v) => v != DjVoiceCharacter.byTimeOfDay))
                DropdownMenuItem(value: character, child: Text(widget.characterName(character))),
            ],
            onChanged: _busy
                ? null
                : (value) {
                    if (value != null) _save(show.copyWith(coHost: value));
                  },
          ),
          Text(context.l10n.djAnnouncementChance((_duoDrag ?? show.duoChance.toDouble()).round())),
          Slider(
            key: const ValueKey('djDuoChance'),
            min: 5,
            max: 100,
            divisions: 19,
            value: _duoDrag ?? show.duoChance.toDouble().clamp(5, 100),
            onChanged: _busy ? null : (value) => setState(() => _duoDrag = value),
            onChangeEnd: (value) {
              setState(() => _duoDrag = null);
              _save(show.copyWith(duoChance: value.round()));
            },
          ),
        ],
        const Divider(height: 32),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(context.l10n.djStationIdentity),
          subtitle: Text(context.l10n.djStationIdentityHelp),
          value: show.identityEnabled,
          onChanged: _busy ? null : (value) => _save(_edited().copyWith(identityEnabled: value)),
        ),
        if (show.identityEnabled) ...[
          TextField(
            key: const PageStorageKey('djStationName'),
            controller: _name,
            enabled: !_busy,
            maxLength: 80,
            decoration: InputDecoration(labelText: context.l10n.djStationName),
          ),
          TextField(
            key: const PageStorageKey('djStationIntro'),
            controller: _intro,
            enabled: !_busy,
            maxLength: 180,
            minLines: 1,
            maxLines: 3,
            decoration: InputDecoration(
              labelText: context.l10n.djStationIntro,
              helperText: context.l10n.djStationIntroHelp,
              helperMaxLines: 3,
            ),
          ),
          FilledButton.tonal(
            onPressed: _busy ? null : () => _save(_edited()),
            child: Text(context.l10n.djSaveIdentity),
          ),
          const SizedBox(height: 16),
          Text(context.l10n.djStationJingle, style: style),
          Text(context.l10n.djJingleFormat),
          TextField(
            key: const PageStorageKey('djJingleWords'),
            controller: _jingle,
            enabled: !_busy,
            maxLength: 100,
            maxLines: 2,
            decoration: InputDecoration(labelText: context.l10n.djJingleWords),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: _busy ? null : () => _storeJingle(import: false),
                icon: const Icon(Icons.record_voice_over),
                label: Text(context.l10n.djRecordJingle),
              ),
              OutlinedButton.icon(
                onPressed: _busy ? null : () => _storeJingle(import: true),
                icon: const Icon(Icons.file_open_outlined),
                label: Text(context.l10n.djImportJingle),
              ),
              if (show.jingleId.isNotEmpty) ...[
                OutlinedButton.icon(
                  onPressed: _busy ? null : _previewJingle,
                  icon: const Icon(Icons.play_arrow),
                  label: Text(context.l10n.djPreviewJingle),
                ),
                TextButton(onPressed: _busy ? null : _removeJingle, child: Text(context.l10n.djRemoveJingle)),
              ],
            ],
          ),
          if (show.jingleId.isNotEmpty) ...[
            Text(context.l10n.djJingleChance((_jingleDrag ?? show.jingleChance.toDouble()).round())),
            Slider(
              key: const ValueKey('djJingleChance'),
              min: 0,
              max: 100,
              divisions: 20,
              value: _jingleDrag ?? show.jingleChance.toDouble(),
              onChanged: _busy ? null : (value) => setState(() => _jingleDrag = value),
              onChangeEnd: (value) {
                setState(() => _jingleDrag = null);
                _save(_edited().copyWith(jingleChance: value.round()));
              },
            ),
          ],
        ],
        if (_busy) const LinearProgressIndicator(),
      ],
    );
  }
}
