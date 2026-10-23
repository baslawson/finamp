import 'dart:async';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/ai_dj_service.dart';
import 'package:finamp/services/ai_service.dart';
import 'package:finamp/services/audio_service_helper.dart';
import 'package:finamp/services/finamp_user_helper.dart';
import 'package:finamp/services/jellyfin_api_helper.dart';
import 'package:finamp/services/library_matcher.dart';
import 'package:finamp/services/music_player_background_task.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';

/// What a spoken request asks for.
sealed class VoiceCommand {
  const VoiceCommand();
}

enum PlayerAction { play, pause, next, previous, shuffleOn, shuffleOff, louder, quieter, favorite, whatsPlaying }

class PlayerCommand extends VoiceCommand {
  const PlayerCommand(this.action);
  final PlayerAction action;
}

class SetVolumeCommand extends VoiceCommand {
  const SetVolumeCommand(this.percent);
  final int percent;
}

/// Shuffle everything, or only favorites.
class ShuffleCommand extends VoiceCommand {
  const ShuffleCommand({required this.favorites});
  final bool favorites;
}

/// Play something by name. [kind] narrows it down when the request said so ("the album …").
class PlayCommand extends VoiceCommand {
  const PlayCommand(this.query, {this.kind, this.artist});
  final String query;
  final BaseItemDtoType? kind;

  /// "… by [artist]"
  final String? artist;
}

/// Free-form, like "something chill for cooking": handed to the AI DJ.
class MixCommand extends VoiceCommand {
  const MixCommand(this.request);
  final String request;
}

/// Control the music by voice: "pause", "next song", "turn it up", "play Nevermind", "play Hotel California by the
/// Eagles", "play my favorites" or, with an AI key, anything like "something upbeat for cleaning".
class VoiceControlService {
  VoiceControlService._();

  static final _logger = Logger("VoiceControlService");
  static const _channel = MethodChannel("com.unicornsonlsd.finamp/voice_search");

  static Future<bool> isAvailable() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>("isAvailable") ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// Turns recognised speech into a command.
  static VoiceCommand parse(String spoken) {
    final text = spoken.toLowerCase().replaceAll(RegExp(r"[.!?,]"), "").replaceAll(RegExp(r"\s+"), " ").trim();
    bool matches(String pattern) => RegExp("^(?:$pattern)\$").hasMatch(text);

    if (matches(r"(?:please )?(?:pause|stop)(?: (?:the )?(?:music|playing|playback|it))?(?: please)?")) {
      return const PlayerCommand(PlayerAction.pause);
    }
    if (matches(r"(?:play|resume|continue|unpause|start)(?: (?:the )?(?:music|playing|playback|it))?")) {
      return const PlayerCommand(PlayerAction.play);
    }
    if (matches(r"(?:next|skip)(?: (?:song|track|this(?: song| one)?|it))?|next one|play the next (?:song|one)")) {
      return const PlayerCommand(PlayerAction.next);
    }
    if (matches(r"(?:previous|back|go back|last)(?: (?:song|track|one))?|play the previous (?:song|one)")) {
      return const PlayerCommand(PlayerAction.previous);
    }
    if (matches(r"(?:turn )?shuffle(?: on)?|turn on shuffle|shuffle mode on")) {
      return const PlayerCommand(PlayerAction.shuffleOn);
    }
    if (matches(r"(?:turn )?shuffle off|turn off shuffle|stop shuffling|(?:no|don't) shuffle")) {
      return const PlayerCommand(PlayerAction.shuffleOff);
    }
    if (matches(r"(?:turn (?:it |the music |the volume )?up|louder|volume up|(?:make it )?louder please)")) {
      return const PlayerCommand(PlayerAction.louder);
    }
    if (matches(r"(?:turn (?:it |the music |the volume )?down|quieter|softer|volume down|lower(?: the volume)?)")) {
      return const PlayerCommand(PlayerAction.quieter);
    }
    final volume = RegExp(r"^(?:set )?(?:the )?volume (?:to |at )?(\d{1,3})(?: ?%| percent)?$").firstMatch(text);
    if (volume != null) return SetVolumeCommand(int.parse(volume.group(1)!).clamp(0, 100));
    if (matches(r"(?:i )?(?:like|love|favou?rite|heart)(?: (?:this|this song|it|that|the song))?")) {
      return const PlayerCommand(PlayerAction.favorite);
    }
    if (matches(r"what(?:'s| is) (?:playing|this(?: song)?|the song|this track)(?: now)?|which song is this")) {
      return const PlayerCommand(PlayerAction.whatsPlaying);
    }
    if (matches(r"(?:play|shuffle) (?:my )?(?:favou?rites|favou?rite songs|liked songs)")) {
      return const ShuffleCommand(favorites: true);
    }
    if (matches(r"(?:play|shuffle) (?:everything|all(?: songs| my music)?|my (?:music|library)|anything|something)|surprise me")) {
      return const ShuffleCommand(favorites: false);
    }

    final play = RegExp(r"^(?:play|put on|listen to|shuffle)(?: me)? (.+)$").firstMatch(text);
    if (play != null) {
      var query = play.group(1)!.trim();
      BaseItemDtoType? kind;
      final kinds = {
        r"^(?:the )?album (.+)$": BaseItemDtoType.album,
        r"^(.+?) album$": BaseItemDtoType.album,
        r"^(?:the )?(?:artist|band) (.+)$": BaseItemDtoType.artist,
        r"^(?:(?:some )?(?:songs|music|something) (?:by|from)) (.+)$": BaseItemDtoType.artist,
        r"^(?:the |my )?playlist (.+)$": BaseItemDtoType.playlist,
        r"^(.+?) playlist$": BaseItemDtoType.playlist,
        r"^(?:the )?(?:song|track) (.+)$": BaseItemDtoType.track,
      };
      for (final MapEntry(key: pattern, value: type) in kinds.entries) {
        final match = RegExp(pattern).firstMatch(query);
        if (match != null) {
          kind = type;
          query = match.group(1)!.trim();
          break;
        }
      }
      final by = kind == null || kind == BaseItemDtoType.track ? RegExp(r"^(.+?) by (.+)$").firstMatch(query) : null;
      if (by != null) return PlayCommand(by.group(1)!, kind: BaseItemDtoType.track, artist: by.group(2));
      return PlayCommand(query, kind: kind);
    }
    return MixCommand(spoken.trim());
  }

