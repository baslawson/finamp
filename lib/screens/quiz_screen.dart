import 'dart:async';

import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/extensions/localizations.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/music_player_background_task.dart';
import 'package:finamp/services/quiz_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

/// Guess the song: a few seconds of a song from your library, four titles to choose from. Pass the phone around to
/// play with friends.
class QuizScreen extends StatefulWidget {
  const QuizScreen({super.key});

  static const routeName = "/quiz";

  @override
  State<QuizScreen> createState() => _QuizScreenState();
}

enum _Stage { setup, loading, question, answered, done }

class _QuizScreenState extends State<QuizScreen> {
  static const _decades = [1960, 1970, 1980, 1990, 2000, 2010, 2020];

  final _player = QuizPlayer();
  bool _musicWasPlaying = false;

  QuizSource _source = const QuizEverything();
  int _rounds = 10;
  int _playerCount = 1;

  _Stage _stage = _Stage.setup;
  List<QuizQuestion> _questions = [];
  int _index = 0;
  late List<int> _scores;
  BaseItemDto? _picked;
  final _stopwatch = Stopwatch();
  int _lastPoints = 0;

  @override
  void initState() {
    super.initState();
    final music = GetIt.instance<MusicPlayerBackgroundTask>();
    _musicWasPlaying = music.playbackState.value.playing;
    if (_musicWasPlaying) unawaited(music.pause());
  }

  @override
  void dispose() {
    unawaited(_player.dispose());
    if (_musicWasPlaying) unawaited(GetIt.instance<MusicPlayerBackgroundTask>().play());
    super.dispose();
  }

  int get _turn => _index % _playerCount;

  Future<void> _start() async {
    setState(() => _stage = _Stage.loading);
    try {
      final questions = await QuizService.questions(_source, count: _rounds * _playerCount);
      if (!mounted) return;
      if (questions.length < 2) {
        GlobalSnackbar.message((context) => context.l10n.quizNotEnoughSongs);
        setState(() => _stage = _Stage.setup);
        return;
      }
      _questions = questions;
      _scores = List.filled(_playerCount, 0);
      _index = 0;
      await _ask();
    } catch (e) {
      GlobalSnackbar.error(e);
      if (mounted) setState(() => _stage = _Stage.setup);
    }
  }

  Future<void> _ask() async {
    setState(() {
      _stage = _Stage.loading;
      _picked = null;
    });
    final question = _questions[_index];
    try {
      await _player.load(question);
    } catch (e) {
      // Unplayable file: skip this one.
      if (_index + 1 < _questions.length) {
        _questions.removeAt(_index);
        return _ask();
      }
      GlobalSnackbar.error(e);
    }
    if (!mounted) return;
    setState(() => _stage = _Stage.question);
    _stopwatch
      ..reset()
      ..start();
    await _player.play(from: question.clipStart);
  }

  Future<void> _answer(BaseItemDto choice) async {
    if (_stage != _Stage.question) return;
    _stopwatch.stop();
    final question = _questions[_index];
    final correct = choice.id == question.answer.id;
    _lastPoints = QuizService.points(correct: correct, time: _stopwatch.elapsed);
    setState(() {
      _picked = choice;
      _scores[_turn] += _lastPoints;
      _stage = _Stage.answered;
    });
    await _player.playOn();
  }

  Future<void> _next() async {
    if (_index + 1 >= _questions.length) {
      await _player.stop();
      setState(() => _stage = _Stage.done);
      return;
    }
    _index++;
    await _ask();
  }

