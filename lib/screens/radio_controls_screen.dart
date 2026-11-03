import 'dart:async';
import 'package:finamp/components/genre_fit_switch.dart';
import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/analyzer_service.dart';
import 'package:finamp/services/dj_voice_service.dart';
import 'package:finamp/screens/dj_voice_settings_screen.dart';
import 'package:finamp/screens/listening_enhancements_screen.dart';
import 'package:finamp/screens/offline_mixes_screen.dart';
import 'package:finamp/services/artist_spacing.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:finamp/services/jellyfin_api_helper.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:finamp/services/radio_preferences.dart';
import 'package:finamp/services/radio_clock_settings.dart';
import 'package:finamp/services/listenbrainz_discovery_service.dart';
import 'package:finamp/services/radio_service_helper.dart' as radio;
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

class RadioControlsScreen extends StatefulWidget {
  const RadioControlsScreen({super.key});
  static const routeName = '/radio/controls';
  @override
  State<RadioControlsScreen> createState() => _RadioControlsScreenState();
}

class _RadioControlsScreenState extends State<RadioControlsScreen> {
  RadioPreferences _preferences = const RadioPreferences();
  List<RadioStation> _stations = [];
  List<String> _genres = [];
  bool _loading = true, _busy = false, _analyzer = false;
  bool _matchTime = true;
  String? _error;
  StreamSubscription<FinampQueueInfo?>? _queueSubscription;
  QueueService get _queue => GetIt.instance<QueueService>();
  @override
  void initState() {
    super.initState();
    _queueSubscription = _queue.getQueueStream().listen((_) {
      if (mounted) setState(() {});
    });
    _load();
  }

  @override
  void dispose() {
    unawaited(_queueSubscription?.cancel());
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final preferences = await RadioPreferencesStore.load(), stations = await RadioPreferencesStore.stations();
      final matchTime = await RadioClockSettings.load();
      final analyzer = await AnalyzerService.isConfigured();
      List<BaseItemDto> genres = [];
      if (!FinampSettingsHelper.finampSettings.isOffline) {
        try {
          genres =
              await GetIt.instance<JellyfinApiHelper>()
                  .getItems(
                    parentItem: _queue.getQueue().sourceLibrary,
                    includeItemTypes: 'MusicGenre',
                    sortBy: 'SortName',
                    limit: 100,
                  )
                  .timeout(const Duration(seconds: 5)) ??
              [];
        } catch (_) {
          /* Saved genre choices remain editable offline. */
        }
      }
      if (mounted) {
        setState(() {
          _preferences = preferences;
          _matchTime = matchTime;
          _stations = stations;
          _analyzer = analyzer;
          _genres = {...preferences.genres, ...genres.map((g) => g.name).whereType<String>()}.toList()..sort();
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _apply({BaseItemDto? seed}) => _run(() async {
    final wasEnabled = FinampSettingsHelper.finampSettings.radioEnabled;
    await RadioPreferencesStore.save(_preferences);
    await RadioClockSettings.save(_matchTime);
    if (seed != null) FinampSetters.setRadioMode(RadioMode.similar);
    if (FinampSettingsHelper.finampSettings.radioEnabled || seed != null) {
      radio.toggleRadio(true);
      await _queue.retuneRadio(seed: seed, replaceQueued: seed != null && !wasEnabled);
    }
  });
  Future<void> _saveStation() async {
    final queue = _queue.getQueue();
    final seed = queue.source.item ?? queue.currentTrack?.baseItem;
    if (seed == null) return;
    var draftName = seed.name ?? '';
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.radioSaveStation),
        content: TextFormField(
          initialValue: draftName,
          onChanged: (value) => draftName = value,
          autofocus: true,
          maxLength: 60,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(context.l10n.featureCancel)),
          FilledButton(
            onPressed: () {
              if (draftName.trim().isNotEmpty) Navigator.pop(context, draftName.trim());
            },
            child: Text(context.l10n.save),
          ),
        ],
      ),
    );
    if (name == null || !mounted) return;
    await _run(() async {
      final station = RadioPreferencesStore.station(
        name,
        seed,
        FinampSettingsHelper.finampSettings.radioMode,
        _preferences,
      );
      final stations = [..._stations, station];
      await RadioPreferencesStore.writeStations(stations);
      if (mounted) setState(() => _stations = stations);
    });
  }

