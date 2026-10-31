import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/services/dj_voice_service.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class DjVoiceSessionControls extends StatefulWidget {
  const DjVoiceSessionControls({super.key});
  @override
  State<DjVoiceSessionControls> createState() => _DjVoiceSessionControlsState();
}

class _DjVoiceSessionControlsState extends State<DjVoiceSessionControls> {
  bool _busy = false;
  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      GlobalSnackbar.error(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: DjVoiceService.status,
    builder: (context, state, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (state.$3 != null)
          Text(
            context.l10n.djQuietUntil(
              DateFormat.jm(Localizations.localeOf(context).toString()).format(state.$3!.toLocal()),
            ),
          ),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            TextButton.icon(
              onPressed: _busy || !(state.$1 || state.$2) ? null : () => _run(DjVoiceService.skipAnnouncement),
              icon: const Icon(Icons.skip_next),
              label: Text(context.l10n.djSkipAnnouncement),
            ),
            PopupMenuButton<int>(
              tooltip: context.l10n.djTemporaryQuiet,
              enabled: !_busy,
              onSelected: (minutes) => _run(() => DjVoiceService.quietFor(Duration(minutes: minutes))),
              itemBuilder: (context) => [
                for (final minutes in [15, 30, 60])
                  PopupMenuItem(value: minutes, child: Text(context.l10n.djQuietMinutes(minutes))),
              ],
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.volume_off_outlined),
                    const SizedBox(width: 8),
                    Flexible(child: Text(context.l10n.djTemporaryQuiet)),
                  ],
                ),
              ),
            ),
            if (state.$3 != null)
              TextButton(
                onPressed: _busy ? null : () => _run(DjVoiceService.resumeDj),
                child: Text(context.l10n.djResume),
              ),
          ],
        ),
        ValueListenableBuilder<String?>(
          valueListenable: DjVoiceService.transcript,
          builder: (context, text, _) => text == null
              ? const SizedBox.shrink()
              : Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(context.l10n.djTranscript, style: Theme.of(context).textTheme.titleSmall),
                      SelectableText(text),
                      TextButton.icon(
                        onPressed: _busy || state.$1 ? null : () => _run(DjVoiceService.replayAnnouncement),
                        icon: const Icon(Icons.replay),
                        label: Text(context.l10n.djReplay),
                      ),
                    ],
                  ),
                ),
        ),
      ],
    ),
  );
}
