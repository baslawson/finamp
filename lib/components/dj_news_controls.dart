import 'dart:async';
import 'dart:io';

import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/l10n/app_localizations.dart';
import 'package:finamp/services/dj_audio_import.dart';
import 'package:finamp/services/dj_news.dart';
import 'package:finamp/services/dj_news_sting.dart';
import 'package:finamp/services/dj_recordings.dart';
import 'package:finamp/services/dj_voice_service.dart';
import 'package:flutter/material.dart';

typedef _Chimes = ({
  String chosen,
  ({String chime, int chance}) second,
  ({int chance, int under}) talk,
  bool own,
  List<DjSound> sounds,
});

/// Whether the DJ reads news headlines, when, from which feed, and how many.
class DjNewsControls extends StatefulWidget {
  const DjNewsControls({super.key});

  @override
  State<DjNewsControls> createState() => _DjNewsControlsState();
}

class _DjNewsControlsState extends State<DjNewsControls> {
  DjNewsSettings? _settings;
  final _custom = TextEditingController();
  final _secondCustom = TextEditingController();

  /// What checking the feed found: its first headlines, or that it couldn't be read.
  String? _check;
  bool _checking = false;

  /// The chimes chosen (primary and secondary, and how often the secondary plays), whether the listener imported one
  /// of their own, and the sounds that come with the app, once known.
  _Chimes? _chime;
  bool _chimeBusy = false;
  double? _secondDrag, _talkDrag, _underDrag;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    unawaited(_loadChime());
  }

  static Future<_Chimes> _readChime() async => (
    chosen: await DjNewsSting.chosen(),
    second: await DjNewsSting.secondary(),
    talk: await DjNewsSting.talkOver(),
    own: await DjNewsSting.isOwn(),
    sounds: await DjSounds.all(),
  );

  Future<void> _loadChime() async {
    final chime = await _readChime();
    if (mounted) setState(() => _chime = chime);
  }

  /// Runs [task] on the chime, then shows which chime is in use; an error goes to a snackbar.
  Future<void> _onChime(Future<void> Function() task) async {
    if (_chimeBusy) return;
    setState(() => _chimeBusy = true);
    try {
      await task();
    } catch (error) {
      if (mounted) GlobalSnackbar.error(error);
    } finally {
      final chime = await _readChime();
      if (mounted) {
        setState(() {
          _chime = chime;
          _chimeBusy = false;
        });
      }
    }
  }

  Future<void> _importChime() => _onChime(() async {
    final formatMessage = context.l10n.djNewsChimeFormat;
    final bytes = await DjAudioImport.pick(formatMessage);
    if (bytes == null) return;
    try {
      await DjNewsSting.import(bytes);
    } on FormatException {
      throw FormatException(formatMessage);
    }
  });

  Future<void> _previewChime(String choice) => _onChime(() async {
    final recording = await DjNewsSting.sound(choice);
    if (recording == null) return;
    final temp = await Directory.systemTemp.createTemp('finamp-chime-preview-');
    try {
      final copy = await File('${temp.path}/chime.wav').writeAsBytes(recording);
      await DjVoiceService.previewRecording(
        DjAudioClip(copy, ''),
        profile: DjVoiceService.effectiveProfile,
        replayable: false,
      );
    } finally {
      await temp.delete(recursive: true).catchError((_) => temp);
    }
  });

  /// The choice of a chime ([secondary] also offers none), with a button to hear it.
  Widget _chimeChoice(
    _Chimes chime, {
    required String label,
    required String value,
    required Future<void> Function(String) choose,
    bool secondary = false,
  }) {
    final l10n = context.l10n;
    return Row(
      children: [
        Expanded(
          child: DropdownButtonFormField<String>(
            key: ValueKey((label, chime)),
            initialValue: value,
            isExpanded: true,
            decoration: InputDecoration(labelText: label),
            items: [
              if (secondary) DropdownMenuItem(value: DjNewsSting.none, child: Text(l10n.djJingleNone)),
              DropdownMenuItem(value: DjNewsSting.bells, child: Text(l10n.djNewsChimeBells)),
              for (final sound in chime.sounds) DropdownMenuItem(value: sound.id, child: Text(sound.name)),
              if (chime.own) DropdownMenuItem(value: DjNewsSting.own, child: Text(l10n.djNewsChimeOwn)),
            ],
            onChanged: _chimeBusy
                ? null
                : (choice) {
                    if (choice != null) unawaited(_onChime(() => choose(choice)));
                  },
          ),
        ),
        IconButton(
          tooltip: l10n.djNewsChimePreview,
          onPressed: _chimeBusy || value == DjNewsSting.none ? null : () => _previewChime(value),
          icon: const Icon(Icons.play_arrow),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _custom.dispose();
    _secondCustom.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final settings = await DjNews.settings();
    if (!mounted) return;
    setState(() {
      _settings = settings;
      _custom.text = settings.custom;
      _secondCustom.text = settings.secondCustom;
    });
  }

  Future<void> _save({
    DjNewsMode? mode,
    DjNewsFeed? feed,
    String? custom,
    DjNewsFeed? second,
    bool noSecond = false,
    String? secondCustom,
    int? count,
    bool? gentle,
    bool? pause,
    bool? detail,
    DjNewsStyle? style,
    bool? sting,
  }) async {
    await DjNews.save(
      mode: mode,
      feed: feed,
      custom: custom,
      second: second,
      noSecond: noSecond,
      secondCustom: secondCustom,
      count: count,
      gentle: gentle,
      pause: pause,
      detail: detail,
      style: style,
      sting: sting,
    );
    final settings = await DjNews.settings();
    if (!mounted) return;
    setState(() {
      if (feed != null || custom != null || second != null || noSecond || secondCustom != null) _check = null;
      _settings = settings;
    });
    if (mode != null && mode != DjNewsMode.off) DjNews.prefetch();
  }

  Future<void> _checkFeed() async {
    final l10n = context.l10n;
    setState(() => _checking = true);
    final hasSecond = _settings?.second != null;
    final (headlines, local) = await (
      DjNews.headlines(),
      hasSecond ? DjNews.headlines(second: true) : Future.value(const <String>[]),
    ).wait;
    if (!mounted) return;
    String found(List<String> headlines) =>
        headlines.isEmpty ? l10n.djNewsCheckFailed : headlines.take(3).map((headline) => "• $headline").join("\n");
    setState(() {
      _checking = false;
      _check = [found(headlines), if (hasSecond) "${l10n.djNewsCheckLocal}\n${found(local)}"].join("\n\n");
    });
  }

  static String _feedName(AppLocalizations l10n, DjNewsFeed feed) => switch (feed) {
    DjNewsFeed.bbcWorld => l10n.djNewsFeedBbcWorld,
    DjNewsFeed.bbcUk => l10n.djNewsFeedBbcUk,
    DjNewsFeed.bbcAustralia => l10n.djNewsFeedBbcAustralia,
    DjNewsFeed.guardianWorld => l10n.djNewsFeedGuardianWorld,
    DjNewsFeed.nprWorld => l10n.djNewsFeedNprWorld,
    DjNewsFeed.alJazeera => l10n.djNewsFeedAlJazeera,
    DjNewsFeed.abcAustralia => l10n.djNewsFeedAbcAustralia,
    DjNewsFeed.bbcEngland => l10n.djNewsFeedBbcEngland,
    DjNewsFeed.bbcScotland => l10n.djNewsFeedBbcScotland,
    DjNewsFeed.bbcWales => l10n.djNewsFeedBbcWales,
    DjNewsFeed.bbcNorthernIreland => l10n.djNewsFeedBbcNorthernIreland,
    DjNewsFeed.guardianUk => l10n.djNewsFeedGuardianUk,
    DjNewsFeed.guardianAustralia => l10n.djNewsFeedGuardianAustralia,
    DjNewsFeed.guardianUs => l10n.djNewsFeedGuardianUs,
    DjNewsFeed.nprNational => l10n.djNewsFeedNprNational,
    DjNewsFeed.abcJustIn => l10n.djNewsFeedAbcJustIn,
    DjNewsFeed.sbsAustralia => l10n.djNewsFeedSbsAustralia,
    DjNewsFeed.rnzNational => l10n.djNewsFeedRnzNational,
    DjNewsFeed.cbcCanada => l10n.djNewsFeedCbcCanada,
    DjNewsFeed.rteNews => l10n.djNewsFeedRteNews,
    DjNewsFeed.custom => l10n.djNewsFeedCustom,
  };

  @override
  Widget build(BuildContext context) {
    final settings = _settings;
    if (settings == null) return const SizedBox.shrink();
    final l10n = context.l10n;
    final on = settings.mode != DjNewsMode.off;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 12),
        Text(l10n.djNews, style: TextTheme.of(context).titleMedium),
        Text(l10n.djNewsHelp, style: TextTheme.of(context).bodySmall),
        const SizedBox(height: 8),
        SegmentedButton<DjNewsMode>(
          segments: [
            ButtonSegment(value: DjNewsMode.off, label: Text(l10n.djNewsOff)),
            ButtonSegment(value: DjNewsMode.onTheHour, label: Text(l10n.djNewsOnTheHour)),
            ButtonSegment(value: DjNewsMode.nowAndThen, label: Text(l10n.djNewsNowAndThen)),
          ],
          selected: {settings.mode},
          onSelectionChanged: (selected) => unawaited(_save(mode: selected.first)),
        ),
        if (on) ...[
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              settings.mode == DjNewsMode.onTheHour ? l10n.djNewsOnTheHourHelp : l10n.djNewsNowAndThenHelp,
              style: TextTheme.of(context).bodySmall,
            ),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<DjNewsFeed>(
            initialValue: settings.feed,
            isExpanded: true,
            decoration: InputDecoration(labelText: l10n.djNewsFeed),
            items: [
              for (final feed in DjNewsFeed.values)
                DropdownMenuItem(
                  value: feed,
                  child: Text(_feedName(l10n, feed), overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (feed) {
              if (feed != null) unawaited(_save(feed: feed));
            },
          ),
          if (settings.feed == DjNewsFeed.custom)
            // Its own storage key, so the field's scroll position doesn't share the section's saved state.
            KeyedSubtree(
              key: const PageStorageKey('djNewsCustomFeedField'),
              // Kept as soon as the field is left, for the other address field too, which tapping into isn't "outside".
              child: Focus(
                onFocusChange: (focused) {
                  if (!focused && _custom.text.trim() != _settings?.custom) unawaited(_save(custom: _custom.text));
                },
                child: TextField(
                  controller: _custom,
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.done,
                  decoration: InputDecoration(labelText: l10n.djNewsCustomFeed, hintText: "https://…"),
                  onSubmitted: (value) => unawaited(_save(custom: value)),
                  onTapOutside: (_) => FocusScope.of(context).unfocus(),
                ),
              ),
            ),
          const SizedBox(height: 8),
          DropdownButtonFormField<DjNewsFeed?>(
            initialValue: settings.second,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: l10n.djNewsSecondFeed,
              helperText: l10n.djNewsSecondFeedHelp,
              helperMaxLines: 3,
            ),
            items: [
              DropdownMenuItem(value: null, child: Text(l10n.djNewsSecondFeedNone)),
              for (final feed in DjNewsFeed.values)
                DropdownMenuItem(
                  value: feed,
                  child: Text(_feedName(l10n, feed), overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (feed) => unawaited(feed == null ? _save(noSecond: true) : _save(second: feed)),
          ),
          if (settings.second == DjNewsFeed.custom)
            KeyedSubtree(
              key: const PageStorageKey('djNewsSecondCustomFeedField'),
              child: Focus(
                onFocusChange: (focused) {
                  if (!focused && _secondCustom.text.trim() != _settings?.secondCustom) {
                    unawaited(_save(secondCustom: _secondCustom.text));
                  }
                },
                child: TextField(
                  controller: _secondCustom,
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.done,
                  decoration: InputDecoration(labelText: l10n.djNewsSecondCustomFeed, hintText: "https://…"),
                  onSubmitted: (value) => unawaited(_save(secondCustom: value)),
                  onTapOutside: (_) => FocusScope.of(context).unfocus(),
                ),
              ),
            ),
          if (settings.mode == DjNewsMode.onTheHour) ...[
            const SizedBox(height: 8),
            Text(l10n.djNewsCount),
            const SizedBox(height: 4),
            SegmentedButton<int>(
              segments: [
                ButtonSegment(value: 1, label: Text(l10n.djNewsCountOne)),
                ButtonSegment(value: 3, label: Text(l10n.djNewsCountThree)),
              ],
              selected: {settings.count},
              onSelectionChanged: (selected) => unawaited(_save(count: selected.first)),
            ),
          ],
          const SizedBox(height: 8),
          Text(l10n.djNewsStyle),
          const SizedBox(height: 4),
          SegmentedButton<DjNewsStyle>(
            segments: [
              ButtonSegment(value: DjNewsStyle.newsreader, label: Text(l10n.djNewsStyleNewsreader)),
              ButtonSegment(value: DjNewsStyle.inCharacter, label: Text(l10n.djNewsStyleInCharacter)),
            ],
            selected: {settings.style},
            onSelectionChanged: (selected) => unawaited(_save(style: selected.first)),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.djNewsSting),
            subtitle: Text(l10n.djNewsStingHelp),
            value: settings.sting,
            onChanged: (sting) => unawaited(_save(sting: sting)),
          ),
          if (_chime case final chime? when settings.sting) ...[
            _chimeChoice(chime, label: l10n.djNewsChimePrimary, value: chime.chosen, choose: DjNewsSting.choose),
            const SizedBox(height: 8),
            _chimeChoice(
              chime,
              label: l10n.djNewsChimeSecondary,
              value: chime.second.chime,
              choose: DjNewsSting.chooseSecondary,
              secondary: true,
            ),
            if (chime.second.chime != DjNewsSting.none) ...[
              const SizedBox(height: 8),
              Text(l10n.djSecondaryChance((_secondDrag ?? chime.second.chance.toDouble()).round())),
              Slider(
                min: 0,
                max: 100,
                divisions: 20,
                value: _secondDrag ?? chime.second.chance.toDouble(),
                onChanged: _chimeBusy ? null : (value) => setState(() => _secondDrag = value),
                onChangeEnd: (value) {
                  setState(() => _secondDrag = null);
                  unawaited(_onChime(() => DjNewsSting.setSecondaryChance(value.round())));
                },
              ),
            ],
            const SizedBox(height: 8),
            Text(l10n.djTalkOverChime((_talkDrag ?? chime.talk.chance.toDouble()).round())),
            Slider(
              min: 0,
              max: 100,
              divisions: 20,
              value: _talkDrag ?? chime.talk.chance.toDouble(),
              onChanged: _chimeBusy ? null : (value) => setState(() => _talkDrag = value),
              onChangeEnd: (value) {
                setState(() => _talkDrag = null);
                unawaited(_onChime(() => DjNewsSting.setTalkOver(chance: value.round())));
              },
            ),
            if (chime.talk.chance > 0) ...[
              Text(l10n.djUnderVoiceChime((_underDrag ?? chime.talk.under.toDouble()).round())),
              Slider(
                min: 5,
                max: 50,
                divisions: 9,
                value: _underDrag ?? chime.talk.under.toDouble(),
                onChanged: _chimeBusy ? null : (value) => setState(() => _underDrag = value),
                onChangeEnd: (value) {
                  setState(() => _underDrag = null);
                  unawaited(_onChime(() => DjNewsSting.setTalkOver(under: value.round())));
                },
              ),
            ],
            Text(l10n.djTalkOverChimeHelp, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 4),
            Text(l10n.djNewsChimeFormat, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _chimeBusy ? null : _importChime,
                  icon: const Icon(Icons.file_open_outlined),
                  label: Text(l10n.djNewsChimeImport),
                ),
                if (chime.own)
                  TextButton(
                    onPressed: _chimeBusy ? null : () => _onChime(DjNewsSting.remove),
                    child: Text(l10n.djNewsChimeRemove),
                  ),
              ],
            ),
          ],
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.djNewsDetail),
            subtitle: Text(l10n.djNewsDetailHelp),
            value: settings.detail,
            onChanged: (detail) => unawaited(_save(detail: detail)),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.djNewsGentle),
            subtitle: Text(l10n.djNewsGentleHelp),
            value: settings.gentle,
            onChanged: (gentle) => unawaited(_save(gentle: gentle)),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.djNewsPause),
            subtitle: Text(l10n.djNewsPauseHelp),
            value: settings.pause,
            onChanged: (pause) => unawaited(_save(pause: pause)),
          ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: _checking ? null : () => unawaited(_checkFeed()),
              icon: _checking
                  ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.newspaper),
              label: Text(l10n.djNewsCheck),
            ),
          ),
          if (_check != null) Text(_check!, style: TextTheme.of(context).bodySmall),
        ],
      ],
    );
  }
}
