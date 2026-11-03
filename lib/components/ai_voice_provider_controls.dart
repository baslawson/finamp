import 'dart:async';

import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/services/ai_service.dart';
import 'package:finamp/services/dj_voice_service.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// API keys are shared by request generation and voice playback.
Future<void> showAiApiKeyDialog({required BuildContext context, required AiProvider provider}) async {
  final hasKey = await AiService.getApiKey(provider) != null;
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (_) => _VoiceApiKeyDialog(provider: provider, hasKey: hasKey),
  );
}

/// Voice API choices are global, including when this panel is opened for a station.
class AiVoiceProviderControls extends StatefulWidget {
  const AiVoiceProviderControls({super.key, this.compact = false, this.showHeading = true});
  final bool compact;
  final bool showHeading;

  @override
  State<AiVoiceProviderControls> createState() => _AiVoiceProviderControlsState();
}

class _AiVoiceProviderControlsState extends State<AiVoiceProviderControls> with AutomaticKeepAliveClientMixin {
  AiSpeechSettings? _settings;
  final _hasKey = <AiProvider, bool>{};
  bool _saving = false;
  Object? _error;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final settings = await AiService.getSpeechSettings();
      final keys = <AiProvider, bool>{};
      for (final provider in AiSpeechSettings.supported) {
        keys[provider] = await AiService.getApiKey(provider) != null;
      }
      if (mounted) {
        setState(() {
          _settings = settings;
          _hasKey.addAll(keys);
          _error = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _save(AiSpeechSettings settings) async {
    setState(() => _saving = true);
    try {
      await DjVoiceService.saveSpeechSettings(settings);
      if (mounted) setState(() => _settings = settings);
    } catch (error) {
      GlobalSnackbar.error(error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _editKey(AiProvider provider) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _VoiceApiKeyDialog(provider: provider, hasKey: _hasKey[provider] ?? false),
    );
    await _load();
  }

  Widget _keyButton(AiProvider provider) => TextButton(
    key: ValueKey('voiceApiKey-${provider.name}'),
    onPressed: _saving ? null : () => unawaited(_editKey(provider)),
    child: Text(context.l10n.djVoiceManageKey),
  );

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final settings = _settings;
    if (_error != null) return Text('$_error');
    if (settings == null) return const LinearProgressIndicator();
    final l10n = context.l10n;
    final controls = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(l10n.djVoiceApiHelp, style: Theme.of(context).textTheme.bodySmall),
        SwitchListTile(
          key: const ValueKey('voiceBoost'),
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.djVoiceBoost),
          subtitle: Text(l10n.djVoiceBoostHelp),
          value: settings.boost,
          onChanged: _saving
              ? null
              : (boost) => unawaited(
                  _save(AiSpeechSettings(primary: settings.primary, fallbacks: settings.fallbacks, boost: boost)),
                ),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<AiProvider>(
          key: ValueKey('voiceApiPrimary-${settings.primary.name}'),
          initialValue: settings.primary,
          isExpanded: true,
          decoration: InputDecoration(labelText: l10n.djVoicePrimaryApi),
          items: [
            for (final provider in AiSpeechSettings.supported)
              DropdownMenuItem(value: provider, child: Text(provider.displayName)),
          ],
          onChanged: _saving
              ? null
              : (provider) {
                  if (provider != null && provider != settings.primary) {
                    unawaited(_save(settings.selectPrimary(provider)));
                  }
                },
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.aiApiKey(settings.primary.displayName)),
          subtitle: Text((_hasKey[settings.primary] ?? false) ? l10n.aiApiKeySaved : l10n.djVoiceKeyNeeded),
          trailing: _keyButton(settings.primary),
        ),
        Text(l10n.djVoiceFallbackApis, style: Theme.of(context).textTheme.titleSmall),
        Text(l10n.djVoiceFallbackHelp, style: Theme.of(context).textTheme.bodySmall),
        for (final provider in AiSpeechSettings.supported.where((value) => value != settings.primary))
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Checkbox(
              key: ValueKey('voiceApiFallback-${provider.name}'),
              semanticLabel: l10n.djVoiceFallbackApi(provider.displayName),
              value: settings.fallbacks.contains(provider),
              onChanged: _saving
                  ? null
                  : (enabled) => unawaited(
                      _save(
                        AiSpeechSettings(
                          primary: settings.primary,
                          boost: settings.boost,
                          fallbacks: (enabled ?? false)
                              ? [...settings.fallbacks, provider]
                              : settings.fallbacks.where((value) => value != provider),
                        ),
                      ),
                    ),
            ),
            title: Text(provider.displayName),
            subtitle: Text((_hasKey[provider] ?? false) ? l10n.aiApiKeySaved : l10n.djVoiceKeyNeeded),
            trailing: _keyButton(provider),
          ),
        ValueListenableBuilder<AiProvider?>(
          valueListenable: AiService.lastSpeechProvider,
          builder: (context, provider, _) => provider == null
              ? const SizedBox.shrink()
              : Text(l10n.djVoiceLastApi(provider.displayName), style: Theme.of(context).textTheme.bodySmall),
        ),
      ],
    );
    if (widget.compact) {
      return ExpansionTile(
        key: const ValueKey('voiceApiSettings'),
        tilePadding: EdgeInsets.zero,
        title: Text(l10n.djVoiceApi),
        subtitle: Text(settings.order.map((provider) => provider.displayName).join(' → ')),
        children: [controls],
      );
    }
    if (!widget.showHeading) return controls;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.djVoiceApi, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          controls,
        ],
      ),
    );
  }
}

class _VoiceApiKeyDialog extends StatefulWidget {
  const _VoiceApiKeyDialog({required this.provider, required this.hasKey});
  final AiProvider provider;
  final bool hasKey;
  @override
  State<_VoiceApiKeyDialog> createState() => _VoiceApiKeyDialogState();
}

class _VoiceApiKeyDialogState extends State<_VoiceApiKeyDialog> {
  final _controller = TextEditingController();
  bool _saving = false;
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save({bool remove = false}) async {
    final key = _controller.text.trim();
    if (!remove && key.isEmpty) return;
    setState(() => _saving = true);
    try {
      await DjVoiceService.saveSpeechApiKey(widget.provider, remove ? null : key);
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      GlobalSnackbar.error(error);
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: Text(context.l10n.aiApiKey(widget.provider.displayName)),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: _controller,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          enabled: !_saving,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: context.l10n.aiApiKey(widget.provider.displayName),
            hintText: widget.hasKey ? context.l10n.aiApiKeySaved : null,
          ),
        ),
        TextButton(
          onPressed: () =>
              unawaited(launchUrl(Uri.parse(widget.provider.keyUrl), mode: LaunchMode.externalApplication)),
          child: Text(context.l10n.aiGetKey),
        ),
      ],
    ),
    actions: [
      if (widget.hasKey)
        TextButton(
          onPressed: _saving ? null : () => unawaited(_save(remove: true)),
          child: Text(context.l10n.aiRemoveKey),
        ),
      TextButton(
        onPressed: _saving ? null : () => Navigator.of(context).pop(),
        child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
      ),
      FilledButton(
        onPressed: _saving || _controller.text.trim().isEmpty ? null : () => unawaited(_save()),
        child: Text(context.l10n.save),
      ),
    ],
  );
}
