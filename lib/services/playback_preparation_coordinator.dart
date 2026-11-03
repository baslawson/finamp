import 'dart:async';

/// Owns pending music/voice work so late completion cannot replace a newer request.
class PlaybackPreparationCoordinator {
  PlaybackPreparationCoordinator._();
  static final shared = PlaybackPreparationCoordinator._();
  final Map<String, int> _revisions = {};
  final Map<String, Completer<void>> _cancellations = {};
  PreparationTicket start(String owner) {
    cancel(owner);
    final cancellation = _cancellations[owner] = Completer<void>();
    return PreparationTicket._(this, owner, _revisions[owner]!, cancellation.future);
  }

  void cancel(String owner) {
    _revisions[owner] = (_revisions[owner] ?? 0) + 1;
    final cancellation = _cancellations.remove(owner);
    if (cancellation != null && !cancellation.isCompleted) cancellation.complete();
  }
}

class PreparationTicket {
  PreparationTicket._(this._coordinator, this._owner, this._revision, this.cancelled);
  final Future<void> cancelled;
  final PlaybackPreparationCoordinator _coordinator;
  final String _owner;
  final int _revision;
  bool get current => _coordinator._revisions[_owner] == _revision;
}
