import 'dart:async';
import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/services/headphone_eq_service.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

class HeadphoneToneControls extends StatefulWidget {
  const HeadphoneToneControls({super.key, required this.equalizer});
  final AndroidEqualizer equalizer;
  @override
  State<HeadphoneToneControls> createState() => _HeadphoneToneControlsState();
}

class _HeadphoneToneControlsState extends State<HeadphoneToneControls> {
  HeadphoneTone? _tone;
  bool? _before;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    HeadphoneEqService.loadTone().then((v) {
      if (mounted) setState(() => _tone = v);
    });
  }

  @override
  void dispose() {
    if (_before != null) unawaited(HeadphoneEqService.endPreview(widget.equalizer).catchError((Object _) {}));
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      GlobalSnackbar.error(e);
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final tone = _tone;
    if (tone == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        Text(context.l10n.listeningFineTune, style: Theme.of(context).textTheme.titleMedium),
        for (final (index, label, value) in [
          (0, context.l10n.listeningBass, tone.bass),
          (1, context.l10n.listeningWarmth, tone.warmth),
          (2, context.l10n.listeningClarity, tone.clarity),
        ]) ...[
          Text('$label: ${value.toStringAsFixed(1)} dB'),
          Slider(
            value: value,
            min: -4,
            max: 4,
            divisions: 16,
            onChanged: _busy || _before != null
                ? null
                : (v) => setState(
                    () => _tone = HeadphoneTone(
                      bass: index == 0 ? v : tone.bass,
                      warmth: index == 1 ? v : tone.warmth,
                      clarity: index == 2 ? v : tone.clarity,
                    ),
                  ),
            onChangeEnd: _busy || _before != null
                ? null
                : (_) => _run(() => HeadphoneEqService.saveTone(_tone!, widget.equalizer)),
          ),
        ],
        Text(context.l10n.listeningPreviewDescription),
        Wrap(
          spacing: 8,
          children: [
            for (final before in [true, false])
              ChoiceChip(
                label: Text(before ? context.l10n.listeningBefore : context.l10n.listeningAfter),
                selected: _before == before,
                onSelected: _busy
                    ? null
                    : (_) => _run(() async {
                        await HeadphoneEqService.previewTone(
                          widget.equalizer,
                          before: before,
                        ).timeout(const Duration(seconds: 3));
                        if (mounted) {
                          setState(() => _before = before);
                        } else {
                          await HeadphoneEqService.endPreview(widget.equalizer);
                        }
                      }),
              ),
            if (_before != null)
              ActionChip(
                label: Text(context.l10n.listeningEndPreview),
                onPressed: _busy
                    ? null
                    : () => _run(() async {
                        await HeadphoneEqService.endPreview(widget.equalizer);
                        if (mounted) setState(() => _before = null);
                      }),
              ),
          ],
        ),
        TextButton(
          onPressed: _busy || _before != null
              ? null
              : () => _run(() async {
                  await HeadphoneEqService.saveTone(const HeadphoneTone(), widget.equalizer);
                  if (mounted) setState(() => _tone = const HeadphoneTone());
                }),
          child: Text(context.l10n.listeningResetTone),
        ),
        const Divider(),
      ],
    );
  }
}
