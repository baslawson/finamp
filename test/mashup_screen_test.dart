import 'dart:async';
import 'dart:io';

import 'package:finamp/l10n/app_localizations.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/screens/mashup_screen.dart';
import 'package:finamp/services/mashup_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const singer = '0123456789abcdef0123456789abcdef', band = 'fedcba9876543210fedcba9876543210';
const other = '11111111111111111111111111111111';
final revision = 'a' * 64;

BaseItemDto song(String id, String name) => BaseItemDto.fromJson({'Id': id, 'Name': name, 'Type': 'Audio'});

MashupJob job({String state = 'ready'}) => MashupJob.fromJson({
  'state': state,
  'revision': revision,
  'vocals': singer,
  'backing': band,
  'message': state == 'failed' ? 'Out of memory' : null,
  'plan': {'tempo': 0.96, 'semitones': -2, 'key': 'same', 'score': 0.5, 'warnings': <String>[]},
  'mixes': {
    'mashup': {'bytes': 4, 'version': 1, 'lufs': -14, 'truePeak': -1},
  },
});

/// Answers from memory and remembers what was asked.
class FakeMashups extends MashupService {
  FakeMashups() : super(settings: () async => (url: 'http://analyzer.test', token: 't'));
  final asked = <String>[];
  List<MashupJob> jobs = [];
  List<SavedMashup> savedCopies = [];
  int listed = 0;

  /// Holds the first listing back until completed.
  Completer<void>? firstList;

  @override
  Future<List<MashupPartner>> partners(String song, {bool sings = true}) async {
    asked.add('partners $song $sings');
    return [
      MashupPartner.fromJson({
        'id': sings ? band : other,
        'score': 0.73,
        'semitones': sings ? 2 : -1,
        'tempo': 1.05,
        'key': 'relative',
      }),
    ];
  }

  /// The songs each "Mashups to try" asked about.
  final seeds = <List<String>>[];

  @override
  Future<List<MashupIdea>> ideas(List<String> songs) async {
    seeds.add(songs);
    return [
      MashupIdea.fromJson({
        'vocals': other,
        'backing': band,
        'score': 0.81,
        'semitones': 1,
        'tempo': 0.97,
        'key': 'same',
      }),
    ];
  }

  @override
  Future<List<MashupJob>> list() async {
    final jobs = this.jobs;
    if (listed++ == 0) await firstList?.future;
    return jobs;
  }

  @override
  Future<List<SavedMashup>> saved() async => savedCopies;

  @override
  Future<void> deleteLocal(MashupJob job) async {
    asked.add('delete phone ${job.revision}');
    savedCopies = [];
  }

  @override
  Future<void> deleteServer(MashupJob job) async {
    asked.add('delete server ${job.revision}');
    jobs = [];
  }
}

