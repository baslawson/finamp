import 'dart:async';
import 'dart:math';

import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/current_track_metadata_provider.dart';
import 'package:finamp/services/music_player_background_task.dart';
import 'package:finamp/services/karaoke_service.dart';
import 'package:finamp/services/lyrics_timeline.dart';
import 'package:finamp/services/karaoke_practice.dart';
import 'package:finamp/screens/karaoke_dashboard_screen.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:finamp/screens/analyzer_settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// Timing helpers for karaoke, kept free of widgets so they can be tested.
class KaraokeTiming {
  KaraokeTiming._();

  static const _ticksPerSecond = 10000000;

  /// The line being sung at [position] (in ticks), or -1 before the first one.
  static int lineAt(List<LyricLine> lines, int position) {
    var index = -1;
    for (var i = 0; i < lines.length; i++) {
      final start = lines[i].start;
      if (start != null && start <= position) index = i;
    }
    return index;
  }

  /// How many characters of [line] have been sung at [position]. Uses word timings when the lyrics have them,
  /// otherwise spreads the line over the time it's likely sung in (lines are often followed by a pause).
  static int sungCharacters(LyricLine line, LyricLine? next, int position) {
    final text = line.text ?? "";
    final start = line.start;
    if (start == null || text.isEmpty || position < start) return 0;
    final cues = line.cues;
    if (cues != null && cues.isNotEmpty) {
      var sung = 0;
      for (var i = 0; i < cues.length; i++) {
        final cue = cues[i];
        if (cue.start > position) break;
        final end = cue.endPosition ?? (i + 1 < cues.length ? cues[i + 1].position : text.length);
        final cueEnd = i + 1 < cues.length ? cues[i + 1].start : (next?.start ?? cue.start + _ticksPerSecond);
        final fraction = cueEnd <= cue.start ? 1.0 : ((position - cue.start) / (cueEnd - cue.start)).clamp(0.0, 1.0);
        sung = cue.position + ((end - cue.position) * fraction).round();
      }
      return sung.clamp(0, text.length);
    }
    final gap = (next?.start ?? start + 5 * _ticksPerSecond) - start;
    final singing = min(gap * 0.9, (text.length * 0.11 + 0.4) * _ticksPerSecond);
    final fraction = singing <= 0 ? 1.0 : ((position - start) / singing).clamp(0.0, 1.0);
    return (text.length * fraction).round();
  }
}

/// Lyrics and playback for instrumentals prepared by the server.
class KaraokeScreen extends ConsumerStatefulWidget {
  const KaraokeScreen({super.key, this.initialGuide = 0, this.initialPart = KaraokePart.vocals, this.service});
  final int initialGuide;
  final KaraokePart initialPart;
  final KaraokeService? service;

  static const routeName = "/karaoke";

  @override
  ConsumerState<KaraokeScreen> createState() => _KaraokeScreenState();
}

class _KaraokeScreenState extends ConsumerState<KaraokeScreen> with SingleTickerProviderStateMixin {
  late final _service = widget.service ?? KaraokeService.instance;
  late final Ticker _ticker;
  late final KaraokePractice _practice;
  bool _reduceGuide = false;
  Timer? _poll;
  int _position = 0;
  int _guide = 0, _generation = 0;
  int _appliedGuide = 0;
  late KaraokePart _part = widget.initialPart;

  /// Whether the guide is drums, which it is whenever the drums are taken out.
  bool get _drums => _part != KaraokePart.vocals;

  /// Whether the player has the mix chosen here, rather than another part or guide level. A saved song keeps its
  /// mix after switching, so this asks the player instead of remembering.
  bool get _playingChosenPart {
    final path = _player.karaokeMixPath, job = _job;
    if (!_player.karaokeActive || path == null || job == null || !job.ready) return false;
    return path.replaceAll('\\', '/').split('/').last == KaraokeService.mixName(job, _guide);
  }

  double? _seekPreview;
  String? _song, _queueId, _error;
  KaraokeJob? _job;
  LyricDto? _savedLyrics;
  List<int> _available = [];
  bool _busy = false, _checking = false, _saved = false, _leaving = false;
  MusicPlayerBackgroundTask get _player => GetIt.instance<MusicPlayerBackgroundTask>();
  bool get _offline => FinampSettingsHelper.finampSettings.isOffline;