  /// How alike a spoken name and an item name are, from 0 to 1.
  static double similarity(String spoken, String name) {
    String clean(String text) =>
        LibraryMatcher.normalizeTitle(text).replaceAll(RegExp(r"^the "), "").replaceAll(" and ", " ").trim();
    final a = clean(spoken);
    final b = clean(name);
    if (a.isEmpty || b.isEmpty) return 0;
    if (a == b) return 1;
    if (a.replaceAll(" ", "") == b.replaceAll(" ", "")) return 0.95;
    if (b.contains(a) || a.contains(b)) {
      final shorter = a.length < b.length ? a : b;
      final longer = a.length < b.length ? b : a;
      return 0.5 + 0.4 * shorter.length / longer.length;
    }
    final wordsA = a.split(" ").toSet();
    final wordsB = b.split(" ").toSet();
    return 0.8 * wordsA.intersection(wordsB).length / wordsA.union(wordsB).length;
  }

  /// Listens for a request and carries it out. [messages] gives the texts to show.
  static Future<void> listen({
    required String prompt,
    required VoiceControlMessages messages,
  }) async {
    String? spoken;
    try {
      spoken = await _channel.invokeMethod<String>("listen", {"prompt": prompt});
    } on PlatformException catch (e) {
      _logger.warning("Voice control couldn't listen", e);
      GlobalSnackbar.message((_) => messages.unavailable);
      return;
    }
    if (spoken == null || spoken.trim().isEmpty) return;
    _logger.info("Heard: $spoken");
    try {
      final result = await run(parse(spoken), messages: messages);
      if (result != null) GlobalSnackbar.message((_) => result, isConfirmation: true);
    } catch (e) {
      GlobalSnackbar.error(e);
    }
  }

  /// Carries out [command]. Returns what to tell the user.
  static Future<String?> run(VoiceCommand command, {required VoiceControlMessages messages}) async {
    final player = GetIt.instance<MusicPlayerBackgroundTask>();
    final queue = GetIt.instance<QueueService>();
    switch (command) {
      case PlayerCommand(:final action):
        switch (action) {
          case PlayerAction.play:
            await player.play();
          case PlayerAction.pause:
            await player.pause();
          case PlayerAction.next:
            await player.skipToNext();
          case PlayerAction.previous:
            await player.skipToPrevious();
          case PlayerAction.shuffleOn:
            await queue.setPlaybackOrder(FinampPlaybackOrder.shuffled);
          case PlayerAction.shuffleOff:
            await queue.setPlaybackOrder(FinampPlaybackOrder.linear);
          case PlayerAction.louder:
            player.setVolume((player.volume + 0.15).clamp(0.0, 1.0));
            return messages.volume((player.volume + 0.15).clamp(0.0, 1.0));
          case PlayerAction.quieter:
            player.setVolume((player.volume - 0.15).clamp(0.05, 1.0));
            return messages.volume((player.volume - 0.15).clamp(0.05, 1.0));
          case PlayerAction.favorite:
            await player.toggleFavoriteStatusOfCurrentTrack();
          case PlayerAction.whatsPlaying:
            final item = player.mediaItem.valueOrNull;
            return item == null ? messages.nothingPlaying : messages.nowPlaying(item.title, item.artist ?? "");
        }
        return null;
      case SetVolumeCommand(:final percent):
        player.setVolume(percent / 100);
        return messages.volume(percent / 100);
      case ShuffleCommand(:final favorites):
        await GetIt.instance<AudioServiceHelper>().shuffleAll(onlyShowFavorites: favorites);
        return favorites ? messages.shufflingFavorites : messages.shufflingEverything;
      case PlayCommand():
        final found = await _find(command);
        if (found != null) {
          await _play(found);
          return messages.playing(found.name ?? command.query);
        }
        if (await AiService.isConfigured()) return _mix(command.query, messages);
        return messages.notFound(command.query);
      case MixCommand(:final request):
        if (await AiService.isConfigured()) return _mix(request, messages);
        // Without AI, treat it as a name.
        final found = await _find(PlayCommand(request));
        if (found == null) return messages.notUnderstood(request);
        await _play(found);
        return messages.playing(found.name ?? request);
    }
  }

