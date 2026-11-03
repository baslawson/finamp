import 'dart:convert';
import 'dart:io';

import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/ai_service.dart';
import 'package:finamp/services/finamp_user_helper.dart';
import 'package:finamp/services/jellyfin_api_helper.dart';
import 'package:get_it/get_it.dart';
import 'package:path_provider/path_provider.dart';

/// The story behind an album, written by the AI.
class LinerNotes {
  LinerNotes({required this.story, required this.highlights, required this.relatedIds});

  final String story;
  final List<({String track, String note})> highlights;

  /// Albums from the library to try next.
  final List<String> relatedIds;

  factory LinerNotes.fromJson(Map<String, dynamic> json) => LinerNotes(
    story: json["story"] as String? ?? "",
    highlights: [
      for (final highlight in json["highlights"] as List<dynamic>? ?? [])
        (track: highlight["track"] as String? ?? "", note: highlight["note"] as String? ?? ""),
    ],
    relatedIds: (json["related"] as List<dynamic>? ?? []).cast<String>(),
  );

  Map<String, dynamic> toJson() => {
    "story": story,
    "highlights": [
      for (final highlight in highlights) {"track": highlight.track, "note": highlight.note},
    ],
    "related": relatedIds,
  };
}

/// Writes and keeps liner notes for albums: how they came about, standout tracks, and what to play next from
/// the library. Each album is only sent to the AI once.
class LinerNotesService {
  LinerNotesService._();

  static Future<File> _file(String albumId) async {
    final directory = Directory("${(await getApplicationSupportDirectory()).path}/liner_notes");
    await directory.create(recursive: true);
    return File("${directory.path}/$albumId.json");
  }

  static Future<LinerNotes?> cached(BaseItemDto album) async {
    try {
      final file = await _file(album.id.raw);
      if (!await file.exists()) return null;
      return LinerNotes.fromJson(jsonDecode(await file.readAsString()) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  static Future<LinerNotes> write(BaseItemDto album, List<BaseItemDto> tracks) async {
    final api = GetIt.instance<JellyfinApiHelper>();
    final library = GetIt.instance<FinampUserHelper>().currentUser?.currentView;
    // Candidates for "play next": albums sharing a genre, falling back to random ones.
    final candidates =
        (await api.getItems(
                  parentItem: library,
                  includeItemTypes: BaseItemDtoType.album.jellyfinName,
                  sortBy: "Random",
                  recursive: true,
                  limit: 150,
                  genreFilters: album.genreItems?.map((genre) => genre.id).toList(),
                ) ??
                [])
            .where((candidate) => candidate.id != album.id)
            .toList();

    final prompt = StringBuffer()
      ..writeln(
        "Write liner notes for this album, like the booklet of a good reissue: how and when it was made, "
        "what it meant for the artist, and what to listen for. Only state facts you're confident about; "
        "if you don't know the album, keep it short and say what the music itself suggests instead of inventing history.",
      )
      ..writeln()
      ..writeln("Album: ${album.name} by ${album.albumArtist ?? album.artists?.join(", ") ?? "unknown artist"}")
      ..writeln("Year: ${album.productionYear ?? "unknown"}")
      ..writeln("Genres: ${album.genres?.join(", ") ?? "unknown"}")
      ..writeln("Tracks: ${tracks.map((track) => track.name).join("; ")}")
      ..writeln()
      ..writeln("Albums in the listener's library (index|album|artist):")
      ..writeln([
        for (var i = 0; i < candidates.length; i++) "$i|${candidates[i].name}|${candidates[i].albumArtist ?? ""}",
      ].join("\n"))
      ..writeln()
      ..writeln(
        "Return: story (2-4 short paragraphs separated by blank lines, at most 220 words), highlights (2-4 "
        "tracks from the tracklist with one sentence each on what makes them stand out), and related (up to 4 "
        "indexes of library albums a fan of this one would enjoy next). Write in the language of this locale: "
        "${Platform.localeName}.",
      );
    final result = await AiService.generateJson(
      prompt: prompt.toString(),
      schemaName: "liner_notes",
      schema: {
        "type": "object",
        "properties": {
          "story": {"type": "string"},
          "highlights": {
            "type": "array",
            "items": {
              "type": "object",
              "properties": {
                "track": {"type": "string"},
                "note": {"type": "string"},
              },
              "required": ["track", "note"],
              "additionalProperties": false,
            },
          },
          "related": {
            "type": "array",
            "items": {"type": "integer"},
          },
        },
        "required": ["story", "highlights", "related"],
        "additionalProperties": false,
      },
    );
    final notes = LinerNotes(
      story: (result["story"] as String? ?? "").trim(),
      highlights: [
        for (final highlight in result["highlights"] as List<dynamic>? ?? [])
          (track: highlight["track"] as String? ?? "", note: highlight["note"] as String? ?? ""),
      ],
      relatedIds: [
        for (final index in (result["related"] as List<dynamic>? ?? []).whereType<num>())
          if (index >= 0 && index < candidates.length) candidates[index.toInt()].id.raw,
      ],
    );
    await (await _file(album.id.raw)).writeAsString(jsonEncode(notes.toJson()));
    return notes;
  }

  static Future<void> forget(BaseItemDto album) async {
    final file = await _file(album.id.raw);
    if (await file.exists()) await file.delete();
  }
}
