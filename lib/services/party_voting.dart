import 'package:finamp/models/jellyfin_models.dart';
import 'package:uuid/uuid.dart';

class PartyRequest {
  PartyRequest({required this.track, required this.guest, required this.address, this.message = '', DateTime? time})
    : id = const Uuid().v4(),
      time = time ?? DateTime.now();
  final String id, guest, address;

  /// An optional dedication or note for the DJ, already cleaned up; empty when there is none.
  final String message;
  final BaseItemDto track;
  final DateTime time;
  final Set<String> voters = {};
}

/// Votes decide the next song among guests other than the last winner whenever
/// possible. This preserves turns even when one guest has the highest votes.
class PartyVoting {
  final List<PartyRequest> requests = [];
  String? lastGuest;
  static const perGuestLimit = 3, totalLimit = 60;
  bool add(PartyRequest request, {int pendingForGuest = 0}) {
    if (requests.length >= totalLimit ||
        pendingForGuest + requests.where((r) => r.address == request.address).length >= perGuestLimit ||
        requests.any((r) => r.track.id == request.track.id)) {
      return false;
    }
    request.voters.add(request.address);
    requests.add(request);
    return true;
  }

  bool vote(String id, String voter) {
    final matches = requests.where((r) => r.id == id);
    if (matches.isEmpty) return false;
    final request = matches.first;
    if (request.voters.length >= 200) return false;
    return request.voters.add(voter);
  }

  List<PartyRequest> get ranked => [...requests]
    ..sort((a, b) {
      final votes = b.voters.length.compareTo(a.voters.length);
      final time = a.time.compareTo(b.time);
      return votes != 0
          ? votes
          : time != 0
          ? time
          : a.id.compareTo(b.id);
    });
  PartyRequest? get next {
    final choices = ranked;
    final others = choices.where((r) => r.address != lastGuest);
    return others.firstOrNull ?? choices.firstOrNull;
  }

  void complete(PartyRequest request) {
    requests.remove(request);
    lastGuest = request.address;
  }

  void clear() {
    requests.clear();
    lastGuest = null;
  }
}
