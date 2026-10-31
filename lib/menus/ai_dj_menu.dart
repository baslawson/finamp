import 'package:finamp/components/menu_sheet.dart';
import 'package:finamp/components/fun_heading.dart';
import 'package:finamp/components/ai_voice_provider_controls.dart';
import 'package:finamp/components/harmonic_mixing_switch.dart';
import 'package:finamp/components/mix_length_chips.dart';
import 'package:finamp/components/mood_notes_dialog.dart';
import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/screens/dj_voice_settings_screen.dart';
import 'package:finamp/services/ai_dj_service.dart';
import 'package:finamp/services/radio_tuning.dart';
import 'package:finamp/services/ai_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

Future<void> showAiDjMenu({required BuildContext context}) {
  return showMenuSheet<void>(context: context, builder: (_) => const _AiDjMenu());
}

const _lengthKey = "aiDjMinutes";

class _AiDjMenu extends StatefulWidget {
  const _AiDjMenu();

  @override
  State<_AiDjMenu> createState() => _AiDjMenuState();
}

class _AiDjMenuState extends State<_AiDjMenu> {
  final _requestController = TextEditingController();
  int _minutes = 60;
  bool _creating = false;

  /// Null while loading, then whether the chosen provider has an API key.
  bool? _configured;
  AiTextSettings? _routing;
  bool _showSettings = false;

  @override
  void initState() {
    super.initState();
    _reloadConfiguration();
    SharedPreferencesAsync().getInt(_lengthKey).then((minutes) {
      if (minutes != null && mounted) setState(() => _minutes = minutes);
    });
  }

  void _setMinutes(int minutes) {
    setState(() => _minutes = minutes);
    SharedPreferencesAsync().setInt(_lengthKey, minutes).ignore();
  }

  @override
  void dispose() {
    _requestController.dispose();
    super.dispose();
  }

  Future<void> _reloadConfiguration() async {
    final routing = await AiService.getTextSettings();
    final configured = await AiService.isConfigured();
    if (mounted) {
      setState(() {
        _configured = configured;
        _routing = routing;
      });
    }
  }

