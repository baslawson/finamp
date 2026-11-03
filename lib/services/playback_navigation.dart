import 'dart:async';

enum PlaybackNavigationKind { next, previous, select, seekForward, seekBackward, restart }

/// User transport commands, separate from decoder/crossfade synchronization.
/// Beginning a command invalidates voice work synchronously, without delaying
/// the music command. A late completion cannot complete a newer command.
class PlaybackNavigation {
  PlaybackNavigation._();
  static final shared = PlaybackNavigation._();
  final _commands = StreamController<PlaybackNavigationCommand>.broadcast(sync: true);
  int _revision = 0;
  PlaybackNavigationCommand? _last;
  PlaybackNavigationCommand? get last => _last;
  Stream<PlaybackNavigationCommand> get commands => _commands.stream;

  PlaybackNavigationCommand begin(PlaybackNavigationKind kind, {required String? queueId, String? fromItemId}) {
    final command = PlaybackNavigationCommand._(++_revision, kind, queueId, fromItemId);
    _last = command;
    _commands.add(command);
    return command;
  }
}

class PlaybackNavigationCommand {
  PlaybackNavigationCommand._(this.revision, this.kind, this.queueId, this.fromItemId);
  final int revision;
  final PlaybackNavigationKind kind;
  final String? queueId;
  final String? fromItemId;
  bool _pending = true;
  String? _targetItemId;
  bool get pending => _pending;
  String? get targetItemId => _targetItemId;

  void complete({required String? targetItemId}) {
    if (!pending) return;
    _targetItemId = targetItemId;
    _pending = false;
  }
}
