import 'package:finamp/components/mix_length_chips.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:flutter_test/flutter_test.dart';

BaseItemDto _track(String id, {int? minutes}) => BaseItemDto(
  id: BaseItemId(id),
  name: id,
  type: "Audio",
  runTimeTicks: minutes == null ? null : minutes * 60 * 10000000,
);

void main() {
  test("keeps songs until the length is filled, finishing the last one", () {
    final tracks = [for (var i = 0; i < 10; i++) _track("$i", minutes: 4)];
    // 30 minutes: seven songs make 28, so an eighth plays past the mark.
    expect(fillMixLength(tracks, 30).map((track) => track.name), ["0", "1", "2", "3", "4", "5", "6", "7"]);
    expect(fillMixLength(tracks, 8), hasLength(2));
  });

  test("counts songs without a length as average ones", () {
    final tracks = [for (var i = 0; i < 10; i++) _track("$i")];
    expect(fillMixLength(tracks, 12), hasLength(12 ~/ averageTrackMinutes));
  });

  test("keeps everything without a length or when there isn't enough", () {
    final tracks = [for (var i = 0; i < 3; i++) _track("$i", minutes: 4)];
    expect(fillMixLength(tracks, null), tracks);
    expect(fillMixLength(tracks, 120), tracks);
  });
}