  static Future<String> _mix(String request, VoiceControlMessages messages) async {
    final name = await AiDjService.playMix(request, trackCount: 40);
    return messages.playing(name);
  }

  /// The library item best matching [command], or null when nothing is close enough.
  static Future<BaseItemDto?> _find(PlayCommand command) async {
    final api = GetIt.instance<JellyfinApiHelper>();
    final library = GetIt.instance<FinampUserHelper>().currentUser?.currentView;

    if (command.artist != null) {
      final track = await LibraryMatcher.find(SongRef(title: command.query, artist: command.artist!));
      if (track != null) return track;
    }

    final kinds = command.kind == null
        ? [BaseItemDtoType.artist, BaseItemDtoType.album, BaseItemDtoType.playlist, BaseItemDtoType.track]
        : [command.kind!];
    final results = await Future.wait([
      for (final kind in kinds)
        api
            .getItems(
              parentItem: kind == BaseItemDtoType.playlist ? null : library,
              includeItemTypes: kind.jellyfinName,
              searchTerm: command.query,
              recursive: true,
              limit: 20,
            )
            .then((items) => items ?? <BaseItemDto>[])
            .catchError((Object e) => <BaseItemDto>[]),
    ]);
    // Best name match wins; on a tie, artists come before albums, playlists and songs (the order of [kinds]).
    final scored = [
      for (final (rank, items) in results.indexed)
        for (final item in items) (item: item, score: similarity(command.query, item.name ?? "") - rank * 0.01),
    ].sortedBy<num>((candidate) => -candidate.score);
    final best = scored.firstOrNull;
    return best != null && best.score >= 0.6 ? best.item : null;
  }

  static Future<void> _play(BaseItemDto item) async {
    final api = GetIt.instance<JellyfinApiHelper>();
    final library = GetIt.instance<FinampUserHelper>().currentUser?.currentView;
    final type = BaseItemDtoType.fromItem(item);
    final tracks = switch (type) {
      BaseItemDtoType.track => [item],
      BaseItemDtoType.artist =>
        await api.getItems(
              parentItem: item,
              libraryFilter: library?.id,
              includeItemTypes: BaseItemDtoType.track.jellyfinName,
              recursive: true,
              sortBy: "Random",
              limit: 200,
            ) ??
            [],
      BaseItemDtoType.album =>
        await api.getItems(
              parentItem: item,
              includeItemTypes: BaseItemDtoType.track.jellyfinName,
              recursive: true,
              sortBy: "ParentIndexNumber,IndexNumber,SortName",
            ) ??
            [],
      _ =>
        await api.getItems(parentItem: item, includeItemTypes: BaseItemDtoType.track.jellyfinName, recursive: true) ??
            [],
    };
    if (tracks.isEmpty) throw Exception("${item.name} has no songs");
    await GetIt.instance<QueueService>().startPlayback(
      items: tracks,
      source: QueueItemSource.rawId(
        type: switch (type) {
          BaseItemDtoType.album => QueueItemSourceType.album,
          BaseItemDtoType.artist => QueueItemSourceType.artist,
          BaseItemDtoType.playlist => QueueItemSourceType.playlist,
          _ => QueueItemSourceType.unknown,
        },
        name: QueueItemSourceName(type: QueueItemSourceNameType.preTranslated, pretranslatedName: item.name ?? ""),
        id: item.id.raw,
      ),
      order: type == BaseItemDtoType.artist ? FinampPlaybackOrder.shuffled : FinampPlaybackOrder.linear,
    );
  }
}

/// The texts voice control shows, so the service doesn't need a [BuildContext].
class VoiceControlMessages {
  const VoiceControlMessages({
    required this.unavailable,
    required this.nothingPlaying,
    required this.nowPlaying,
    required this.volume,
    required this.shufflingFavorites,
    required this.shufflingEverything,
    required this.playing,
    required this.notFound,
    required this.notUnderstood,
  });

  final String unavailable;
  final String nothingPlaying;
  final String Function(String title, String artist) nowPlaying;
  final String Function(double volume) volume;
  final String shufflingFavorites;
  final String shufflingEverything;
  final String Function(String name) playing;
  final String Function(String query) notFound;
  final String Function(String spoken) notUnderstood;
}
