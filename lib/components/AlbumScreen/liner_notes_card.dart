import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/ai_service.dart';
import 'package:finamp/services/item_helper.dart';
import 'package:finamp/services/jellyfin_api_helper.dart';
import 'package:finamp/services/liner_notes_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

/// Liner notes at the end of an album page. Written on request, then kept.
class LinerNotesCard extends StatefulWidget {
  const LinerNotesCard({super.key, required this.album, required this.tracks});

  final BaseItemDto album;
  final List<BaseItemDto> tracks;

  @override
  State<LinerNotesCard> createState() => _LinerNotesCardState();
}

class _LinerNotesCardState extends State<LinerNotesCard> {
  LinerNotes? _notes;
  List<BaseItemDto> _related = [];
  bool _loading = true;
  bool _writing = false;
  bool _aiConfigured = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final notes = await LinerNotesService.cached(widget.album);
    final configured = await AiService.isConfigured();
    if (!mounted) return;
    setState(() {
      _notes = notes;
      _aiConfigured = configured;
      _loading = false;
    });
    if (notes != null) await _loadRelated(notes);
  }

  Future<void> _loadRelated(LinerNotes notes) async {
    if (notes.relatedIds.isEmpty) return;
    try {
      final related =
          await GetIt.instance<JellyfinApiHelper>().getItems(
            itemIds: [for (final id in notes.relatedIds) BaseItemId(id)],
          ) ??
          [];
      if (mounted) setState(() => _related = related);
    } catch (_) {
      // Offline or removed albums: just leave them out.
    }
  }

  Future<void> _write() async {
    setState(() => _writing = true);
    try {
      await LinerNotesService.forget(widget.album);
      final notes = await LinerNotesService.write(widget.album, widget.tracks);
      if (!mounted) return;
      setState(() => _notes = notes);
      await _loadRelated(notes);
    } catch (e) {
      GlobalSnackbar.error(e);
    } finally {
      if (mounted) setState(() => _writing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final notes = _notes;
    if (_loading || (notes == null && !_aiConfigured)) return const SizedBox.shrink();
    final textTheme = Theme.of(context).textTheme;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: notes == null
            ? Row(
                children: [
                  const Icon(TablerIcons.notebook),
                  const SizedBox(width: 12),
                  Expanded(child: Text(context.l10n.linerNotesOffer)),
                  const SizedBox(width: 8),
                  FilledButton.tonal(
                    onPressed: _writing ? null : _write,
                    child: _writing
                        ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : Text(context.l10n.linerNotesWrite),
                  ),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(TablerIcons.notebook),
                      const SizedBox(width: 12),
                      Expanded(child: Text(context.l10n.linerNotes, style: textTheme.titleLarge)),
                      if (_aiConfigured)
                        IconButton(
                          tooltip: context.l10n.linerNotesRewrite,
                          onPressed: _writing ? null : _write,
                          icon: _writing
                              ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(TablerIcons.refresh),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(notes.story, style: textTheme.bodyMedium?.copyWith(height: 1.45)),
                  if (notes.highlights.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Text(context.l10n.linerNotesHighlights, style: textTheme.titleMedium),
                    const SizedBox(height: 4),
                    for (final highlight in notes.highlights)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: "${highlight.track} — ",
                                style: const TextStyle(fontWeight: FontWeight.bold),
                              ),
                              TextSpan(text: highlight.note),
                            ],
                          ),
                        ),
                      ),
                  ],
                  if (_related.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Text(context.l10n.linerNotesNext, style: textTheme.titleMedium),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        for (final album in _related)
                          ActionChip(
                            avatar: const Icon(TablerIcons.disc),
                            label: Text("${album.name} · ${album.albumArtist ?? ""}"),
                            onPressed: () => openItemPage(album, Navigator.of(context)),
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 8),
                  Text(context.l10n.linerNotesDisclaimer, style: textTheme.bodySmall),
                ],
              ),
      ),
    );
  }
}
