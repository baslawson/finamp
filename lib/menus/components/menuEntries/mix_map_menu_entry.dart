import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/menus/components/menuEntries/menu_entry.dart';
import 'package:finamp/screens/mix_map_screen.dart';
import 'package:finamp/services/analyzer_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

final _analyzerConfiguredProvider = FutureProvider.autoDispose((ref) => AnalyzerService.isConfigured());

/// Opens the [MixMapScreen] for the queue. Needs the analyzer, which knows each song's key and tempo.
class MixMapMenuEntry extends ConsumerWidget implements HideableMenuEntry {
  const MixMapMenuEntry({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!(ref.watch(_analyzerConfiguredProvider).valueOrNull ?? false)) return const SizedBox.shrink();
    return MenuEntry(
      icon: TablerIcons.chart_line,
      title: context.l10n.mixMap,
      onTap: () {
        final navigator = Navigator.of(context);
        navigator.pop(); // close menu
        navigator.pushNamed(MixMapScreen.routeName);
      },
    );
  }

  @override
  bool get isVisible => true;
}
