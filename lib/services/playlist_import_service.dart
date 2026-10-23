import 'dart:convert';

import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/finamp_user_helper.dart';
import 'package:finamp/services/jellyfin_api_helper.dart';
import 'package:finamp/services/library_matcher.dart';
import 'package:get_it/get_it.dart';
import 'package:http/http.dart' as http;

class PlaylistImportException implements Exception {
  PlaylistImportException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A playlist read from another service or pasted text.
typedef ImportedPlaylist = ({String? name, List<SongRef> songs});

/// Reads playlists from Spotify and Apple Music links, CSV exports and plain "Artist - Title" lists,
/// so they can be rebuilt from the user's own library.
class PlaylistImportService {
  PlaylistImportService._();

  static const _browserHeaders = {
    "User-Agent":
        "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126 Mobile Safari/537.36",
    "Accept-Language": "en",
  };

  /// Reads [input], which is a playlist link or the text of a list or CSV file.
  static Future<ImportedPlaylist> read(String input) async {
    final text = input.trim();
    final spotify = RegExp(r"open\.spotify\.com/(?:intl-[a-z]+/)?(playlist|album)/([A-Za-z0-9]+)").firstMatch(text);
    if (spotify != null) return _spotify(spotify.group(1)!, spotify.group(2)!);
    final apple = RegExp(r"https://music\.apple\.com/\S+").firstMatch(text);
    if (apple != null) return _appleMusic(Uri.parse(apple.group(0)!));
    if (RegExp(r"^https?://", caseSensitive: false).hasMatch(text)) {
      throw PlaylistImportException("Only Spotify and Apple Music links can be read. For others, paste the song list.");
    }
    return (name: null, songs: parseText(text));
  }

  static Future<String> _fetch(Uri uri) async {
    final response = await http.get(uri, headers: _browserHeaders).timeout(const Duration(seconds: 20));
    if (response.statusCode == 404) throw PlaylistImportException("That playlist wasn't found. Is it public?");
    if (response.statusCode != 200) {
      throw PlaylistImportException("Couldn't load the playlist (${response.statusCode})");
    }
    return utf8.decode(response.bodyBytes);
  }

  static Map<String, dynamic> _jsonScript(String html, String id) {
    final match = RegExp('<script[^>]*id="$id"[^>]*>(.*?)</script>', dotAll: true).firstMatch(html);
    if (match == null) {
      throw PlaylistImportException("Couldn't read the playlist page. The service may have changed it.");
    }
    return jsonDecode(match.group(1)!) as Map<String, dynamic>;
  }

  /// Spotify's embed page has the track list without needing an API key (up to 100 tracks).
  static Future<ImportedPlaylist> _spotify(String kind, String id) async {
    final html = await _fetch(Uri.parse("https://open.spotify.com/embed/$kind/$id"));
    try {
      final data = _jsonScript(html, "__NEXT_DATA__");
      final entity = data["props"]["pageProps"]["state"]["data"]["entity"] as Map<String, dynamic>;
      final tracks = (entity["trackList"] as List).cast<Map<String, dynamic>>();
      return (
        name: (entity["name"] ?? entity["title"]) as String?,
        songs: [
          for (final track in tracks)
            SongRef(title: track["title"] as String, artist: (track["subtitle"] as String? ?? "").replaceAll(" ", " ")),
        ],
      );
    } on PlaylistImportException {
      rethrow;
    } catch (e) {
      throw PlaylistImportException("Couldn't read the Spotify playlist: $e");
    }
  }

  static Future<ImportedPlaylist> _appleMusic(Uri uri) async {
    final html = await _fetch(uri);
    try {
      final data = _jsonScript(html, "serialized-server-data");
      final page = ((data["data"] as List).first as Map<String, dynamic>)["data"] as Map<String, dynamic>;
      final sections = (page["sections"] as List).cast<Map<String, dynamic>>();
      String? name;
      final songs = <SongRef>[];
      for (final section in sections) {
        final items = (section["items"] as List? ?? []).cast<Map<String, dynamic>>();
        if (section["itemKind"] == "containerDetailHeaderLockup" && items.isNotEmpty) {
          name = items.first["title"] as String?;
        } else if (section["itemKind"] == "trackLockup") {
          for (final item in items) {
            songs.add(SongRef(title: item["title"] as String, artist: item["artistName"] as String? ?? ""));
          }
        }
      }
      return (name: name, songs: songs);
    } on PlaylistImportException {
      rethrow;
    } catch (e) {
      throw PlaylistImportException("Couldn't read the Apple Music playlist: $e");
    }
  }

  /// Parses CSV exports (Exportify, TuneMyMusic and similar, with title and artist columns) or one song per line
  /// as "Artist - Title".
  static List<SongRef> parseText(String text) {
    final lines = const LineSplitter().convert(text).where((line) => line.trim().isNotEmpty).toList();
    if (lines.isEmpty) return [];
    final header = _csvRow(lines.first).map((cell) => cell.toLowerCase().trim()).toList();
    final titleColumn = header.indexWhere((cell) => ["track name", "title", "track", "song", "name"].contains(cell));
    final artistColumn = header.indexWhere(
      (cell) => ["artist name(s)", "artist name", "artist", "artists", "artist(s)"].contains(cell),
    );
    if (titleColumn >= 0 && artistColumn >= 0) {
      return [
        for (final line in lines.skip(1))
          if (_csvRow(line) case final row when row.length > titleColumn && row.length > artistColumn)
            SongRef(title: row[titleColumn].trim(), artist: row[artistColumn].trim()),
      ];
    }
    return [
      for (final line in lines)
        if (RegExp(r"^\s*(?:\d+[.)]\s*)?(.+?)\s+[-–—]\s+(.+?)\s*$").firstMatch(line) case final match?)
          SongRef(artist: match.group(1)!, title: match.group(2)!),
    ];
  }

  /// Splits one CSV line, honoring quoted cells.
  static List<String> _csvRow(String line) {
    final cells = <String>[];
    final cell = StringBuffer();
    var quoted = false;
    for (var i = 0; i < line.length; i++) {
      final char = line[i];
      if (quoted) {
        if (char == '"' && i + 1 < line.length && line[i + 1] == '"') {
          cell.write('"');
          i++;
        } else if (char == '"') {
          quoted = false;
        } else {
          cell.write(char);
        }
      } else if (char == '"') {
        quoted = true;
      } else if (char == ",") {
        cells.add(cell.toString());
        cell.clear();
      } else {
        cell.write(char);
      }
    }
    cells.add(cell.toString());
    return cells;
  }

  /// Creates a Jellyfin playlist with [tracks].
  static Future<BaseItemDto> createPlaylist(String name, List<BaseItemDto> tracks) async {
    final api = GetIt.instance<JellyfinApiHelper>();
    final created = await api.createNewPlaylist(
      NewPlaylist(
        name: name,
        userId: GetIt.instance<FinampUserHelper>().currentUserId,
        mediaType: "Audio",
        ids: [for (final track in tracks) track.id],
      ),
    );
    return api.getItemById(created.id!);
  }
}
