import 'package:finamp/services/playback_buffer_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('music and incoming buffers fit the configured budget with room for a local voice', () {
    for (final megabytes in [1, 5, 10, 50, 500]) {
      final total = megabytes * 1024 * 1024;
      final main = PlaybackBufferPolicy.mainBudget(total);
      final incoming = PlaybackBufferPolicy.nextBudget(total);
      expect(main + incoming + PlaybackBufferPolicy.voiceBudgetBytes, lessThanOrEqualTo(total));
      expect(main, greaterThan(incoming));
      expect(incoming, lessThanOrEqualTo(12 * 1024 * 1024));
      final load = PlaybackBufferPolicy.incoming(totalBytes: total).androidLoadControl!;
      expect(load.targetBufferBytes, incoming);
      expect(load.bufferForPlaybackDuration, lessThanOrEqualTo(load.minBufferDuration));
      expect(load.minBufferDuration, lessThanOrEqualTo(load.maxBufferDuration));
    }
  });

  test('preparation moves earlier after slow loads, stays bounded and recovers gradually', () {
    final lead = PreparationLead();
    expect(lead.value, const Duration(seconds: 10));
    lead.record(const Duration(seconds: 20));
    expect(lead.value, const Duration(seconds: 30));
    lead.record(const Duration(milliseconds: 100));
    expect(lead.value, greaterThan(const Duration(seconds: 20)));
    for (var i = 0; i < 20; i++) {
      lead.record(const Duration(milliseconds: 100));
    }
    expect(lead.value, const Duration(seconds: 10));
  });
}
