import 'package:finamp/components/normalization_details.dart';
import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

import 'menu_entry.dart';

class NormalizationDetailsMenuEntry extends StatelessWidget implements HideableMenuEntry {
  const NormalizationDetailsMenuEntry({super.key, required this.item});
  final BaseItemDto item;

  @override
  bool get isVisible => true;

  @override
  Widget build(BuildContext context) => MenuEntry(
    icon: TablerIcons.adjustments,
    title: context.l10n.volumeNormalizationSettingsTitle,
    onTap: () => showDialog<void>(
      context: context,
      builder: (_) => NormalizationDetailsDialog(item: item),
    ),
  );
}
