import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/services/on_this_day_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

/// What you played on this date in earlier years, one card per year.
class OnThisDayScreen extends StatefulWidget {
  const OnThisDayScreen({super.key});

  static const routeName = "/onthisday";

  @override
  State<OnThisDayScreen> createState() => _OnThisDayScreenState();
}

class _OnThisDayScreenState extends State<OnThisDayScreen> {
  ({List<OnThisDayYear> years, bool widened})? _result;
  bool _starting = false;

  @override
  void initState() {
    super.initState();
    OnThisDayService.load().then((result) {
      if (mounted) setState(() => _result = result);
    });
  }

  Future<void> _play(List<PastPlay>? songs, String name) async {
    setState(() => _starting = true);
    try {
      if (!await OnThisDayService.play(songs: songs == null ? null : [...songs], name: name)) {
        GlobalSnackbar.message((context) => context.l10n.onThisDayNothingInLibrary);
      } else if (mounted) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      GlobalSnackbar.error(e);
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    final now = DateTime.now();
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.onThisDay),
        actions: [
          if (result?.years.isNotEmpty ?? false)
            IconButton(
              tooltip: context.l10n.onThisDayPlayAll,
              onPressed: _starting ? null : () => _play(null, context.l10n.onThisDay),
              icon: const Icon(TablerIcons.player_play),
            ),
        ],
      ),
      body: result == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  result.widened ? context.l10n.onThisDayWeekIntro : context.l10n.onThisDayIntro,
                  style: textTheme.bodyMedium,
                ),
                if (_starting) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
                if (result.years.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 32),
                    child: Text(context.l10n.onThisDayEmpty, textAlign: TextAlign.center),
                  ),
                for (final year in result.years)
                  Card(
                    margin: const EdgeInsets.only(top: 12),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 8, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(context.l10n.onThisDayYearsAgo(now.year - year.year), style: textTheme.titleMedium),
                                    Text(
                                      context.l10n.onThisDaySongCount("${year.year}", year.songs.length),
                                      style: textTheme.bodySmall,
                                    ),
                                  ],
                                ),
                              ),
                              IconButton.filledTonal(
                                tooltip: context.l10n.onThisDayPlayYear("${year.year}"),
                                onPressed: _starting
                                    ? null
                                    : () => _play(year.songs, context.l10n.onThisDayMixName("${year.year}")),
                                icon: const Icon(TablerIcons.player_play),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          for (final song in year.songs.take(6))
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 3),
                              child: Text(
                                song.artist.isEmpty ? song.title : "${song.title} · ${song.artist}",
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          if (year.songs.length > 6)
                            Text(
                              context.l10n.onThisDayMore(year.songs.length - 6),
                              style: textTheme.bodySmall,
                            ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}
