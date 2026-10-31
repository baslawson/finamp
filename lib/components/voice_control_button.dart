import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/menus/components/icon_button_with_semantics.dart';
import 'package:finamp/services/voice_control_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

/// Starts voice control with the app's texts.
Future<void> startVoiceControl(BuildContext context) {
  final l10n = context.l10n;
  return VoiceControlService.listen(
    prompt: l10n.voiceControlPrompt,
    messages: VoiceControlMessages(
      unavailable: l10n.voiceControlUnavailable,
      nothingPlaying: l10n.voiceControlNothingPlaying,
      nowPlaying: l10n.voiceControlNowPlaying,
      volume: (volume) => l10n.voiceControlVolume((volume * 100).round()),
      shufflingFavorites: l10n.voiceControlShufflingFavorites,
      shufflingEverything: l10n.voiceControlShufflingEverything,
      playing: l10n.voiceControlPlaying,
      notFound: l10n.voiceControlNotFound,
      notUnderstood: l10n.voiceControlNotUnderstood,
    ),
  );
}

/// A microphone button that starts voice control, shown only where speech recognition is available.
class VoiceControlButton extends StatelessWidget {
  const VoiceControlButton({super.key});

  static final _available = VoiceControlService.isAvailable();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _available,
      builder: (context, available) => (available.data ?? false)
          ? IconButtonWithSemantics(
              label: context.l10n.voiceControl,
              icon: TablerIcons.microphone,
              iconSize: 28.0,
              onPressed: () => startVoiceControl(context),
            )
          : const SizedBox.shrink(),
    );
  }
}