  @override
  void initState() {
    super.initState();
    final queue = GetIt.instance<QueueService>();
    _practice = KaraokePractice(
      seek: _player.seek,
      setSpeed: _player.setSpeed,
      setPitch: _player.setPitch,
      originalSpeed: queue.playbackSpeed,
      originalPitch: queue.playbackPitch,
    );
    _ticker = createTicker((_) {
      final player = GetIt.instance<MusicPlayerBackgroundTask>();
      final position = player.playbackPosition.inMicroseconds * 10;
      if (position != _position) setState(() => _position = position);
      if (player.karaokeActive && !_busy && !_leaving) {
        final generation = _generation;
        unawaited(
          _practice
              .tick(player.playbackPosition, playing: player.playbackState.value.playing)
              .then<void>((looped) {
                if (!mounted || generation != _generation || !looped || !_reduceGuide || _guide == 0) return;
                final levels = KaraokeService.guideLevels
                    .where((level) => level < _guide && (!_offline || _available.contains(level)))
                    .toList();
                if (levels.isEmpty) return;
                setState(() => _guide = levels.last);
                unawaited(_useMix(startPlayback: true));
              })
              .catchError((Object error) {
                if (mounted) {
                  setState(() {
                    _practice.enabled = false;
                    _error = '$error';
                  });
                }
              }),
        );
      }
    })..start();
    // Keeping the screen on is a convenience; karaoke works without it.
    unawaited(WakelockPlus.enable().catchError((Object _) {}));
    _poll = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_job?.waiting ?? false) unawaited(_check());
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadCurrent());
  }

  @override
  void dispose() {
    _ticker.dispose();
    _generation++;
    _poll?.cancel();
    unawaited(_practice.close().catchError((Object _) {}));
    unawaited(WakelockPlus.disable().catchError((Object _) {}));
    if (!_leaving && _queueId != null) {
      unawaited(_player.setKaraokeMix(queueId: _queueId!).catchError((Object _) {}));
    }
    super.dispose();
  }

  void _loadCurrent() {
    final track = GetIt.instance<QueueService>().getCurrentTrack();
    if (track == null || track.id == _queueId) return;
    final previous = _queueId;
    if (previous != null) {
      unawaited(
        _practice.reset().catchError((Object error) {
          if (mounted) setState(() => _error = '$error');
        }),
      );
    }
    _generation++;
    setState(() {
      _queueId = track.id;
      _song = track.baseItem.id.raw;
      _job = null;
      _error = null;
      _savedLyrics = null;
      _saved = false;
      _available = [];
      _guide = previous == null ? widget.initialGuide : 0;
      _appliedGuide = _guide;
    });
    if (previous != null) unawaited(_player.setKaraokeMix(queueId: previous).catchError((Object _) {}));
    unawaited(_check());
  }

  /// Takes the other part out of the song. The current mix pauses until that version is played.
  void _choosePart(KaraokePart part) {
    if (part == _part || _busy || _leaving) return;
    _generation++;
    setState(() {
      _part = part;
      _job = null;
      _error = null;
      _saved = false;
      _available = [];
      _guide = 0;
      _appliedGuide = 0;
    });
    if (_player.karaokeActive && _player.playbackState.value.playing) unawaited(_player.pause());
    unawaited(_check());
  }

  Future<void> _check({bool prepare = false}) async {
    if (_checking || _song == null) return;
    setState(() => _checking = true);
    final song = _song!, generation = _generation, part = _part;
    try {
      final job = prepare
          ? await _service.prepare(song, part: part)
          : await _service.status(song, offline: _offline, part: part);
      final lyrics = await _service.savedLyrics(song);
      final available = job.ready ? await _service.availableGuides(song, job) : <int>[];
      final saved = job.ready && await _service.localMix(song, job, _guide, onlyOffline: true) != null;
      if (!mounted || generation != _generation) return;
      setState(() {
        _job = job;
        _error = null;
        _savedLyrics = lyrics;
        _available = available;
        _saved = saved;
        if (_offline && !available.contains(_guide) && available.isNotEmpty) _guide = available.first;
      });
    } catch (error) {
      if (mounted && generation == _generation) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _checking = false);
      if (mounted && generation != _generation) unawaited(_check());
    }
  }

  Future<void> _useMix({bool saveOnly = false, bool startPlayback = true}) async {
    if (_busy || _job?.ready != true || _song == null || _queueId == null) return;
    final song = _song!, job = _job!, queueId = _queueId!, guide = _guide, generation = _generation;
    final previousGuide = _appliedGuide;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final file = await _service.download(song, job, guide, keepOffline: saveOnly, offline: _offline);
      if (!mounted || generation != _generation || _leaving) return;
      // The song's own timings: a mashup playing shows them moved to its audio.
      final shown = ref.read(currentTrackMetadataProvider).valueOrNull;
      final lyrics = shown?.originalLyrics ?? shown?.lyrics;
      if (lyrics != null) await _service.saveLyrics(song, lyrics);
      if (!mounted || generation != _generation || _leaving) return;
      if (saveOnly) {
        final track = GetIt.instance<QueueService>().getCurrentTrack();
        final item = track?.baseItem;
        // As the song itself, even while a mashup of it plays under its own title.
        final original = item == null ? null : LyricsTimeline.of(track!)?.original(item) ?? item;
        if (original != null) await _service.saveOfflineDetails(original, lyrics ?? _savedLyrics);
      }
      if (!saveOnly) {
        await _player.setKaraokeMix(queueId: queueId, file: file, measurement: job.measurement(guide));
        if (!mounted || generation != _generation || _leaving) return;
        _appliedGuide = guide;
        if (mounted && generation == _generation && !_leaving && startPlayback) unawaited(_player.play());
      }
      final available = await _service.availableGuides(song, job);
      final saved = await _service.localMix(song, job, guide, onlyOffline: true) != null;
      if (mounted && generation == _generation) {
        setState(() {
          _available = available;
          _saved = saved;
        });
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _error = error.toString();
          if (!saveOnly && _player.karaokeActive) _guide = previousGuide;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _exit() async {
    if (_leaving) return;
    setState(() => _leaving = true);
    try {
      await _practice.close();
      if (_queueId != null) await _player.setKaraokeMix(queueId: _queueId!);
      await WidgetsBinding.instance.endOfFrame;
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      _leaving = false;
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Widget _controls(BuildContext context) {
    final ready = _job?.ready ?? false, waiting = _job?.waiting ?? false;
    return Flexible(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                // Three segments can be wider than a small phone; shrink them rather than overflow.
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: SegmentedButton<KaraokePart>(
                    style: SegmentedButton.styleFrom(
                      foregroundColor: Colors.white70,
                      selectedForegroundColor: Colors.black,
                      selectedBackgroundColor: Colors.white,
                    ),
                    segments: [
                      ButtonSegment(
                        value: KaraokePart.vocals,
                        icon: const Icon(TablerIcons.microphone_2),
                        label: Text(context.l10n.karaokeRemoveVocals),
                      ),
                      ButtonSegment(
                        value: KaraokePart.drums,
                        icon: const Icon(TablerIcons.metronome),
                        label: Text(context.l10n.karaokeRemoveDrums),
                      ),
                      ButtonSegment(
                        value: KaraokePart.both,
                        icon: const Icon(TablerIcons.guitar_pick),
                        label: Text(context.l10n.karaokeRemoveBoth),
                        tooltip: context.l10n.karaokeBackingOnly,
                      ),
                    ],
                    selected: {_part},
                    onSelectionChanged: _busy || _leaving ? null : (parts) => _choosePart(parts.single),
                  ),
                ),
              ),
              if (_job?.state == KaraokeState.failed)
                Text(
                  _job?.message ?? context.l10n.karaokeOfflineMissing,
                  style: const TextStyle(color: Colors.orangeAccent),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.orangeAccent),
                  ),
                ),
              if (_busy || waiting || (_checking && _job == null)) const LinearProgressIndicator(),
              if (waiting)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(
                    _job?.message ??
                        switch (_part) {
                          KaraokePart.vocals => context.l10n.karaokePreparing,
                          KaraokePart.drums => context.l10n.karaokePreparingDrums,
                          KaraokePart.both => context.l10n.karaokePreparingBoth,
                        },
                    style: const TextStyle(color: Colors.white70),
                  ),
                ),
              if (!ready && !waiting) ...[
                Text(
                  switch (_part) {
                    KaraokePart.vocals => context.l10n.karaokeServerDescription,
                    KaraokePart.drums => context.l10n.karaokeDrumsServerDescription,
                    KaraokePart.both => context.l10n.karaokeBothServerDescription,
                  },
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70),
                ),
                FilledButton.icon(
                  onPressed: _offline || _checking || _song == null ? null : () => _check(prepare: true),
                  icon: Icon(_drums ? TablerIcons.metronome : TablerIcons.microphone_2),
                  label: Text(switch (_part) {
                    KaraokePart.vocals => context.l10n.karaokePrepare,
                    KaraokePart.drums => context.l10n.karaokePrepareDrums,
                    KaraokePart.both => context.l10n.karaokePrepareBoth,
                  }),
                ),
                if (_offline) Text(context.l10n.karaokeOfflineMissing, style: const TextStyle(color: Colors.white70)),
                TextButton(
                  onPressed: () async {
                    await Navigator.of(context).pushNamed(AnalyzerSettingsScreen.routeName);
                    await _check();
                  },
                  child: Text(context.l10n.karaokeServerSettings),
                ),
              ],
              if (ready) ...[
                ExpansionTile(
                  title: Text(context.l10n.karaokePractice),
                  textColor: Colors.white,
                  collapsedTextColor: Colors.white,
                  children: [
                    Text(context.l10n.karaokeLoopHelp, style: const TextStyle(color: Colors.white70)),
                    Wrap(
                      spacing: 8,
                      children: [
                        TextButton(
                          onPressed: !_player.karaokeActive || _busy
                              ? null
                              : () => setState(() => _practice.markA(_player.playbackPosition)),
                          child: Text(
                            '${context.l10n.karaokeMarkA}${_practice.a == null ? '' : ' ${_practice.a!.inSeconds}s'}',
                          ),
                        ),
                        TextButton(
                          onPressed: !_player.karaokeActive || _busy
                              ? null
                              : () {
                                  try {
                                    setState(() => _practice.markB(_player.playbackPosition));
                                  } catch (_) {
                                    setState(() => _error = context.l10n.karaokeLoopInvalid);
                                  }
                                },
                          child: Text(
                            '${context.l10n.karaokeMarkB}${_practice.b == null ? '' : ' ${_practice.b!.inSeconds}s'}',
                          ),
                        ),
                      ],
                    ),
                    SwitchListTile(
                      title: Text(context.l10n.karaokeLoop, style: const TextStyle(color: Colors.white)),
                      value: _practice.enabled,
                      onChanged: _practice.a == null || _practice.b == null || _busy
                          ? null
                          : (v) => setState(() => _practice.enabled = v),
                    ),
                    SwitchListTile(
                      title: Text(
                        _drums ? context.l10n.karaokeReduceGuideDrums : context.l10n.karaokeReduceGuide,
                        style: const TextStyle(color: Colors.white),
                      ),
                      value: _reduceGuide,
                      onChanged: (v) => setState(() => _reduceGuide = v),
                    ),
                    DropdownButton<double>(
                      value: _practice.speed,
                      dropdownColor: Colors.black,
                      style: const TextStyle(color: Colors.white),
                      items: ({.5, .65, .75, .85, 1.0, 1.15, 1.25, _practice.speed}.toList()..sort())
                          .map((v) => DropdownMenuItem(value: v, child: Text('${context.l10n.karaokeSpeed}: ${v}x')))
                          .toList(),
                      onChanged: !_player.karaokeActive || _busy
                          ? null
                          : (v) async {
                              if (v == null) return;
                              try {
                                await _practice.changeSpeed(v);
                                if (mounted) setState(() {});
                              } catch (error) {
                                if (mounted) setState(() => _error = '$error');
                              }
                            },
                    ),
                  ],
                ),
                Row(
                  children: [
                    Text(
                      _drums ? context.l10n.karaokeGuideDrums : context.l10n.karaokeGuideVocals,
                      style: const TextStyle(color: Colors.white70),
                    ),
                    Expanded(
                      child: Slider(
                        value: _guide.toDouble(),
                        min: 0,
                        max: 100,
                        divisions: 4,
                        onChanged: _busy
                            ? null
                            : (value) => setState(() {
                                _guide = value.round();
                                _saved = false;
                              }),
                        onChangeEnd: (_) {
                          if (_player.karaokeActive) {
                            unawaited(_useMix(startPlayback: _player.playbackState.value.playing));
                          } else {
                            unawaited(_check());
                          }
                        },
                      ),
                    ),
                    Text('$_guide%', style: const TextStyle(color: Colors.white70)),
                  ],
                ),
                if (_offline)
                  Text(
                    _drums
                        ? context.l10n.karaokeOfflineDrumMixes(_available.join(', '))
                        : context.l10n.karaokeOfflineMixes(_available.join(', ')),
                    style: const TextStyle(color: Colors.white70),
                  ),
                TextButton.icon(
                  onPressed: _busy || _saved || (_offline && !_available.contains(_guide))
                      ? null
                      : () => _useMix(saveOnly: true),
                  icon: Icon(_saved ? TablerIcons.check : TablerIcons.download),
                  label: Text(_saved ? context.l10n.karaokeSaved : context.l10n.karaokeSaveOffline),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(currentTrackProvider, (_, _) => _loadCurrent());
    final metadata = ref.watch(currentTrackMetadataProvider).valueOrNull;
    var lyrics = metadata?.lyrics;
    final track = ref.watch(currentTrackProvider).value;
    if (lyrics == null && _savedLyrics != null && track != null && LyricsTimeline.of(track) != null) {
      // The saved lyrics keep the song's own timings; a mashup playing moves them to its audio.
      ref.watch(karaokeMixChangesProvider);
      final playing = GetIt.instance<MusicPlayerBackgroundTask>().karaokeMixPathFor(track);
      lyrics = LyricsTimeline.playing(track, playing)?.apply(_savedLyrics!);
    }
    final lines = (lyrics ?? _savedLyrics)?.lyrics ?? const <LyricLine>[];
    final synced = lines.isNotEmpty && lines.first.start != null;
    final theme = Theme.of(context);
    // The theme colour brightened, so it stands out on the black background.
    final accent = HSLColor.fromColor(theme.colorScheme.primary).withLightness(0.68).toColor();
    final player = GetIt.instance<MusicPlayerBackgroundTask>();

    final current = synced ? KaraokeTiming.lineAt(lines, _position) : -1;
    Widget line(int index, {required double size, required double opacity}) {
      if (index < 0 || index >= lines.length) return SizedBox(height: size * 1.4);
      final text = lines[index].text ?? "";
      final sung = index == current
          ? KaraokeTiming.sungCharacters(lines[index], index + 1 < lines.length ? lines[index + 1] : null, _position)
          : (index < current ? text.length : 0);
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: text.substring(0, sung),
                style: TextStyle(color: accent.withValues(alpha: opacity)),
              ),
              TextSpan(
                text: text.substring(sung),
                style: TextStyle(color: Colors.white.withValues(alpha: opacity * 0.85)),
              ),
            ],
          ),
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: size, fontWeight: FontWeight.w800, height: 1.2),
        ),
      );
    }

    return PopScope(
      canPop: _leaving,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_exit());
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          leading: BackButton(onPressed: _exit),
          actions: [
            IconButton(
              tooltip: context.l10n.karaokeDashboard,
              icon: const Icon(Icons.queue_music),
              onPressed: () async {
                final navigator = Navigator.of(context);
                await _exit();
                if (_leaving && navigator.mounted) {
                  await navigator.push(MaterialPageRoute<void>(builder: (_) => const KaraokeDashboardScreen()));
                }
              },
            ),
          ],
          title: Text(
            metadata?.item.name ?? player.mediaItem.valueOrNull?.title ?? context.l10n.karaoke,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: !synced
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            _drums ? context.l10n.karaokeDrumAlong : context.l10n.karaokeNeedsSyncedLyrics,
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.white70, fontSize: 18),
                          ),
                        ),
                      )
                    : SingleChildScrollView(
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            children: [
                              line(current - 1, size: 20, opacity: .35),
                              line(current, size: 34, opacity: 1),
                              line(current + 1, size: 24, opacity: .55),
                              line(current + 2, size: 20, opacity: .3),
                            ],
                          ),
                        ),
                      ),
              ),
              _controls(context),
              StreamBuilder(
                stream: player.playbackState,
                builder: (context, snapshot) {
                  final playing = snapshot.data?.playing ?? false;
                  final duration = player.playerDuration ?? Duration.zero;
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton.filled(
                        iconSize: 36,
                        onPressed: _busy || _job?.ready != true || (_offline && !_available.contains(_guide))
                            ? null
                            : () async {
                                if (_playingChosenPart) {
                                  if (playing) {
                                    await player.pause();
                                  } else {
                                    unawaited(player.play());
                                  }
                                } else {
                                  await _useMix();
                                }
                              },
                        tooltip: switch (_part) {
                          KaraokePart.vocals => context.l10n.karaokePlay,
                          KaraokePart.drums => context.l10n.karaokePlayDrums,
                          KaraokePart.both => context.l10n.karaokePlayBoth,
                        },
                        icon: Icon(_playingChosenPart && playing ? TablerIcons.player_pause : TablerIcons.player_play),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Slider(
                          value: (_seekPreview ?? player.playbackPosition.inMilliseconds.toDouble()).clamp(
                            0,
                            max(1, duration.inMilliseconds).toDouble(),
                          ),
                          min: 0,
                          max: max(1, duration.inMilliseconds).toDouble(),
                          onChanged: duration > Duration.zero && !_busy
                              ? (value) => setState(() => _seekPreview = value)
                              : null,
                          onChangeEnd: (value) async {
                            setState(() => _seekPreview = null);
                            try {
                              await player.seek(Duration(milliseconds: value.round()));
                            } catch (error) {
                              if (mounted) setState(() => _error = error.toString());
                            }
                          },
                        ),
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}
