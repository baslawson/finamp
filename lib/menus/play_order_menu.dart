import 'package:finamp/components/menu_sheet.dart';
import 'package:finamp/components/fun_heading.dart';
import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/components/harmonic_mixing_switch.dart';
import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/menus/components/playbackActions/playback_action.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/services/analyzer_service.dart';
import 'package:finamp/services/feedback_helper.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';
import 'package:rxdart/rxdart.dart';

/// Whether the analyzer is set up, which harmonic order needs for each song's key and tempo.
final analyzerConfiguredProvider = FutureProvider.autoDispose((ref) => AnalyzerService.isConfigured());

/// Turns harmonic order for the rest of the queue on or off, saying so when too few songs are analysed for it.
Future<void> toggleHarmonicOrder() async {
  final queueService = GetIt.instance<QueueService>();
  FeedbackHelper.feedback(FeedbackType.selection);
  if (!await queueService.setHarmonicOrder(!queueService.harmonicOrder)) {
    GlobalSnackbar.message((context) => context.l10n.harmonicOrderNotEnoughAnalysis);
  }
}

/// The options menu's Harmonic button: lit while the rest of the queue is in harmonic order.
class HarmonicOrderAction extends StatelessWidget {
  const HarmonicOrderAction({super.key, required this.iconColor});

  /// The colour for when it's on.
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<bool>(
      stream: GetIt.instance<QueueService>().getHarmonicOrderStream(),
      builder: (context, snapshot) {
        final on = snapshot.data ?? false;
        return PlaybackAction(
          icon: TablerIcons.wave_sine,
          onPressed: toggleHarmonicOrder,
          onLongPress: () => showPlayOrderMenu(context),
          label: context.l10n.harmonicOrderButtonLabel,
          iconColor: on ? iconColor : Theme.of(context).textTheme.bodyMedium?.color ?? Colors.white,
          glow: on,
        );
      },
    );
  }
}

enum _PlayOrder { inOrder, shuffle, harmonic }

/// Picks how the rest of the queue plays: in order, shuffled, or in harmonic order. Opened by long-pressing a shuffle
/// button.
Future<void> showPlayOrderMenu(BuildContext context) {
  // As tall as it needs, scrolling on a short screen, with room for the harmonic strength.
  return showMenuSheet<void>(context: context, builder: (_) => const _PlayOrderMenu());
}

class _PlayOrderMenu extends ConsumerWidget {
  const _PlayOrderMenu();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queueService = GetIt.instance<QueueService>();
    final analyzer = ref.watch(analyzerConfiguredProvider).value ?? false;
    return SafeArea(
      child: StreamBuilder<_PlayOrder>(
        stream: Rx.combineLatest2(
          queueService.getPlaybackOrderStream(),
          queueService.getHarmonicOrderStream(),
          (order, harmonic) => harmonic
              ? _PlayOrder.harmonic
              : order == FinampPlaybackOrder.shuffled
              ? _PlayOrder.shuffle
              : _PlayOrder.inOrder,
        ),
        builder: (context, snapshot) {
          final selected = snapshot.data;
          Future<void> choose(_PlayOrder choice) async {
            Navigator.of(context).pop();
            if (choice == selected) return;
            switch (choice) {
              case _PlayOrder.inOrder:
                await queueService.setPlaybackOrder(FinampPlaybackOrder.linear);
              case _PlayOrder.shuffle:
                await queueService.setPlaybackOrder(FinampPlaybackOrder.shuffled);
              case _PlayOrder.harmonic:
                await toggleHarmonicOrder();
            }
          }

          Widget option(_PlayOrder choice, IconData icon, String title, String subtitle, {bool enabled = true}) =>
              ListTile(
                leading: Icon(icon),
                title: Text(title),
                subtitle: Text(subtitle),
                trailing: selected == choice ? const Icon(TablerIcons.check) : null,
                selected: selected == choice,
                enabled: enabled,
                onTap: () => choose(choice),
              );

          return SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: GradientTitle(context.l10n.playOrderMenuTitle, icon: TablerIcons.wave_sine),
                ),
                option(
                  _PlayOrder.inOrder,
                  TablerIcons.arrows_right,
                  context.l10n.playOrderInOrder,
                  context.l10n.playOrderInOrderDescription,
                ),
                option(
                  _PlayOrder.shuffle,
                  TablerIcons.arrows_shuffle,
                  context.l10n.playOrderShuffle,
                  context.l10n.playOrderShuffleDescription,
                ),
                option(
                  _PlayOrder.harmonic,
                  TablerIcons.wave_sine,
                  context.l10n.harmonicOrderButtonLabel,
                  analyzer ? context.l10n.playOrderHarmonicDescription : context.l10n.harmonicMixingNeedsAnalyzer,
                  enabled: analyzer,
                ),
                // Shared with every harmonic mix; letting go puts the rest of the queue in order again at the new strength.
                if (analyzer) HarmonicStrengthSlider(onChangeEnd: (_) => queueService.refreshHarmonicOrder()),
                const SizedBox(height: 8),
              ],
            ),
          );
        },
      ),
    );
  }
}
