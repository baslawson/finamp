import 'package:finamp/components/AudioServiceSettingsScreen/shuffle_randomness_slider.dart';
import 'package:finamp/components/harmonic_mixing_switch.dart';
import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:finamp/services/radio_tuning.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A ready-made mix feel: a Randomness and a Harmonic strength, in percent.
typedef MixFeelPreset = ({int randomness, int strength});

/// The presets offered, from most random to most DJ-like.
const mixFeelPresets = <MixFeelPreset>[
  (randomness: 100, strength: 30),
  (randomness: 50, strength: 75),
  (randomness: 25, strength: 90),
  (randomness: 0, strength: 100),
];

/// The preset matching [randomness] and [strength] exactly, if any.
MixFeelPreset? mixFeelPresetOf(int randomness, int strength) {
  for (final preset in mixFeelPresets) {
    if (preset.randomness == randomness && preset.strength == strength) return preset;
  }
  return null;
}

/// The value along an axis of [length] at [offset], in percent; [flipped] puts 100% at the start (the pad's top).
int mixFeelPercentAt(double offset, double length, {bool flipped = false}) {
  if (length <= 0) return 0;
  final t = (offset / length).clamp(0.0, 1.0);
  return ((flipped ? 1 - t : t) * 100).round();
}

/// Randomness and Harmonic strength as one control: a pad where across is Randomness and up is Harmonic strength,
/// with presets and the two exact sliders. The setting that doesn't order this mix is faded: Randomness while
/// [harmonic] mixing is on (it's only used if too few songs are analysed), Harmonic strength while it's off.
class MixFeel extends ConsumerWidget {
  const MixFeel({super.key, required this.harmonic});

  final bool harmonic;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final randomness = ref.watch(
      finampSettingsProvider.select(
        (value) => (value.valueOrNull ?? FinampSettingsHelper.finampSettings).shuffleRandomness.clamp(0, 100),
      ),
    );
    return ValueListenableBuilder(
      valueListenable: HarmonicMixing.strength,
      builder: (context, strength, _) {
        final selected = mixFeelPresetOf(randomness, strength);
        final names = [l10n.mixFeelSurprise, l10n.mixFeelBalanced, l10n.mixFeelSmooth, l10n.mixFeelDjSet];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 8,
          children: [
            Text(l10n.mixFeelTitle, style: TextTheme.of(context).titleMedium),
            Text(
              harmonic ? l10n.smartShuffleRandomnessHarmonicHint : l10n.mixFeelDescription,
              style: TextTheme.of(context).bodySmall,
            ),
            _Pad(randomness: randomness, strength: strength, harmonic: harmonic),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final (index, preset) in mixFeelPresets.indexed)
                  ChoiceChip(
                    label: Text(names[index]),
                    selected: selected == preset,
                    onSelected: (_) => _set(preset.randomness, preset.strength, save: true),
                  ),
              ],
            ),
            // The exact values, also the way to set them with a screen reader.
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: EdgeInsets.zero,
              title: Text(l10n.mixFeelExactValues),
              children: [
                Opacity(
                  opacity: harmonic ? 0.5 : 1,
                  child: const ShuffleRandomnessSlider(padding: EdgeInsets.symmetric(vertical: 8)),
                ),
                Opacity(
                  opacity: harmonic ? 1 : 0.5,
                  child: const HarmonicStrengthSlider(padding: EdgeInsets.symmetric(vertical: 8)),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// Sets both values: shown straight away, the Harmonic strength saved when [save] (once let go).
void _set(int randomness, int strength, {required bool save}) {
  if (FinampSettingsHelper.finampSettings.shuffleRandomness != randomness) {
    FinampSetters.setShuffleRandomness(randomness);
  }
  HarmonicMixing.strength.value = strength;
  if (save) HarmonicMixing.setStrength(strength).ignore();
}

class _Pad extends StatelessWidget {
  const _Pad({required this.randomness, required this.strength, required this.harmonic});

  final int randomness, strength;
  final bool harmonic;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = ColorScheme.of(context);
    final small = TextTheme.of(context).labelSmall;
    return Semantics(
      label: l10n.mixFeelSemantics(l10n.shuffleRandomnessPercent(randomness), l10n.shuffleRandomnessPercent(strength)),
      excludeSemantics: true,
      child: LayoutBuilder(
        builder: (context, constraints) {
          const height = 140.0, dot = 22.0;
          final width = constraints.maxWidth;
          void at(Offset position, {required bool save}) => _set(
            mixFeelPercentAt(position.dx, width),
            mixFeelPercentAt(position.dy, height, flipped: true),
            save: save,
          );
          // Takes the drag at once, so dragging up or down moves the dot rather than scrolling the menu.
          return RawGestureDetector(
            gestures: {
              _ImmediatePanGestureRecognizer: GestureRecognizerFactoryWithHandlers<_ImmediatePanGestureRecognizer>(
                _ImmediatePanGestureRecognizer.new,
                (recognizer) => recognizer
                  ..onDown = ((details) => at(details.localPosition, save: false))
                  ..onUpdate = ((details) => at(details.localPosition, save: false))
                  // Saved as last shown, since this pad is rebuilt on every move.
                  ..onEnd = ((_) => HarmonicMixing.setStrength(HarmonicMixing.strength.value).ignore())
                  ..onCancel = (() => HarmonicMixing.setStrength(HarmonicMixing.strength.value).ignore()),
              ),
            },
            child: Container(
              height: height,
              decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(16)),
              child: Stack(
                children: [
                  // Strength runs up the side, Randomness along the bottom; the one not in use is faded.
                  Positioned(
                    left: 10,
                    top: 8,
                    child: Opacity(
                      opacity: harmonic ? 1 : 0.4,
                      child: Text(l10n.harmonicStrengthStrict, style: small),
                    ),
                  ),
                  Positioned(
                    left: 10,
                    bottom: 8,
                    child: Opacity(
                      opacity: harmonic ? 0.4 : 1,
                      child: Text(l10n.shuffleRandomnessOrdered, style: small),
                    ),
                  ),
                  Positioned(
                    right: 10,
                    bottom: 8,
                    child: Opacity(
                      opacity: harmonic ? 0.4 : 1,
                      child: Text(l10n.shuffleRandomnessRandom, style: small),
                    ),
                  ),
                  Positioned(
                    left: (randomness / 100) * (width - dot),
                    top: (1 - strength / 100) * (height - dot),
                    child: Container(
                      width: dot,
                      height: dot,
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        shape: BoxShape.circle,
                        border: Border.all(color: scheme.surface, width: 2),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// A pan that wins as soon as the finger is down, ahead of the scrolling around it.
class _ImmediatePanGestureRecognizer extends PanGestureRecognizer {
  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolve(GestureDisposition.accepted);
  }
}