void main() {
  late FakeMashups service;
  Completer<void>? searching;
  Future<List<BaseItemDto>> songs({List<String>? ids, String? searchTerm}) async {
    if (searchTerm != null) await searching?.future;
    return [
      for (final (id, name) in [(singer, 'Singer song'), (band, 'Band song'), (other, 'Other song')])
        if (ids == null || ids.contains(id)) song(id, name),
    ];
  }

  late bool playing;
  setUp(() {
    service = FakeMashups();
    playing = false;
    searching = null;
  });

  Future<void> open(
    WidgetTester tester, {
    bool offline = false,
    bool withSong = true,
    bool settle = true,
    String songName = 'Singer song',
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        // A new screen each time, as opening it again would.
        home: MashupScreen(
          key: UniqueKey(),
          item: withSong ? song(singer, songName) : null,
          service: service,
          songs: songs,
          offline: offline,
          isPlaying: (_) async => playing,
          played: () async => [song(singer, 'Singer song'), song(band, 'Band song')],
        ),
      ),
    );
    settle ? await tester.pumpAndSettle() : await tester.pump();
  }

  testWidgets('partners are suggested for either role, with how they are fitted', (tester) async {
    await open(tester);
    expect(service.asked, ['partners $singer true']);
    expect(find.text('Band song'), findsOneWidget);
    expect(find.textContaining('Related key · singer 2 semitones higher · vocals 5% faster'), findsOneWidget);
    expect(find.text('73%'), findsOneWidget);
    await tester.tap(find.text("Another song's vocals over it"));
    await tester.pumpAndSettle();
    expect(service.asked.last, 'partners $singer false');
    expect(find.text('Other song'), findsOneWidget);
    expect(find.text('Band song'), findsNothing);
  });

  testWidgets('server mashups offer saving and deleting; a saved one also deletes from the phone', (tester) async {
    service.jobs = [job()];
    await open(tester, withSong: false);
    expect(find.text('Singer song over Band song'), findsOneWidget);
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    expect(find.text('Play mashup'), findsOneWidget);
    expect(find.text('Save offline'), findsOneWidget);
    expect(find.text('Delete from phone'), findsNothing);
    await tester.tap(find.text('Delete from server'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete from server'));
    await tester.pumpAndSettle();
    expect(service.asked, ['delete server $revision']);
    expect(find.text('Singer song over Band song'), findsNothing);

    service.jobs = [job()];
    service.savedCopies = [
      (job: job(), singer: song(singer, 'Singer song'), band: song(band, 'Band song'), file: File('x')),
    ];
    await open(tester, withSong: false);
    expect(find.text('Saved on this phone'), findsOneWidget);
    await tester.tap(find.byType(PopupMenuButton<String>).last);
    await tester.pumpAndSettle();
    expect(find.text('Save offline'), findsNothing);
    await tester.tap(find.text('Delete from phone'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete from phone'));
    await tester.pumpAndSettle();
    expect(service.asked.last, 'delete phone $revision');
    expect(find.text('Saved on this phone'), findsNothing);
  });

  // Not pumpAndSettle: a listing held back keeps the progress bar moving.
  Future<void> step(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  Future<void> deletePhone(WidgetTester tester, {bool startsPlaying = false}) async {
    await tester.tap(find.byType(PopupMenuButton<String>).first);
    await step(tester);
    await tester.tap(find.text('Delete from phone'));
    await step(tester);
    if (find.widgetWithText(FilledButton, 'Delete from phone').evaluate().isEmpty) return;
    playing = startsPlaying;
    await tester.tap(find.widgetWithText(FilledButton, 'Delete from phone'));
    await step(tester);
  }

  testWidgets('the phone copy that is playing is not deleted', (tester) async {
    final copy = (job: job(), singer: song(singer, 'Singer song'), band: song(band, 'Band song'), file: File('x'));
    service.savedCopies = [copy];
    await open(tester, offline: true);
    playing = true;
    await deletePhone(tester);
    expect(find.textContaining('from this phone?'), findsNothing);
    expect(find.text("Play something else before deleting this mashup from the phone."), findsOneWidget);
    // It may also start playing while the question is open.
    playing = false;
    await deletePhone(tester, startsPlaying: true);
    expect(find.text("Play something else before deleting this mashup from the phone."), findsWidgets);
    expect(service.asked, isEmpty);
    expect(find.text('Saved on this phone'), findsOneWidget);
  });

  testWidgets('an action during a slow listing lists again afterwards', (tester) async {
    service.savedCopies = [
      (job: job(), singer: song(singer, 'Singer song'), band: song(band, 'Band song'), file: File('x')),
    ];
    service.firstList = Completer();
    await open(tester, withSong: false, settle: false);
    await tester.pump();
    await deletePhone(tester);
    expect(service.asked, ['delete phone $revision']);
    // The listing that was already running started before the change; another one shows it.
    service.jobs = [job()];
    service.firstList!.complete();
    await tester.pumpAndSettle();
    expect(service.listed, 2);
    expect(find.text('Singer song over Band song'), findsOneWidget);
  });

  testWidgets('opened from a playing mashup, the song is looked up rather than taken by its mashup title', (
    tester,
  ) async {
    await open(tester, songName: 'Singer song over Other song');
    expect(find.text("Mash up 'Singer song'"), findsOneWidget);
    await tester.tap(find.text('Band song'));
    await step(tester);
    expect(find.text('Singer song over Band song'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets('without a song, mashups to try come from the songs played lately', (tester) async {
    await open(tester, withSong: false);
    expect(service.seeds, [
      [singer, band],
    ]);
    expect(find.text('Mashups to try'), findsOneWidget);
    expect(find.text('Other song over Band song'), findsOneWidget);
    expect(find.text('81%'), findsOneWidget);
    await tester.tap(find.text('Other song over Band song'));
    await step(tester);
    // The same question as for a suggestion, with how the pair is fitted.
    expect(find.widgetWithText(AlertDialog, 'Other song over Band song'), findsOneWidget);
    expect(find.textContaining('singer 1 semitone higher'), findsWidgets);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    // Not with a song (it has its own suggestions), nor offline.
    service.seeds.clear();
    await open(tester);
    await open(tester, withSong: false, offline: true);
    expect(service.seeds, isEmpty);
    expect(find.text('Mashups to try'), findsNothing);
  });

  testWidgets('clearing a search that is still running stops its progress bar', (tester) async {
    await open(tester);
    await tester.tap(find.text('Pick a song yourself'));
    await tester.pumpAndSettle();
    searching = Completer();
    await tester.enterText(find.byType(TextField), 'so');
    await tester.pump(const Duration(milliseconds: 500));
    final bar = find.descendant(of: find.byType(AlertDialog), matching: find.byType(LinearProgressIndicator));
    expect(bar, findsOneWidget);
    await tester.enterText(find.byType(TextField), 's');
    await tester.pump(const Duration(milliseconds: 500));
    searching!.complete();
    await tester.pumpAndSettle();
    expect(bar, findsNothing);
    expect(find.text('Other song'), findsNothing);
    searching = null;
  });

  testWidgets('a failed mashup can be retried and offline only saved ones show', (tester) async {
    service.jobs = [job(state: 'failed')];
    await open(tester, withSong: false);
    expect(find.textContaining('Failed: Out of memory'), findsOneWidget);
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Play mashup'), findsNothing);
    await tester.tapAt(Offset.zero);
    await tester.pumpAndSettle();

    service.savedCopies = [
      (job: job(), singer: song(singer, 'Singer song'), band: song(band, 'Band song'), file: File('x')),
    ];
    await open(tester, offline: true);
    expect(service.asked, isEmpty);
    expect(find.text("You're offline: only mashups saved on this phone can play."), findsOneWidget);
    expect(find.text('Saved on this phone'), findsOneWidget);
    expect(find.text('Mashups on the server'), findsNothing);
  });
}