  Future<void> _play(RadioStation station) => _run(() async {
    final missingMessage = context.l10n.radioStationMissing;
    final items = await GetIt.instance<JellyfinApiHelper>().getItems(itemIds: [station.seed.id]);
    if (items == null || items.isEmpty) throw StateError(missingMessage);
    await RadioPreferencesStore.save(station.preferences);
    if (mounted) setState(() => _preferences = station.preferences);
    final preview = await radio.generateRadioPreview(items.first, radioMode: station.mode);
    await radio.startRadioPlaybackWithTracks(
      items.first,
      station.mode,
      preview.tracks,
      stationId: station.id,
      stationName: station.name,
    );
  });
  @override
  Widget build(BuildContext context) {
    final current = _queue.getCurrentTrack()?.baseItem;
    final artist = current == null ? null : ArtistSpacing.artistKey(current);
    final songMode = FinampSettingsHelper.finampSettings.radioMode != RadioMode.albumMix;
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.radioControls)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_busy) const LinearProgressIndicator(),
                if (_error != null) Padding(padding: const EdgeInsets.all(8), child: Text(_error!)),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(context.l10n.listenBrainzDiscovery),
                  subtitle: Text(context.l10n.listenBrainzDiscoveryHelp),
                  trailing: IconButton(
                    tooltip: context.l10n.listenBrainzDiscoveryStart,
                    icon: const Icon(Icons.travel_explore),
                    onPressed: _busy || FinampSettingsHelper.finampSettings.isOffline
                        ? null
                        : () => _run(() async {
                            final name = context.l10n.listenBrainzDiscovery;
                            try {
                              await ListenBrainzDiscoveryService.play(
                                name: name,
                                seed: _queue.getCurrentTrack()?.baseItem,
                              );
                            } on ListenBrainzDiscoveryException catch (error) {
                              if (mounted) {
                                setState(
                                  () => _error = switch (error.reason) {
                                    ListenBrainzDiscoveryFailure.connect => context.l10n.listenBrainzConnectFirst,
                                    ListenBrainzDiscoveryFailure.noRecommendations =>
                                      context.l10n.listenBrainzNoRecommendations,
                                    ListenBrainzDiscoveryFailure.noMatches => context.l10n.listenBrainzNoMatches,
                                    ListenBrainzDiscoveryFailure.unavailable =>
                                      context.l10n.listenBrainzDiscoveryFailed,
                                  },
                                );
                              }
                            }
                          }),
                  ),
                ),
                const Divider(),
                OutlinedButton.icon(
                  icon: const Icon(Icons.download),
                  label: Text(context.l10n.offlineMixDownload),
                  onPressed: _busy || FinampSettingsHelper.finampSettings.isOffline || current == null
                      ? null
                      : () => Navigator.of(context).push(
                          MaterialPageRoute<void>(builder: (_) => const OfflineMixesScreen(createFromQueue: true)),
                        ),
                ),
                Text(
                  '${context.l10n.radioDiscovery}: ${_preferences.discovery}%',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                Text(songMode ? context.l10n.radioDiscoveryHelp : context.l10n.radioAlbumControlsHelp),
                Slider(
                  value: _preferences.discovery.toDouble(),
                  min: 0,
                  max: 100,
                  divisions: 20,
                  label: '${_preferences.discovery}%',
                  onChanged: _busy || !songMode
                      ? null
                      : (v) => setState(() => _preferences = _preferences.copyWith(discovery: v.round())),
                ),
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: Text(context.l10n.radioGenres),
                  subtitle: _preferences.genres.isEmpty
                      ? null
                      : Text(_preferences.genres.join(', '), maxLines: 2, overflow: TextOverflow.ellipsis),
                  children: [
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final genre in _genres)
                          FilterChip(
                            label: Text(genre),
                            selected: _preferences.genres.contains(genre),
                            onSelected: _busy
                                ? null
                                : (selected) => setState(
                                    () => _preferences = _preferences.copyWith(
                                      genres: selected
                                          ? [..._preferences.genres, genre]
                                          : _preferences.genres.where((g) => g != genre).toList(),
                                    ),
                                  ),
                          ),
                      ],
                    ),
                    const GenreFitSwitch(),
                  ],
                ),
                const SizedBox(height: 12),
                Text(context.l10n.radioEnergy, style: Theme.of(context).textTheme.titleMedium),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final value in [-1, 0, 1])
                      ChoiceChip(
                        label: Text(
                          value < 0
                              ? context.l10n.radioCalmer
                              : value > 0
                              ? context.l10n.radioMoreEnergy
                              : context.l10n.radioAnyEnergy,
                        ),
                        selected: _preferences.energy == value,
                        onSelected: _busy || !songMode || (!_analyzer && value != 0)
                            ? null
                            : (_) => setState(() => _preferences = _preferences.copyWith(energy: value)),
                      ),
                  ],
                ),
                if (!_analyzer) Text(context.l10n.radioEnergyHelp),
                const SizedBox(height: 12),
                FilledButton(onPressed: _busy ? null : () => _apply(), child: Text(context.l10n.radioApply)),
                OutlinedButton(
                  onPressed: _busy || current == null
                      ? null
                      : () {
                          final seed = _queue.getCurrentTrack()?.baseItem;
                          if (seed != null) _apply(seed: seed);
                        },
                  child: Text(context.l10n.radioMoreLikeThis),
                ),
                OutlinedButton(
                  onPressed: _busy || artist == null
                      ? null
                      : () {
                          final track = _queue.getCurrentTrack()?.baseItem;
                          final artist = track == null ? null : ArtistSpacing.artistKey(track);
                          if (artist == null) return;
                          setState(
                            () => _preferences = _preferences.copyWith(
                              excludedArtists: {..._preferences.excludedArtists, artist}.toList(),
                            ),
                          );
                          _apply();
                        },
                  child: Text(context.l10n.radioLessArtist),
                ),
                if (_preferences.excludedArtists.isNotEmpty)
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => setState(() => _preferences = _preferences.copyWith(excludedArtists: [])),
                    child: Text(context.l10n.radioResetArtists),
                  ),
                TextButton.icon(
                  icon: const Icon(Icons.block),
                  label: Text(context.l10n.radioBlockedArtists),
                  onPressed: () => Navigator.of(context).pushNamed(ListeningEnhancementsScreen.routeName),
                ),
                const Divider(),
                Row(
                  children: [
                    Expanded(child: Text(context.l10n.radioStations, style: Theme.of(context).textTheme.titleLarge)),
                    IconButton(
                      tooltip: context.l10n.radioSaveStation,
                      onPressed: _busy ? null : _saveStation,
                      icon: const Icon(Icons.add),
                    ),
                  ],
                ),
                if (_stations.isEmpty) Text(context.l10n.radioStationsEmpty),
                for (final station in _stations)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(station.name),
                    subtitle: Text(
                      '${station.seed.name ?? ''} · ${context.l10n.radioModeOptionName(station.mode.name)}',
                    ),
                    onTap: _busy || FinampSettingsHelper.finampSettings.isOffline ? null : () => _play(station),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: context.l10n.djVoice,
                          icon: const Icon(Icons.record_voice_over),
                          onPressed: _busy
                              ? null
                              : () => Navigator.of(context).push(
                                  MaterialPageRoute<void>(
                                    builder: (_) =>
                                        DjVoiceSettingsScreen(stationId: station.id, stationName: station.name),
                                  ),
                                ),
                        ),
                        IconButton(
                          tooltip: context.l10n.featureRemove,
                          icon: const Icon(Icons.delete_outline),
                          onPressed: _busy
                              ? null
                              : () => _run(() async {
                                  final stations = _stations.where((s) => s.id != station.id).toList();
                                  await RadioPreferencesStore.writeStations(stations);
                                  await DjVoiceService.clearStationProfile(station.id);
                                  if (mounted) setState(() => _stations = stations);
                                }),
                        ),
                      ],
                    ),
                  ),
                const Divider(),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(context.l10n.radioMatchTimeOfDay),
                  subtitle: Text(context.l10n.radioMatchTimeOfDayHelp),
                  value: _matchTime,
                  onChanged: _busy || !songMode
                      ? null
                      : (value) async {
                          setState(() => _matchTime = value);
                          await _apply();
                        },
                ),
              ],
            ),
    );
  }
}
