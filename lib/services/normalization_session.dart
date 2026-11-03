import 'loudness_normalization.dart';

enum NormalizationSource { off, track, album, fallback }

/// The decision for one playback, shared by both decoders during a crossfade.
class NormalizationSnapshot {
  const NormalizationSnapshot({
    required this.source,
    required this.gainDb,
    required this.headroomDb,
    this.measurement,
    this.usesAlbum = false,
  });

  factory NormalizationSnapshot.calculate({
    required bool enabled,
    required bool album,
    required LoudnessLevel level,
    required double headroomDb,
    LoudnessMeasurement? measurement,
    double? legacyGain,
    bool attenuationOnly = false,
  }) {
    final measured =
        measurement != null && (!album || (measurement.albumLufs != null && measurement.albumTruePeak != null));
    final gain = enabled
        ? normalizationGain(
            level: level,
            album: album,
            measurement: measurement,
            legacyGain: legacyGain,
            headroomDb: headroomDb,
          )
        : 0.0;
    return NormalizationSnapshot(
      source: !enabled
          ? NormalizationSource.off
          : !measured
          ? NormalizationSource.fallback
          : album
          ? NormalizationSource.album
          : NormalizationSource.track,
      gainDb: attenuationOnly && gain > 0 ? 0 : gain,
      headroomDb: headroomDb,
      measurement: measurement,
      usesAlbum: album,
    );
  }

  final NormalizationSource source;
  final double gainDb;
  final double headroomDb;
  final LoudnessMeasurement? measurement;
  final bool usesAlbum;
  bool get enabled => source != NormalizationSource.off;
}

/// Measurement arrivals never change a decision already in use. Explicit
/// playback settings form the context, so user changes still take effect.
class NormalizationSession {
  static final playback = NormalizationSession();
  final _snapshots = <(String, String), ({Object context, NormalizationSnapshot value})>{};

  NormalizationSnapshot? get(String server, String playbackId) => _snapshots[(server, playbackId)]?.value;

  NormalizationSnapshot resolve({
    required String server,
    required String playbackId,
    required Object context,
    required NormalizationSnapshot Function() create,
  }) {
    final key = (server, playbackId);
    final previous = _snapshots[key];
    if (previous != null && previous.context == context) return previous.value;
    final value = create();
    _snapshots[key] = (context: context, value: value);
    return value;
  }

  void retain(String server, Set<String> playbackIds) =>
      _snapshots.removeWhere((key, _) => key.$1 != server || !playbackIds.contains(key.$2));

  void clear() => _snapshots.clear();
}
