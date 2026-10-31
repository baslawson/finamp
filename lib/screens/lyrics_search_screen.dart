import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/menus/ai_dj_menu.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/services/ai_service.dart';
import 'package:finamp/services/lyrics_search_service.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

/// Finds a song from a line of its lyrics.
class LyricsSearchScreen extends StatefulWidget {
  const LyricsSearchScreen({super.key});

  static const routeName = "/music/search/lyrics";

  @override
  State<LyricsSearchScreen> createState() => _LyricsSearchScreenState();
}

class _LyricsSearchScreenState extends State<LyricsSearchScreen> {
  final _query = TextEditingController();
  List<LyricsMatch>? _results;
  bool _searching = false;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final initial = ModalRoute.of(context)?.settings.arguments;
    if (initial is String && initial.trim().isNotEmpty) {
      _query.text = initial;
      WidgetsBinding.instance.addPostFrameCallback((_) => _search());
    }
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _query.text.trim();
    if (query.isEmpty) return;
    FocusScope.of(context).unfocus();
    if (!await AiService.isConfigured()) {
      GlobalSnackbar.message((context) => context.l10n.lyricsSearchNeedsAi);
      if (mounted) await showAiDjMenu(context: context);
      return;
    }
    setState(() => _searching = true);
    try {
      final results = await LyricsSearchService.search(query);
      if (mounted) setState(() => _results = results);
    } catch (e) {
      GlobalSnackbar.error(e);
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _play(LyricsMatch match) async {
    await GetIt.instance<QueueService>().startPlayback(
      items: [match.track!],
      source: QueueItemSource.rawId(
        type: QueueItemSourceType.unknown,
        name: QueueItemSourceName(
          type: QueueItemSourceNameType.preTranslated,
          pretranslatedName: context.l10n.lyricsSearch,
        ),
        id: "lyricsSearch",
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final results = _results;
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.lyricsSearch)),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          Text(context.l10n.lyricsSearchDescription),
          const SizedBox(height: 12),
          TextField(
            controller: _query,
            minLines: 1,
            maxLines: 3,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _search(),
            decoration: InputDecoration(
              hintText: context.l10n.lyricsSearchHint,
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(TablerIcons.quote),
            ),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _searching ? null : _search,
            icon: const Icon(TablerIcons.search),
            label: Text(context.l10n.lyricsSearchButton),
          ),
          if (_searching) const Padding(padding: EdgeInsets.only(top: 16), child: LinearProgressIndicator()),
          if (results != null && results.isEmpty && !_searching)
            Padding(
              padding: const EdgeInsets.all(32),
              child: Center(child: Text(context.l10n.lyricsSearchNone)),
            ),
          if (results != null && !_searching)
            for (final match in results)
              Card(
                margin: const EdgeInsets.only(top: 12),
                child: ListTile(
                  enabled: true,
                  leading: Icon(
                    match.track != null ? TablerIcons.player_play : TablerIcons.music_off,
                    color: match.track != null ? colors.primary : colors.outline,
                  ),
                  title: Text(match.song.title),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(match.song.artist),
                      if (match.line != null)
                        Text("“${match.line}”", style: const TextStyle(fontStyle: FontStyle.italic)),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 6,
                        children: [
                          if (match.verified)
                            Chip(
                              visualDensity: VisualDensity.compact,
                              avatar: const Icon(TablerIcons.circle_check, size: 16),
                              label: Text(context.l10n.lyricsSearchConfirmed),
                            ),
                          Chip(
                            visualDensity: VisualDensity.compact,
                            label: Text(
                              match.track != null
                                  ? context.l10n.lyricsSearchInLibrary
                                  : context.l10n.importNotInLibrary,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  isThreeLine: true,
                  onTap: match.track == null ? null : () => _play(match),
                ),
              ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
