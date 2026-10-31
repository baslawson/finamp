import 'package:finamp/models/jellyfin_models.dart';

/// A mix written out as an M3U playlist, for other players and the server's own library tools.
class MixExport {
  MixExport._();

  /// [tracks] as an extended M3U playlist named [name]. Each song points at its file as the server stores it, so the
  /// playlist works next to the music library; songs without a known file are left out, and [skipped] counts them.
  /// [pathOf] gives a song's file when the song itself doesn't carry it.
  static ({String text, int skipped}) m3u(
    String name,
    List<BaseItemDto> tracks, {
    String? Function(BaseItemDto)? pathOf,
  }) {
    final lines = ["#EXTM3U", "#PLAYLIST:${_oneLine(name)}"];
    var skipped = 0;
    for (final track in tracks) {
      final path = pathOf?.call(track) ?? track.path;
      if (path == null || path.trim().isEmpty) {
        skipped++;
        continue;
      }
      final seconds = track.runTimeTicks == null ? -1 : track.runTimeTicks! ~/ 10000000;
      final artist = track.artists?.join(", ") ?? track.albumArtist;
      final title = track.name ?? "";
      lines.add("#EXTINF:$seconds,${_oneLine(artist == null || artist.isEmpty ? title : "$artist - $title")}");
      lines.add(path.trim());
    }
    return (text: "${lines.join("\n")}\n", skipped: skipped);
  }

  /// A file name for [name]'s playlist, without characters file systems refuse.
  static String fileName(String name) {
    final safe = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), " ").replaceAll(RegExp(r"\s+"), " ").trim();
    return "${safe.isEmpty ? "Mix" : safe}.m3u";
  }

  static String _oneLine(String text) => text.replaceAll(RegExp(r"[\r\n]+"), " ");
}
