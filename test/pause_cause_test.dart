import 'package:finamp/services/pause_cause.dart';
import 'package:flutter_test/flutter_test.dart';

String _cause(List<String> calls) =>
    pauseCause(StackTrace.fromString([for (final (i, call) in calls.indexed) '#$i      $call'].join('\n')));

void main() {
  test('a pause from the lock screen or notification is put down to the media controls', () {
    expect(
      _cause([
        'MusicPlayerBackgroundTask.pause (package:finamp/services/music_player_background_task.dart:961:30)',
        '_HandlerCallbacks.pause (package:audio_service/audio_service.dart:3921:28)',
        '<asynchronous suspension>',
      ]),
      'the media controls (lock screen, notification, Bluetooth device, car or watch)',
    );
  });

  test('a pause from a headset or car button is put down to a media button', () {
    expect(
      _cause([
        'MusicPlayerBackgroundTask.pause (package:finamp/services/music_player_background_task.dart)',
        'BaseAudioHandler.click (package:audio_service/audio_service.dart)',
        '_HandlerCallbacks.click (package:audio_service/audio_service.dart)',
      ]),
      'a media button (headset, Bluetooth device or car)',
    );
  });

  test('a pause from the app names the part of it that asked, past the toggle', () {
    expect(
      _cause([
        'MusicPlayerBackgroundTask.pause (package:finamp/services/music_player_background_task.dart:961:30)',
        'MusicPlayerBackgroundTask.togglePlayback (package:finamp/services/music_player_background_task.dart:1074:14)',
        '_PlayerButtonsState.build.<anonymous closure> (package:finamp/components/PlayerScreen/player_buttons.dart:73:38)',
        '_InkResponseState.handleTap (package:flutter/src/material/ink_well.dart:1224:21)',
      ]),
      'the app (_PlayerButtonsState.build.<anonymous closure>)',
    );
  });

  test('a pause with no part of the app or the system behind it is unknown, not put down to a library', () {
    expect(
      _cause([
        'MusicPlayerBackgroundTask.pause (package:finamp/services/music_player_background_task.dart)',
        '_BehaviorSubject._add (package:rxdart/src/subjects/behavior_subject.dart)',
        '_rootRun (dart:async/zone.dart)',
      ]),
      'unknown',
    );
  });
}
