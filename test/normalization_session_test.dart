import 'package:finamp/services/loudness_normalization.dart';
import 'package:finamp/services/normalization_session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  NormalizationSnapshot decision(LoudnessMeasurement? measurement, {bool album = false, double headroom = 0}) =>
      NormalizationSnapshot.calculate(
        enabled: true,
        album: album,
        level: LoudnessLevel.normal,
        headroomDb: headroom,
        measurement: measurement,
      );

  test('late analysis cannot change a playing song or its second decoder', () {
    final session = NormalizationSession();
    LoudnessMeasurement? measured;
    NormalizationSnapshot resolve(String playback) => session.resolve(
      server: 'server',
      playbackId: playback,
      context: (true, false, 0),
      create: () => decision(measured),
    );
    final first = resolve('queue-id');
    expect(first.source, NormalizationSource.fallback);
    expect(first.gainDb, -1);
    measured = const LoudnessMeasurement(lufs: -8, truePeak: -1);
    expect(identical(resolve('queue-id'), first), isTrue);
    expect(resolve('next-playback').gainDb, -6);
  });

  test('explicit level, scope and EQ changes replace a frozen decision', () {
    final session = NormalizationSession();
    const measured = LoudnessMeasurement(lufs: -8, truePeak: -1, albumLufs: -16, albumTruePeak: -2);
    NormalizationSnapshot resolve(bool album, double reserve) => session.resolve(
      server: 's',
      playbackId: 'id',
      context: (album, reserve),
      create: () => decision(measured, album: album, headroom: reserve),
    );
    expect(resolve(false, 0).gainDb, -6);
    expect(resolve(true, 0).gainDb, 1);
    expect(resolve(true, 4).gainDb, -3);
    session.clear();
    expect(session.get('s', 'id'), isNull);
  });

  test('completed playbacks and switched servers cannot retain stale gain', () {
    final session = NormalizationSession();
    for (final server in ['a', 'b']) {
      session.resolve(server: server, playbackId: 'id', context: 0, create: () => decision(null));
    }
    session.retain('b', {'id'});
    expect(session.get('a', 'id'), isNull);
    session.retain('b', {});
    expect(session.get('b', 'id'), isNull);
  });

  test('album fallback, Off, and attenuation-only platforms describe the actual gain', () {
    const measured = LoudnessMeasurement(lufs: -20, truePeak: -10);
    expect(decision(measured, album: true).source, NormalizationSource.fallback);
    final off = NormalizationSnapshot.calculate(
      enabled: false,
      album: false,
      level: LoudnessLevel.normal,
      headroomDb: 4,
      measurement: measured,
    );
    expect(off.enabled, isFalse);
    expect(off.gainDb, 0);
    final limited = NormalizationSnapshot.calculate(
      enabled: true,
      album: false,
      level: LoudnessLevel.normal,
      headroomDb: 0,
      measurement: measured,
      attenuationOnly: true,
    );
    expect(limited.gainDb, 0);
  });
}
