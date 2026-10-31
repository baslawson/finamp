import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';

/// Where a song's singing moved to in a remix of it, such as a mashup that plays the singer faster or slower and
/// later or earlier: a time in the original becomes `time / tempo + offset`. Kept in the queue item's extras under
/// [key], so the song's own lyrics still line up.
class LyricsTimeline {
  const LyricsTimeline({required this.tempo, required this.offset, this.name, this.ticks, this.artists});

  static const key = 'lyricsTimeline';

  /// How much faster the singing plays: 1.04 is 4% faster.
  final double tempo;

  /// How much later the singing starts, after the tempo change.
  final Duration offset;

  /// The original song's title, length (in ticks) and artists, which the remix's queue item replaces with its own;
  /// looking lyrics up by name, and saving the song, need them.
  final String? name;
  final int? ticks;
  final List<String>? artists;

  /// This timeline, remembering [song] as the original.
  LyricsTimeline ofSong(BaseItemDto song) =>
      LyricsTimeline(tempo: tempo, offset: offset, name: song.name, ticks: song.runTimeTicks, artists: song.artists);

  /// [item] as the original song, for looking its lyrics up or saving it.
  BaseItemDto original(BaseItemDto item) {
    if (name == null && ticks == null && artists == null) return item;
    return BaseItemDto.fromJson(item.toJson(setOffline: false))
      ..name = name ?? item.name
      ..runTimeTicks = ticks ?? item.runTimeTicks
      ..artists = artists ?? item.artists;
  }

  /// The timeline [track] was remixed on, if any.
  static LyricsTimeline? of(FinampQueueItem track) => fromJson(track.item.extras?[key]);

  /// The timeline that [track]'s lyrics play on while [mixPath] plays: only the remix's own audio moved the
  /// singing, not another mix (such as karaoke) put in its place.
  static LyricsTimeline? playing(FinampQueueItem track, String? mixPath) {
    final remix = track.item.extras?['downloadedTrackPath'];
    if (mixPath == null || remix is! String || _same(remix) != _same(mixPath)) return null;
    return of(track);
  }

  /// How long [track] plays while [mixPath] plays: the remix's own length, or the original song's when another mix
  /// (such as its karaoke) is put in the remix's place. Null when [track] isn't a remix that knows both.
  static Duration? lengthWhile(FinampQueueItem track, String? mixPath) {
    final original = of(track)?.ticks, remix = track.baseItem.runTimeTicks;
    if (original == null || remix == null) return null;
    return Duration(microseconds: (playing(track, mixPath) != null ? remix : original) ~/ 10);
  }

  static String _same(String path) => path.replaceAll(r'\', '/');

  static LyricsTimeline? fromJson(Object? json) {
    if (json is! Map) return null;
    final tempo = json['tempo'], offset = json['offset'];
    if (tempo is! num || offset is! num || !tempo.isFinite || tempo <= 0 || !offset.isFinite) return null;
    final name = json['name'], ticks = json['ticks'], artists = json['artists'];
    return LyricsTimeline(
      tempo: tempo.toDouble(),
      offset: Duration(microseconds: (offset * 1e6).round()),
      name: name is String ? name : null,
      ticks: ticks is int ? ticks : null,
      artists: artists is List ? artists.whereType<String>().toList() : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'tempo': tempo,
    'offset': offset.inMicroseconds / 1e6,
    if (name != null) 'name': name,
    if (ticks != null) 'ticks': ticks,
    if (artists != null) 'artists': artists,
  };

  int _ticks(int ticks) => (ticks / tempo).round() + offset.inMicroseconds * 10;

  /// [lyrics] on this timeline, as new objects. Lines that would come before the start, where the remix cut the
  /// singing, start at the start, so every line keeps its place (translations go by it); unsynced lyrics come back
  /// as they are.
  LyricDto apply(LyricDto lyrics) {
    final lines = <LyricLine>[];
    for (final line in lyrics.lyrics ?? const <LyricLine>[]) {
      final start = line.start;
      lines.add(
        LyricLine(
          text: line.text,
          start: start == null ? null : _ticks(start).clamp(0, 1 << 62),
          cues: line.cues
              ?.map(
                (cue) => LyricLineCue(
                  position: cue.position,
                  start: _ticks(cue.start).clamp(0, 1 << 62),
                  endPosition: cue.endPosition,
                  end: cue.end == null ? null : _ticks(cue.end!).clamp(0, 1 << 62),
                ),
              )
              .toList(),
        ),
      );
    }
    return LyricDto(metadata: lyrics.metadata, lyrics: lines);
  }
}