  String _playerName(int index) => context.l10n.quizPlayer(index + 1);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.quiz)),
      body: SafeArea(
        child: switch (_stage) {
          _Stage.setup => _setup(context),
          _Stage.loading => const Center(child: CircularProgressIndicator()),
          _Stage.question || _Stage.answered => _questionView(context),
          _Stage.done => _results(context),
        },
      ),
    );
  }

  Widget _setup(BuildContext context) {
    final l10n = context.l10n;
    final textTheme = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(l10n.quizDescription),
        const SizedBox(height: 20),
        Text(l10n.quizSongsFrom, style: textTheme.titleMedium),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 2,
          children: [
            ChoiceChip(
              label: Text(l10n.quizEverything),
              selected: _source is QuizEverything,
              onSelected: (_) => setState(() => _source = const QuizEverything()),
            ),
            ChoiceChip(
              label: Text(l10n.quizFavorites),
              selected: _source is QuizFavorites,
              onSelected: (_) => setState(() => _source = const QuizFavorites()),
            ),
            for (final decade in _decades)
              ChoiceChip(
                label: Text(l10n.quizDecade(decade < 2000 ? "${decade % 100}" : "$decade")),
                selected: switch (_source) {
                  QuizDecade(decade: final chosen) => chosen == decade,
                  _ => false,
                },
                onSelected: (_) => setState(() => _source = QuizDecade(decade)),
              ),
          ],
        ),
        const SizedBox(height: 20),
        Text(l10n.quizPlayers(_playerCount), style: textTheme.titleMedium),
        SegmentedButton<int>(
          segments: [for (var count = 1; count <= 4; count++) ButtonSegment(value: count, label: Text("$count"))],
          selected: {_playerCount},
          onSelectionChanged: (selection) => setState(() => _playerCount = selection.first),
        ),
        if (_playerCount > 1)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(l10n.quizPassThePhone, style: textTheme.bodySmall),
          ),
        const SizedBox(height: 20),
        Text(l10n.quizRounds(_rounds), style: textTheme.titleMedium),
        SegmentedButton<int>(
          segments: [for (final count in [5, 10, 15]) ButtonSegment(value: count, label: Text("$count"))],
          selected: {_rounds},
          onSelectionChanged: (selection) => setState(() => _rounds = selection.first),
        ),
        const SizedBox(height: 32),
        FilledButton.icon(
          onPressed: _start,
          icon: const Icon(TablerIcons.player_play),
          label: Text(l10n.quizStart),
        ),
      ],
    );
  }

  Widget _questionView(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final question = _questions[_index];
    final answered = _stage == _Stage.answered;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _playerCount > 1
                      ? l10n.quizTurn(_playerName(_turn), _index ~/ _playerCount + 1, _questions.length ~/ _playerCount)
                      : l10n.quizQuestionNumber(_index + 1, _questions.length),
                  style: theme.textTheme.titleMedium,
                ),
              ),
              Text(l10n.quizScore(_scores[_turn]), style: theme.textTheme.titleMedium),
            ],
          ),
          const SizedBox(height: 4),
          LinearProgressIndicator(value: (_index + (answered ? 1 : 0)) / _questions.length),
          const Spacer(),
          Center(
            child: StreamBuilder<bool>(
              stream: _player.playing,
              builder: (context, playing) => Icon(
                (playing.data ?? false) ? TablerIcons.music : TablerIcons.music_question,
                size: 96,
                color: theme.colorScheme.primary,
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (!answered)
            TextButton.icon(
              onPressed: () => _player.play(from: question.clipStart),
              icon: const Icon(TablerIcons.reload),
              label: Text(l10n.quizReplay),
            )
          else
            Text(
              _picked?.id == question.answer.id ? l10n.quizRight(_lastPoints) : l10n.quizWrong,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleLarge?.copyWith(
                color: _picked?.id == question.answer.id ? Colors.green : theme.colorScheme.error,
              ),
            ),
          const Spacer(),
          for (final choice in question.choices)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: _ChoiceButton(
                track: choice,
                state: !answered
                    ? _ChoiceState.open
                    : choice.id == question.answer.id
                    ? _ChoiceState.right
                    : choice.id == _picked?.id
                    ? _ChoiceState.wrong
                    : _ChoiceState.other,
                onPressed: () => _answer(choice),
              ),
            ),
          const SizedBox(height: 8),
          if (answered)
            FilledButton(
              onPressed: _next,
              child: Text(_index + 1 >= _questions.length ? l10n.quizSeeResults : l10n.quizNext),
            ),
        ],
      ),
    );
  }

  Widget _results(BuildContext context) {
    final l10n = context.l10n;
    final textTheme = Theme.of(context).textTheme;
    final ranking = [for (var player = 0; player < _playerCount; player++) player]
      ..sort((a, b) => _scores[b].compareTo(_scores[a]));
    final maximum = 3 * _questions.length ~/ _playerCount;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Icon(TablerIcons.trophy, size: 72),
        const SizedBox(height: 12),
        Text(
          _playerCount == 1 ? l10n.quizFinalScore(_scores.first, maximum) : l10n.quizWinner(_playerName(ranking.first)),
          textAlign: TextAlign.center,
          style: textTheme.headlineSmall,
        ),
        const SizedBox(height: 16),
        if (_playerCount > 1)
          for (final (place, player) in ranking.indexed)
            ListTile(
              leading: Text("${place + 1}.", style: textTheme.titleLarge),
              title: Text(_playerName(player)),
              trailing: Text(l10n.quizScore(_scores[player]), style: textTheme.titleMedium),
            ),
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: _start,
          icon: const Icon(TablerIcons.reload),
          label: Text(l10n.quizPlayAgain),
        ),
        TextButton(onPressed: () => setState(() => _stage = _Stage.setup), child: Text(l10n.quizChangeSettings)),
      ],
    );
  }
}

enum _ChoiceState { open, right, wrong, other }

class _ChoiceButton extends StatelessWidget {
  const _ChoiceButton({required this.track, required this.state, required this.onPressed});

  final BaseItemDto track;
  final _ChoiceState state;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (background, foreground) = switch (state) {
      _ChoiceState.right => (Colors.green, Colors.white),
      _ChoiceState.wrong => (scheme.error, scheme.onError),
      _ChoiceState.other => (scheme.surfaceContainerHighest, scheme.onSurface.withValues(alpha: 0.5)),
      _ChoiceState.open => (scheme.secondaryContainer, scheme.onSecondaryContainer),
    };
    return FilledButton(
      style: FilledButton.styleFrom(
        backgroundColor: background,
        foregroundColor: foreground,
        disabledBackgroundColor: background,
        disabledForegroundColor: foreground,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        alignment: Alignment.centerLeft,
      ),
      onPressed: state == _ChoiceState.open ? onPressed : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(track.name ?? "", maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16)),
          Text(
            track.albumArtist ?? track.artists?.firstOrNull ?? "",
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 13, color: foreground.withValues(alpha: 0.8)),
          ),
        ],
      ),
    );
  }
}
