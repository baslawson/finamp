import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/services/karaoke_service.dart';
import 'package:flutter/widgets.dart';

/// How lists name each part's version of a song.
extension KaraokePartText on KaraokePart {
  /// What a list adds after the song's name; vocal karaoke is the plain song.
  String? label(BuildContext context) => switch (this) {
    KaraokePart.vocals => null,
    KaraokePart.drums => context.l10n.karaokeDrumless,
    KaraokePart.both => context.l10n.karaokeBackingOnly,
  };

  String play(BuildContext context) => switch (this) {
    KaraokePart.vocals => context.l10n.karaokePlay,
    KaraokePart.drums => context.l10n.karaokePlayDrums,
    KaraokePart.both => context.l10n.karaokePlayBoth,
  };

  /// The guide brought back is drums whenever the drums are taken out.
  String guide(BuildContext context) =>
      this == KaraokePart.vocals ? context.l10n.karaokeGuideVocals : context.l10n.karaokeGuideDrums;
}
