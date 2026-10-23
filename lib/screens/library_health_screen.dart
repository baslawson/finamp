import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/analyzer_service.dart';
import 'package:finamp/services/item_helper.dart';
import 'package:finamp/services/jellyfin_api_helper.dart';
import 'package:finamp/services/library_health_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

/// Scans the library for duplicates, low quality files, missing artwork and missing tags.
class LibraryHealthScreen extends StatefulWidget {
  const LibraryHealthScreen({super.key});

  static const routeName = "/libraryhealth";

  @override
  State<LibraryHealthScreen> createState() => _LibraryHealthScreenState();
}

class _LibraryHealthScreenState extends State<LibraryHealthScreen> {
  LibraryHealthReport? _report;
  // The analyzer's check of the audio itself, with the songs it names; null without an analyzer.
  ({LibraryHealth health, Map<String, BaseItemDto> tracks})? _audio;
  Object? _audioError;
  bool _scanning = false;
  int _scanned = 0;
  Object? _error;

  static const _shown = 100;

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _scanned = 0;
      _error = null;
      _audioError = null;
    });
    final audio = _audioCheck();
    try {
      final report = await LibraryHealthService.scan(
        onProgress: (done, _) {
          if (mounted) setState(() => _scanned = done);
        },
      );
      if (mounted) setState(() => _report = report);
      final checked = await audio;
      if (mounted) setState(() => _audio = checked);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  /// The analyzer's check: songs that can't be decoded or are cut off, long silent endings and hidden tracks, and the
  /// same recording on several albums (by its sound, not its tags). Null when there's no analyzer.
  Future<({LibraryHealth health, Map<String, BaseItemDto> tracks})?> _audioCheck() async {
    if (!await AnalyzerService.isConfigured()) return null;
    try {
      final health = await AnalyzerService.health();
      final ids = {
        ...health.broken.take(_shown).map((item) => item.id),
        ...health.cutOff.take(_shown).map((item) => item.id),
        ...health.silentEndings.take(_shown).map((item) => item.id),
        ...health.duplicates.take(_shown).expand((pair) => pair),
      }.toList();
      final tracks = <String, BaseItemDto>{};
      for (var start = 0; start < ids.length; start += 100) {
        final batch = [for (final id in ids.skip(start).take(100)) BaseItemId(id)];
        for (final track in await GetIt.instance<JellyfinApiHelper>().getItems(itemIds: batch) ?? <BaseItemDto>[]) {
          tracks[track.id.raw.replaceAll("-", "")] = track;
        }
      }
      return (health: health, tracks: tracks);
    } catch (e) {
      if (mounted) setState(() => _audioError = e);
      return null;
    }
  }

  String _trackName(String id) {
    final track = _audio?.tracks[id];
    if (track == null) return id;
    return [track.name ?? id, ?(track.artists?.firstOrNull ?? track.albumArtist)].join(" · ");
  }

  Widget _audioTile(String id, String detail) {
    final track = _audio?.tracks[id];
    return ListTile(
      dense: true,
      title: Text(_trackName(id), maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(detail),
      onTap: track == null ? null : () => _openAlbumOf(track),
    );
  }

  static String _time(double seconds) => "${seconds ~/ 60}:${(seconds.round() % 60).toString().padLeft(2, "0")}";

  Future<void> _openAlbumOf(BaseItemDto track) async {
    final albumId = track.albumId;
    if (albumId == null) return;
    final albums = await GetIt.instance<JellyfinApiHelper>().getItems(itemIds: [albumId]);
    if (albums != null && albums.isNotEmpty && mounted) openItemPage(albums.first, Navigator.of(context));
  }

  String _bitrate(BaseItemDto track) {
    final bitrate = track.mediaSources?.firstOrNull?.bitrate;
    final container = track.mediaSources?.firstOrNull?.container ?? track.container ?? "";
    return "${container.toUpperCase()} ${bitrate == null ? "" : "${bitrate ~/ 1000} kbps"}".trim();
  }

  String _missing(Set<MissingTag> missing) => missing
      .map(
        (tag) => switch (tag) {
          MissingTag.albumArtist => context.l10n.libraryHealthAlbumArtist,
          MissingTag.year => context.l10n.libraryHealthYear,
          MissingTag.genre => context.l10n.libraryHealthGenre,
        },
      )
      .join(", ");

  Widget _section<T>({
    required IconData icon,
    required String title,
    required String description,
    required List<T> items,
    required Widget Function(T item) tile,
  }) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: ExpansionTile(
        leading: Icon(icon, color: items.isEmpty ? Colors.green : Theme.of(context).colorScheme.error),
        title: Text(title),
        subtitle: Text(
          items.isEmpty ? context.l10n.libraryHealthAllGood : context.l10n.libraryHealthFound(items.length),
        ),
        enabled: items.isNotEmpty,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(description, style: Theme.of(context).textTheme.bodySmall),
          ),
          for (final item in items.take(_shown)) tile(item),
          if (items.length > _shown)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(context.l10n.libraryHealthMore(items.length - _shown)),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final report = _report;
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.libraryHealth)),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(context.l10n.libraryHealthDescription),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: FilledButton.icon(
              onPressed: _scanning ? null : _scan,
              icon: _scanning
                  ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(TablerIcons.stethoscope),
              label: Text(
                _scanning
                    ? context.l10n.libraryHealthScanning(_scanned)
                    : report == null
                    ? context.l10n.libraryHealthScan
                    : context.l10n.libraryHealthRescan,
              ),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(_error.toString(), style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          if (report != null) ...[
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                report.isHealthy
                    ? context.l10n.libraryHealthHealthy(report.trackCount, report.albumCount)
                    : context.l10n.libraryHealthSummary(report.trackCount, report.albumCount),
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            _section<List<BaseItemDto>>(
              icon: TablerIcons.copy,
              title: context.l10n.libraryHealthDuplicates,
              description: context.l10n.libraryHealthDuplicatesDescription,
              items: report.duplicates,
              tile: (group) => ListTile(
                dense: true,
                title: Text(
                  "${group.first.name} · ${group.first.albumArtist ?? group.first.artists?.firstOrNull ?? ""}",
                ),
                subtitle: Text(group.map((track) => "${track.album ?? "?"} (${_bitrate(track)})").join("\n")),
                onTap: () => _openAlbumOf(group.first),
              ),
            ),
            _section<BaseItemDto>(
              icon: TablerIcons.chart_bar_off,
              title: context.l10n.libraryHealthLowQuality,
              description: context.l10n.libraryHealthLowQualityDescription(LibraryHealthService.lowBitrate ~/ 1000),
              items: report.lowQuality,
              tile: (track) => ListTile(
                dense: true,
                title: Text(track.name ?? ""),
                subtitle: Text("${track.albumArtist ?? ""} · ${track.album ?? ""} · ${_bitrate(track)}"),
                onTap: () => _openAlbumOf(track),
              ),
            ),
            _section<BaseItemDto>(
              icon: TablerIcons.photo_off,
              title: context.l10n.libraryHealthNoArtwork,
              description: context.l10n.libraryHealthNoArtworkDescription,
              items: report.albumsWithoutArtwork,
              tile: (album) => ListTile(
                dense: true,
                title: Text(album.name ?? ""),
                subtitle: Text(album.albumArtist ?? ""),
                onTap: () => openItemPage(album, Navigator.of(context)),
              ),
            ),
            _section<({BaseItemDto album, Set<MissingTag> missing})>(
              icon: TablerIcons.tag_off,
              title: context.l10n.libraryHealthMissingTags,
              description: context.l10n.libraryHealthMissingTagsDescription,
              items: report.albumsMissingTags,
              tile: (entry) => ListTile(
                dense: true,
                title: Text(entry.album.name ?? ""),
                subtitle: Text(context.l10n.libraryHealthMissing(_missing(entry.missing))),
                onTap: () => openItemPage(entry.album, Navigator.of(context)),
              ),
            ),
            if (_audioError != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  context.l10n.libraryHealthAudioFailed(_audioError.toString()),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (_audio case final audio?) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text(context.l10n.libraryHealthAudio, style: Theme.of(context).textTheme.titleMedium),
              ),
              if (!audio.health.complete)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(context.l10n.libraryHealthAudioPartial, style: Theme.of(context).textTheme.bodySmall),
                ),
              _section<({String id, String reason})>(
                icon: TablerIcons.alert_triangle,
                title: context.l10n.libraryHealthBroken,
                description: context.l10n.libraryHealthBrokenDescription,
                items: audio.health.broken,
                tile: (item) => _audioTile(item.id, item.reason),
              ),
              _section<({String id, double duration, double decoded})>(
                icon: TablerIcons.scissors,
                title: context.l10n.libraryHealthCutOff,
                description: context.l10n.libraryHealthCutOffDescription,
                items: audio.health.cutOff,
                tile: (item) => _audioTile(
                  item.id,
                  context.l10n.libraryHealthCutOffDetail(_time(item.decoded), _time(item.duration)),
                ),
              ),
              _section<({String id, double silence, bool hidden})>(
                icon: TablerIcons.volume_off,
                title: context.l10n.libraryHealthSilentEndings,
                description: context.l10n.libraryHealthSilentEndingsDescription,
                items: audio.health.silentEndings,
                tile: (item) => _audioTile(
                  item.id,
                  item.hidden
                      ? context.l10n.libraryHealthHiddenTrack
                      : context.l10n.libraryHealthSilence(item.silence.round()),
                ),
              ),
              _section<List<String>>(
                icon: TablerIcons.fingerprint,
                title: context.l10n.libraryHealthSameRecording,
                description: context.l10n.libraryHealthSameRecordingDescription,
                items: audio.health.duplicates,
                tile: (pair) =>
                    _audioTile(pair.first, [for (final id in pair) audio.tracks[id]?.album ?? "?"].join("\n")),
              ),
            ],
            const SizedBox(height: 24),
          ],
        ],
      ),
    );
  }
}