  Future<void> _createMix() async {
    final request = _requestController.text.trim();
    if (request.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() => _creating = true);
    try {
      final name = await AiDjService.playMix(request, trackCount: (_minutes / averageTrackMinutes).round());
      GlobalSnackbar.message((context) => context.l10n.aiDjNowPlaying(name), isConfirmation: true);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      GlobalSnackbar.message((_) => e.toString());
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final suggestions = [
      context.l10n.aiDjSuggestionChill,
      context.l10n.aiDjSuggestionFocus,
      context.l10n.aiDjSuggestionWorkout,
      context.l10n.aiDjSuggestionParty,
      context.l10n.aiDjSuggestionRainy,
      context.l10n.aiDjSuggestionRoadTrip,
      context.l10n.aiDjSuggestionSad,
    ];

    return SafeArea(
      child: Padding(
        // Keep the text field above the keyboard.
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16.0, 0.0, 16.0, 16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 12.0,
            children: [
              Row(
                children: [
                  Expanded(child: GradientTitle(context.l10n.aiDjAction, icon: TablerIcons.headphones)),
                  IconButton(
                    tooltip: context.l10n.djVoice,
                    icon: const Icon(TablerIcons.microphone_2),
                    onPressed: () => Navigator.of(context).pushNamed(DjVoiceSettingsScreen.routeName),
                  ),
                  IconButton(
                    tooltip: context.l10n.aiSettings,
                    icon: Icon(_showSettings ? TablerIcons.x : TablerIcons.settings),
                    onPressed: () => setState(() => _showSettings = !_showSettings),
                  ),
                ],
              ),
              if (_configured == null)
                const LinearProgressIndicator()
              else if (_showSettings || !_configured!)
                _AiSettings(
                  onChanged: () {
                    _reloadConfiguration();
                    setState(() => _showSettings = false);
                  },
                )
              else ...[
                if (_routing != null) ...[
                  Text(context.l10n.aiRequestRoute(_routing!.primary.displayName)),
                  if (_routing!.fallbacks.isNotEmpty)
                    Text(context.l10n.aiRequestBackupRoute(_routing!.fallbacks.map((v) => v.displayName).join(', '))),
                ],
                TextField(
                  controller: _requestController,
                  minLines: 1,
                  maxLines: 3,
                  textInputAction: TextInputAction.go,
                  onSubmitted: (_) => _createMix(),
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    labelText: context.l10n.aiDjPrompt,
                    hintText: context.l10n.aiDjPromptHint,
                  ),
                ),
                Wrap(
                  spacing: 8.0,
                  runSpacing: 4.0,
                  children: [
                    for (final suggestion in suggestions)
                      ActionChip(
                        label: Text(suggestion),
                        onPressed: () => setState(() => _requestController.text = suggestion),
                      ),
                  ],
                ),
                MixLengthChips(minutes: _minutes, onChanged: (minutes) => _setMinutes(minutes!)),
                const HarmonicMixingSwitch(menu: HarmonicMixingMenu.aiDj),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _creating ? null : _createMix,
                    icon: _creating
                        ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(TablerIcons.sparkles),
                    label: Text(_creating ? context.l10n.aiDjCreating : context.l10n.aiDjCreate),
                  ),
                ),
                const MoodNotesButton(),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Choose the AI provider and enter its API key, which is only stored on this device.
class _AiSettings extends StatefulWidget {
  const _AiSettings({required this.onChanged});

  final VoidCallback onChanged;

  @override
  State<_AiSettings> createState() => _AiSettingsState();
}

class _AiSettingsState extends State<_AiSettings> {
  final _keyController = TextEditingController();
  AiTextSettings? _routing;
  AiProvider? get _provider => _routing?.primary;
  bool _hasKey = false;
  bool _loadingKey = false, _saving = false;
  int _keyLoadRevision = 0;

  @override
  void initState() {
    super.initState();
    AiService.getTextSettings().then((settings) {
      if (!mounted) return;
      _routing = settings;
      _selectProvider(settings.primary);
    });
  }

  @override
  void dispose() {
    _keyController.dispose();
    super.dispose();
  }

  Future<void> _selectProvider(AiProvider provider) async {
    final revision = ++_keyLoadRevision;
    setState(() {
      _routing = _routing!.selectPrimary(provider);
      _loadingKey = true;
      _hasKey = false;
      _keyController.clear();
    });
    final key = await AiService.getApiKey(provider);
    if (!mounted || revision != _keyLoadRevision) return;
    setState(() {
      _hasKey = key != null;
      _loadingKey = false;
    });
  }

  Future<void> _save() async {
    if (_loadingKey || _saving) return;
    final routing = _routing!;
    setState(() => _saving = true);
    try {
      if (_keyController.text.trim().isNotEmpty) {
        await AiService.setApiKey(routing.primary, _keyController.text);
      }
      await AiService.setTextSettings(routing);
      if (mounted) widget.onChanged();
    } catch (error) {
      GlobalSnackbar.error(error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _removeKey() async {
    await AiService.setApiKey(_provider!, null);
    await _selectProvider(_provider!);
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final provider = _provider;
    if (provider == null) return const LinearProgressIndicator();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 12.0,
      children: [
        Text(context.l10n.aiSettingsDescription),
        Text(context.l10n.aiRequestSettingsHelp),
        SegmentedButton<AiProvider>(
          segments: [
            for (final option in AiProvider.values) ButtonSegment(value: option, label: Text(option.displayName)),
          ],
          selected: {provider},
          onSelectionChanged: _saving ? null : (selection) => _selectProvider(selection.first),
        ),
        TextField(
          controller: _keyController,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          enabled: !_loadingKey && !_saving,
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            labelText: context.l10n.aiApiKey(provider.displayName),
            hintText: _hasKey ? context.l10n.aiApiKeySaved : null,
          ),
        ),
        for (final backup in AiProvider.values.where((value) => value != provider))
          Row(
            children: [
              Expanded(
                child: CheckboxListTile(
                  key: ValueKey('aiRequestFallback-${backup.name}'),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text(context.l10n.aiRequestFallback(backup.displayName)),
                  value: _routing!.fallbacks.contains(backup),
                  onChanged: _saving
                      ? null
                      : (enabled) => setState(() {
                          _routing = AiTextSettings(
                            primary: provider,
                            fallbacks: (enabled ?? false)
                                ? [..._routing!.fallbacks, backup]
                                : _routing!.fallbacks.where((value) => value != backup),
                          );
                        }),
                ),
              ),
              TextButton(
                key: ValueKey('aiRequestKey-${backup.name}'),
                onPressed: _saving ? null : () => showAiApiKeyDialog(context: context, provider: backup),
                child: Text(context.l10n.djVoiceManageKey),
              ),
            ],
          ),
        Wrap(
          spacing: 8.0,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton(onPressed: _loadingKey || _saving ? null : _save, child: Text(context.l10n.save)),
            if (_hasKey) OutlinedButton(onPressed: _saving ? null : _removeKey, child: Text(context.l10n.aiRemoveKey)),
            TextButton.icon(
              onPressed: () => launchUrl(Uri.parse(provider.keyUrl), mode: LaunchMode.externalApplication),
              icon: const Icon(TablerIcons.external_link, size: 18),
              label: Text(context.l10n.aiGetKey),
            ),
          ],
        ),
      ],
    );
  }
}
