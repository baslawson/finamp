import 'dart:io';

import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/services/dj_audio_import.dart';
import 'package:finamp/services/dj_news_sting.dart';
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
  late final _jingle2 = TextEditingController(text: widget.profile.show.jingle2Text);

  /// The sounds that come with the app, to use as a jingle.
  List<DjSound> _sounds = const [];

  @override
  void initState() {
    super.initState();
    DjSounds.all().then((sounds) {
      if (mounted) setState(() => _sounds = sounds);
    });
  }

  bool _busy = false;

  /// The sound just chosen for a jingle (keyed by whether it's the secondary one), shown while it's kept.
  final Map<bool, String> _choosing = {};
  double? _duoDrag, _jingleDrag, _jingle2Drag, _talkDrag, _underDrag;
  @override
  void dispose() {
    _name.dispose();
    _intro.dispose();
    _jingle.dispose();
    _jingle2.dispose();
    super.dispose();
  }

  Future<void> _save(DjShowSettings show) => widget.onChanged(widget.profile.copyWith(show: show));
  DjShowSettings _edited() => widget.profile.show.copyWith(
    stationName: _name.text.trim(),
    intro: _intro.text.trim(),
    jingleText: _jingle.text.trim(),
    jingle2Text: _jingle2.text.trim(),
  );

  /// Keeps a new jingle, the primary one or the [second]ary: recorded with the DJ's voice, [import]ed by the listener,
  /// or one of the app's news [sound]s.
  Future<void> _storeJingle({required bool second, bool import = false, String? sound}) async {
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
      if (sound != null) {
        bytes = await DjSounds.recording(sound) ?? (throw FormatException(formatMessage));
      } else if (import) {
        final picked = await DjAudioImport.pick(formatMessage);
        if (picked == null) return;
        bytes = picked;
      } else {
        final words = second ? show.jingle2Text : show.jingleText;
        if (words.isEmpty) throw FormatException(requiredMessage);
        recording = await DjVoiceService.record(
          words,
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
      await _save(
        second
            ? show.copyWith(jingle2Id: id, jingle2Sound: sound ?? '')
            : show.copyWith(jingleId: id, jingleSound: sound ?? ''),
      );
      await DjVoiceService.discardUnusedJingle(second ? profile.show.jingle2Id : profile.show.jingleId, scope: scope);
      await DjVoiceService.discardUnusedJingle(id, scope: scope);
    } catch (error) {
      if (mounted) GlobalSnackbar.error(error);
    } finally {
      if (recording != null) await DjReplayStore.discard(recording);
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _removeJingle({required bool second}) async {
    final show = widget.profile.show, scope = RadioPreferencesStore.scope;
    final id = second ? show.jingle2Id : show.jingleId;
    setState(() => _busy = true);
    try {
      if (!second && show.jingle2Id.isNotEmpty) {
        // The secondary one becomes the primary, with its words.
        _jingle.text = _jingle2.text;
        _jingle2.clear();
        await _save(
          _edited().copyWith(jingleId: show.jingle2Id, jingleSound: show.jingle2Sound, jingle2Id: '', jingle2Sound: ''),
        );
      } else {
        await _save(
          second
              ? _edited().copyWith(jingle2Id: '', jingle2Sound: '')
              : _edited().copyWith(jingleId: '', jingleSound: ''),
        );
      }
      await DjVoiceService.discardUnusedJingle(id, scope: scope);
    } catch (error) {
      if (mounted) GlobalSnackbar.error(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _previewJingle({required bool second}) async {
    final scope = RadioPreferencesStore.scope, profile = widget.profile;
    final id = second ? profile.show.jingle2Id : profile.show.jingleId;
    final text = second ? profile.show.jingle2Text : profile.show.jingleText;
    setState(() => _busy = true);
    File? copy;
    final missingMessage = context.l10n.djJingleMissing;
    try {
      final bytes = await DjJingleStore.read(id, scope: scope);
      if (bytes == null) throw FormatException(missingMessage);
      if (!mounted || scope != RadioPreferencesStore.scope) return;
      final temp = await Directory.systemTemp.createTemp('finamp-jingle-preview-');
      copy = await File('${temp.path}/jingle.wav').writeAsBytes(bytes);
      await DjVoiceService.previewRecording(DjAudioClip(copy, text), profile: profile);
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

  Future<void> _choose({required bool second, required String choice}) async {
    setState(() => _choosing[second] = choice);
    try {
      await (choice == _none ? _removeJingle(second: second) : _storeJingle(second: second, sound: choice));
    } finally {
      if (mounted) setState(() => _choosing.remove(second));
    }
  }

  /// The dropdown's choices for no jingle, and for one recorded or imported.
  static const _none = '', _own = ' own';

  /// The primary jingle's choice of sound, words and buttons, or the [second]ary one's.
  List<Widget> _jingleSlot({required bool second}) {
    final l10n = context.l10n, show = widget.profile.show;
    final kept = (second ? show.jingle2Id : show.jingleId).isNotEmpty;
    final sound = second ? show.jingle2Sound : show.jingleSound;
    final saved = !kept
        ? _none
        : _sounds.any((s) => s.id == sound)
        ? sound
        : _own;
    final chosen = _choosing[second] ?? saved;
    return [
      Row(
        children: [
          Expanded(
            // A dropdown, not a menu: a menu's list would read the settings card's saved open or closed state as its
            // scroll position.
            child: DropdownButtonFormField<String>(
              key: ValueKey((second, chosen)),
              initialValue: chosen,
              isExpanded: true,
              decoration: InputDecoration(labelText: second ? l10n.djJingleSecondary : l10n.djJinglePrimary),
              items: [
                DropdownMenuItem(value: _none, child: Text(l10n.djJingleNone)),
                for (final s in _sounds) DropdownMenuItem(value: s.id, child: Text(s.name)),
                if (saved == _own) DropdownMenuItem(value: _own, child: Text(l10n.djNewsChimeOwn)),
              ],
              onChanged: _busy
                  ? null
                  : (choice) {
                      if (choice == null || choice == chosen || choice == _own) return;
                      _choose(second: second, choice: choice);
                    },
            ),
          ),
          IconButton(
            tooltip: l10n.djPreviewJingle,
            onPressed: _busy || !kept ? null : () => _previewJingle(second: second),
            icon: const Icon(Icons.play_arrow),
          ),
        ],
      ),
      TextField(
        key: PageStorageKey(second ? 'djJingle2Words' : 'djJingleWords'),
        controller: second ? _jingle2 : _jingle,
        enabled: !_busy,
        maxLength: 100,
        maxLines: 2,
        decoration: InputDecoration(labelText: l10n.djJingleWords),
      ),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          OutlinedButton.icon(
            onPressed: _busy ? null : () => _storeJingle(second: second),
            icon: const Icon(Icons.record_voice_over),
            label: Text(l10n.djRecordJingle),
          ),
          OutlinedButton.icon(
            onPressed: _busy ? null : () => _storeJingle(second: second, import: true),
            icon: const Icon(Icons.file_open_outlined),
            label: Text(l10n.djImportJingle),
          ),
        ],
      ),
    ];
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
          const SizedBox(height: 8),
          ..._jingleSlot(second: false),
          if (show.jingleId.isNotEmpty) ...[const SizedBox(height: 8), ..._jingleSlot(second: true)],
          if (show.jingleId.isNotEmpty && show.jingle2Id.isNotEmpty) ...[
            Text(context.l10n.djSecondaryChance((_jingle2Drag ?? show.jingle2Chance.toDouble()).round())),
            Slider(
              key: const ValueKey('djJingle2Chance'),
              min: 0,
              max: 100,
              divisions: 20,
              value: _jingle2Drag ?? show.jingle2Chance.toDouble(),
              onChanged: _busy ? null : (value) => setState(() => _jingle2Drag = value),
              onChangeEnd: (value) {
                setState(() => _jingle2Drag = null);
                _save(_edited().copyWith(jingle2Chance: value.round()));
              },
            ),
          ],
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
            Text(context.l10n.djTalkOverJingle((_talkDrag ?? show.talkOver.toDouble()).round())),
            Slider(
              key: const ValueKey('djTalkOver'),
              min: 0,
              max: 100,
              divisions: 20,
              value: _talkDrag ?? show.talkOver.toDouble(),
              onChanged: _busy ? null : (value) => setState(() => _talkDrag = value),
              onChangeEnd: (value) {
                setState(() => _talkDrag = null);
                _save(_edited().copyWith(talkOver: value.round()));
              },
            ),
            if (show.talkOver > 0) ...[
              Text(context.l10n.djUnderVoiceJingle((_underDrag ?? show.underVoice.toDouble()).round())),
              Slider(
                key: const ValueKey('djUnderVoice'),
                min: 5,
                max: 50,
                divisions: 9,
                value: _underDrag ?? show.underVoice.toDouble(),
                onChanged: _busy ? null : (value) => setState(() => _underDrag = value),
                onChangeEnd: (value) {
                  setState(() => _underDrag = null);
                  _save(_edited().copyWith(underVoice: value.round()));
                },
              ),
            ],
            Text(context.l10n.djTalkOverJingleHelp, style: Theme.of(context).textTheme.bodySmall),
          ],
        ],
        if (_busy) const LinearProgressIndicator(),
      ],
    );
  }
}
