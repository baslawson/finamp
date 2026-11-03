import 'package:finamp/components/karaoke_delete_dialog.dart';
import 'package:finamp/components/karaoke_part_text.dart';
import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/screens/karaoke_screen.dart';
import 'package:finamp/screens/karaoke_dashboard_screen.dart';
import 'package:finamp/services/karaoke_service.dart';
import 'package:finamp/services/music_player_background_task.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

class SavedKaraokeScreen extends StatefulWidget {
  const SavedKaraokeScreen({super.key, this.service});
  final KaraokeService? service;
  static const routeName = '/karaoke/saved';
  @override
  State<SavedKaraokeScreen> createState() => _SavedKaraokeScreenState();
}

class _SavedKaraokeScreenState extends State<SavedKaraokeScreen> {
  late final _service = widget.service ?? KaraokeService.instance;
  late var _songs = _service.savedSongs();
  String? _error;
  bool _busy = false;

  Future<void> _play(SavedKaraoke saved, int guide) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final file = await _service.localMix(saved.item.id.raw, saved.job, guide, onlyOffline: true);
      if (file == null || !mounted) return;
      await GetIt.instance<MusicPlayerBackgroundTask>().playSavedKaraoke(
        saved.item,
        file,
        saved.job.measurement(guide),
        context.l10n.karaokeSavedLibrary,
      );
      if (mounted) {
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => KaraokeScreen(initialGuide: guide, initialPart: saved.job.part),
            settings: const RouteSettings(name: KaraokeScreen.routeName),
          ),
        );
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(SavedKaraoke saved) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (karaokeCopyInUse(saved.item)) throw StateError(context.l10n.karaokeDeleteInUse);
      if (!await confirmKaraokeDeletion(context, saved.item, server: false) || !mounted) return;
      if (karaokeCopyInUse(saved.item)) throw StateError(context.l10n.karaokeDeleteInUse);
      await _service.deleteLocal(saved.item.id.raw);
      if (mounted) {
        setState(() {
          _songs = _service.savedSongs();
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(context.l10n.karaokeSavedLibrary),
      actions: [
        IconButton(
          tooltip: context.l10n.karaokeDashboard,
          icon: const Icon(Icons.queue_music),
          onPressed: _busy
              ? null
              : () async {
                  await Navigator.of(
                    context,
                  ).push(MaterialPageRoute<void>(builder: (_) => KaraokeDashboardScreen(service: _service)));
                  if (mounted) {
                    setState(() {
                      _songs = _service.savedSongs();
                    });
                  }
                },
        ),
      ],
    ),
    body: Column(
      children: [
        if (_busy) const LinearProgressIndicator(),
        if (_error != null) Padding(padding: const EdgeInsets.all(16), child: Text(_error!)),
        Expanded(
          child: FutureBuilder<List<SavedKaraoke>>(
            future: _songs,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Center(
                  child: Padding(padding: const EdgeInsets.all(16), child: Text('${snapshot.error}')),
                );
              }
              final songs = snapshot.data;
              if (songs == null) return const Center(child: CircularProgressIndicator());
              if (songs.isEmpty) {
                return Center(
                  child: Padding(padding: const EdgeInsets.all(24), child: Text(context.l10n.karaokeOfflineMissing)),
                );
              }
              return ListView.builder(
                itemCount: songs.length,
                itemBuilder: (context, index) {
                  final saved = songs[index];
                  final part = saved.job.part;
                  return ListTile(
                    title: Text([saved.item.name ?? context.l10n.karaoke, part.label(context)].nonNulls.join(' · ')),
                    subtitle: Text(saved.item.artists?.join(', ') ?? ''),
                    onTap: _busy ? null : () => _play(saved, saved.guides.first),
                    trailing: PopupMenuButton<String>(
                      enabled: !_busy,
                      onSelected: (action) => action == 'delete' ? _delete(saved) : _play(saved, int.parse(action)),
                      itemBuilder: (_) => [
                        for (final guide in saved.guides)
                          PopupMenuItem(value: '$guide', child: Text('${part.guide(context)}: $guide%')),
                        const PopupMenuDivider(),
                        PopupMenuItem(value: 'delete', child: Text(context.l10n.karaokeDeletePhone)),
                      ],
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    ),
  );
}
