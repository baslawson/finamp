import 'dart:async';
import 'dart:convert';

import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/finamp_user_helper.dart';
import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _logger = Logger("GenreEditor");

/// When items were asked for: by which server and account, and when (on [GenreEditor.asking]'s clock).
typedef GenreEditorAsked = ({String? who, int at});

/// The Jellyfin account an edit is made with.
typedef GenreEditorAccount = ({String baseUrl, String serverId, String userId, String auth});

/// Saving didn't work for every item: the ones in [savedIds] (of [total]) have their new genres.
class GenreEditException implements Exception {
  const GenreEditException(this.savedIds, this.total, this.reason);

  final List<String> savedIds;
  final int total;
  final String reason;

  int get saved => savedIds.length;

  @override
  String toString() => "Saved $saved of $total, then: $reason";
}

/// Changes the genres of songs and albums in Jellyfin (admin accounts only). Jellyfin's edit replaces the whole item,
/// so each one is fetched in full and sent back with only its genres changed. The genres are locked as well, so a
/// library scan doesn't put back the ones in the files. The music files themselves aren't changed.
class GenreEditor {
  @visibleForTesting
  static http.Client Function() client = http.Client.new;

  /// The newest genres known for items edited while the app runs: as saved, then as Jellyfin last sent them
  /// ([loaded]). Shown wherever the item's genres are, including on copies of it loaded before the edit (such as in
  /// the queue), which never show the old ones again.
  static final edited = ValueNotifier<Map<BaseItemId, List<NameLongIdPair>>>(const {});

  /// The genres to show for [item]: the newest known for an edited one (on this server and account), or as loaded.
  static List<NameLongIdPair>? genresShown(BaseItemDto item) =>
      (_owner == _signedIn() ? edited.value[item.id] : null) ?? item.genreItems;

  /// The server and account [edited] is for: item ids on another are other items.
  static String? _owner;

  static String? _signedIn() {
    try {
      return _ownerOf(account());
    } catch (_) {
      return null;
    }
  }

  static String _ownerOf(GenreEditorAccount who) => "${who.serverId} ${who.userId}";

  /// Starts over when another server or account is signed in.
  static void _forOwner() {
    final now = _signedIn();
    if (now == _owner) return;
    _owner = now;
    _shownAt.clear();
    if (edited.value.isNotEmpty) edited.value = const {};
  }

  /// Counts edits and requests in the order they're made, to tell what Jellyfin sent from before another.
  static int _clock = 0;

  /// For each item in [edited]: when what it shows was edited, or asked for.
  static final _shownAt = <BaseItemId, int>{};

  /// Taken when asking Jellyfin for items, to pass to [loaded] with them: who asked, and when.
  static GenreEditorAsked get asking => (who: _signedIn(), at: ++_clock);

  /// [ids] were just given [genres]: shown on them wherever they are, until Jellyfin sends newer ones.
  static void remember(Iterable<String> ids, List<NameLongIdPair> genres) {
    _forOwner();
    final at = ++_clock;
    for (final id in ids) {
      _shownAt[BaseItemId(id)] = at;
    }
    edited.value = {...edited.value, for (final id in ids) BaseItemId(id): genres};
  }

  /// [items] just came from Jellyfin, asked for at [asked] ([asking]): for edited ones, their genres there are the
  /// newest, a later change made elsewhere included, unless asked for before the edit or before what's shown (an
  /// answer can be slower than one asked for after it), or by another server or account than the one signed in.
  /// Items sent without their genres say nothing about them.
  static void loaded(Iterable<BaseItemDto> items, {required GenreEditorAsked asked}) {
    if (_shownAt.isEmpty || asked.who != _signedIn()) return;
    _forOwner();
    final newer = {
      for (final item in items)
        if (item.genreItems case final genres? when (_shownAt[item.id] ?? asked.at) < asked.at) item.id: genres,
    };
    if (newer.isEmpty) return;
    for (final id in newer.keys) {
      _shownAt[id] = asked.at;
    }
    edited.value = {...edited.value, ...newer};
  }

  /// Just saved [saved] with the account [who], each with [genres] (with the ids known for them): shows those at once
  /// wherever they are, then as Jellyfin has them, unless they're edited again before that's read. The first as
  /// Jellyfin now has it; the others as saved, with the ids Jellyfin gave those genres on the first. Returns the newest
  /// known for the first. Nothing is shown (null) once another account is signed in: its items with the same ids are
  /// other items.
  static Future<List<NameLongIdPair>?> showSaved(
    List<String> saved,
    GenreEditorAccount who, {
    required List<NameLongIdPair> genres,
  }) async {
    if (_signedIn() != _ownerOf(who)) return null;
    remember(saved, genres);
    final asked = asking;
    final web = client();
    // One new to the library (without an id yet) is made a genre there, so its chip opens it.
    final named = [
      for (final genre in genres)
        if (genre.name case final name? when genre.id.raw.isEmpty)
          NameLongIdPair(name: name, id: await _musicGenre(web, who, name) ?? genre.id)
        else
          genre,
    ];
    try {
      final first = await _genreItemsOf(web, who, saved.first);
      final ids = {
        for (final genre in [...named, ...first])
          if (genre.name case final name?) name.toLowerCase(): genre.id,
      };
      final others = [
        for (final genre in named) NameLongIdPair(name: genre.name, id: ids[genre.name?.toLowerCase()] ?? genre.id),
      ];
      loaded([
        BaseItemDto(id: BaseItemId(saved.first), genreItems: first),
        for (final id in saved.skip(1)) BaseItemDto(id: BaseItemId(id), genreItems: others),
      ], asked: asked);
    } catch (e) {
      // Shown as saved until they next load.
      _logger.warning("Couldn't read the saved genres", e);
      loaded([for (final id in saved) BaseItemDto(id: BaseItemId(id), genreItems: named)], asked: asked);
    } finally {
      web.close();
    }
    return _owner == _ownerOf(who) && _signedIn() == _owner ? edited.value[BaseItemId(saved.first)] : null;
  }

  static const _ratings = ["OfficialRating", "CustomRating"];

  @visibleForTesting
  static GenreEditorAccount Function() account = () {
    final helper = GetIt.instance<FinampUserHelper>();
    final user = helper.currentUser!;
    return (baseUrl: user.baseURL, serverId: user.serverId, userId: user.id, auth: helper.authorizationHeader);
  };

  /// The account signed in now: what [save] saves with when called.
  static GenreEditorAccount get signedIn => account();

  /// The genres of the item [id] as Jellyfin has them.
  static Future<List<String>> genresOf(String id) async {
    final web = client();
    // One account throughout, even if another signs in meanwhile.
    final who = account();
    try {
      return _genres(await _item(web, who, id));
    } finally {
      web.close();
    }
  }

  /// The genres of the item [id] with their Jellyfin ids, as the app shows them.
  static Future<List<NameLongIdPair>> genreItemsOf(String id) async {
    final web = client();
    try {
      // One account throughout, even if another signs in meanwhile.
      return await _genreItemsOf(web, account(), id);
    } finally {
      web.close();
    }
  }

  static Future<List<NameLongIdPair>> _genreItemsOf(http.Client web, GenreEditorAccount who, String id) async {
    final item = await _item(web, who, id);
    return [
      for (final genre in ((item["GenreItems"] as List?) ?? const []).whereType<Map<String, dynamic>>())
        if (genre["Id"] case final String genreId)
          NameLongIdPair(name: genre["Name"] as String?, id: BaseItemId(genreId)),
    ];
  }

  /// The ids of the songs on the album [albumId].
  static Future<List<String>> songsOf(String albumId) async {
    final web = client();
    try {
      // One account throughout, even if another signs in meanwhile.
      return [
        for (final song in await _songsOf(web, account(), albumId))
          if (song["Id"] case final String id) id,
      ];
    } finally {
      web.close();
    }
  }

  /// The songs on the album [albumId], with their ratings.
  static Future<List<Map<String, dynamic>>> _songsOf(http.Client web, GenreEditorAccount who, String albumId) async {
    final json = await _get(web, who, "/Items", {
      "ParentId": albumId,
      "IncludeItemTypes": "Audio",
      "Recursive": "true",
      "UserId": who.userId,
      "Fields": "CustomRating",
    });
    return [...(json["Items"] as List? ?? const []).whereType<Map<String, dynamic>>()];
  }

  /// [genres] as they'll be saved: trimmed, without empty ones, each once (ignoring case), in the order given.
  static List<String> tidy(Iterable<String> genres) {
    final seen = <String>{};
    return [
      for (final genre in genres.map((genre) => genre.trim()))
        if (genre.isNotEmpty && seen.add(genre.toLowerCase())) genre,
    ];
  }

  /// Gives the items [ids] (an album first, then its songs) the [genres]. Returns the ids saved; throws a
  /// [GenreEditException] with the ones that were when some weren't. For an [album], its songs are looked up again
  /// as it's saved (in place of the rest of [ids]), so one added since they were isn't left with the album's rating.
  ///
  /// Saving an album makes Jellyfin (10.10 and 10.11 always, later versions when it changes) give its songs the
  /// album's rating, so each song goes back exactly as it was, rating included. Their ratings are kept on the device
  /// until then, so one left unsaved (or the app closed meanwhile) gets its own back when it's next saved.
  static Future<List<String>> save(List<String> ids, List<String> genres, {bool album = false}) async {
    // The account signed in now, even if another signs in before this one's turn.
    final who = account();
    // One at a time, so one doesn't write over the ratings another kept.
    for (var other = _saving; other != null; other = _saving) {
      await other;
    }
    final done = Completer<void>();
    _saving = done.future;
    try {
      return await _save(who, ids, genres, album: album);
    } finally {
      _saving = null;
      done.complete();
    }
  }

  static Future<void>? _saving;

  static Future<List<String>> _save(
    GenreEditorAccount who,
    List<String> asked,
    List<String> genres, {
    required bool album,
  }) async {
    final wanted = tidy(genres);
    final web = client();
    final saved = <String>[];
    try {
      final Map<String, Map<String, dynamic>> kept;
      try {
        kept = await keptRatings(who);
      } catch (e) {
        _logger.warning("Couldn't read the kept ratings", e);
        throw GenreEditException(const [], asked.length, "$e");
      }
      final ids = album ? [asked.first] : [...asked];
      // All fetched before any is saved, each song with its own rating back if it still has the album's.
      final items = <Map<String, dynamic>>[];
      // Each one's ratings as fetched, before any was put back.
      final fetched = <Map<String, dynamic>>[];
      Future<void> fetch(String id) async {
        try {
          final item = await _item(web, who, id);
          fetched.add({for (final field in _ratings) field: item[field]});
          for (final MapEntry(key: field, :value) in (kept[id] ?? const {}).entries) {
            if (value case {"before": final before, "album": final album} when item[field] == album) {
              item[field] = before;
            }
          }
          items.add(item);
        } catch (e) {
          _logger.warning("Couldn't load $id to change its genres", e);
          throw GenreEditException(const [], ids.length, "$e");
        }
      }

      // Its rating goes to all its songs, even ones hidden from this account, which then can't be put back.
      if (album) {
        bool seesAll;
        try {
          seesAll = await _seesAll(web, who);
        } catch (e) {
          _logger.warning("Couldn't tell if every song of ${ids.first} can be seen", e);
          throw GenreEditException(const [], asked.length, "$e");
        }
        if (!seesAll) {
          throw GenreEditException(
            const [],
            asked.length,
            "Parental controls hide some songs from this account, so change the genres song by song",
          );
        }
      }
      for (final id in [...ids]) {
        await fetch(id);
      }
      // Until none are new, so one added to the album while the others were fetched (a library scan) isn't left with
      // the album's rating. Only one added in the moment before the album is saved can still be.
      for (var added = album; added;) {
        final List<Map<String, dynamic>> songs;
        try {
          songs = await _songsOf(web, who, ids.first);
        } catch (e) {
          _logger.warning("Couldn't find the songs of ${ids.first} to change their genres", e);
          throw GenreEditException(const [], ids.length, "$e");
        }
        final found = [
          for (final song in songs)
            if (song["Id"] case final String id when !ids.contains(id)) id,
        ];
        added = found.isNotEmpty;
        for (final song in found) {
          ids.add(song);
          await fetch(song);
        }
        if (added) continue;
        // One gone from the album since it was fetched (deleted, or moved to another) isn't saved.
        final current = {for (final song in songs) song["Id"]};
        for (var index = ids.length - 1; index > 0; index--) {
          if (!current.contains(ids[index])) {
            ids.removeAt(index);
            items.removeAt(index);
            fetched.removeAt(index);
          }
        }
        // A rating changed in Jellyfin since its song was fetched stays as it is now.
        for (final song in songs) {
          final index = ids.indexOf(song["Id"] as String);
          for (final field in _ratings) {
            if (index > 0 && song[field] != fetched[index][field]) {
              fetched[index][field] = song[field];
              items[index][field] = song[field];
            }
          }
        }
      }
      final keptBefore = {...kept};
      var albumSent = false;
      // Kept no more as each is saved, so one put back isn't put back again over a later change should the app close
      // meanwhile. When that can't be kept, it's tried again at the end.
      Future<void> savedOne(int index) async {
        if (kept.remove(ids[index]) == null) return;
        try {
          await _keep(who, kept);
        } catch (e) {
          _logger.warning("Couldn't update the kept ratings", e);
        }
      }

      // What each was last sent as.
      final sent = <int, Map<String, dynamic>>{};
      Future<void> send(int index) async {
        // As it is now: what changed in Jellyfin since it was first fetched stays.
        final item = await _item(web, who, ids[index]);
        // Its rating as worked out above, unless changed in Jellyfin since: still as fetched, or as the album passed
        // on to its songs.
        for (final field in _ratings) {
          if (item[field] == fetched[index][field] || item[field] == items[0][field]) {
            item[field] = items[index][field];
          }
        }
        // Its rating goes to its other children too (such as disc folders), which aren't put back: as it's sent.
        if (index == 0 && album) {
          final children = await _childrenOf(web, who, ids[0]);
          if (children.any(
            (child) =>
                child["Type"] != "Audio" &&
                _ratings.any(
                  (field) =>
                      child[field] != item[field] && !((child["LockedFields"] as List?) ?? const []).contains(field),
                ),
          )) {
            throw const _Unsafe(
              "Some of this album's folders have their own rating, so change the genres song by song",
            );
          }
        }
        item["Genres"] = wanted;
        // Left out, so they stay as they are: sent, Jellyfin would put them back without their order.
        item.remove("People");
        // Jellyfin takes the artists from these, which leave out any it hasn't found in the library (yet).
        if (item["Artists"] case final List<dynamic> artists) {
          final found = {
            for (final artist in ((item["ArtistItems"] as List?) ?? const []).whereType<Map<String, dynamic>>())
              artist["Name"]: artist,
          };
          item["ArtistItems"] = [
            for (final name in artists.whereType<String>()) found[name] ?? {"Name": name},
          ];
        }
        // Of the album artists only the first is sent by name.
        if (item["AlbumArtist"] case final String first when first.isNotEmpty) {
          final albumArtists = ((item["AlbumArtists"] as List?) ?? const []).whereType<Map<String, dynamic>>();
          if (!albumArtists.any((artist) => (artist["Name"] as String?)?.toLowerCase() == first.toLowerCase())) {
            item["AlbumArtists"] = [
              {"Name": first},
              ...albumArtists,
            ];
          }
        }
        // Locked, so a library scan keeps them.
        item["LockedFields"] = [
          ...((item["LockedFields"] as List?) ?? const []).where((field) => field != "Genres"),
          "Genres",
        ];
        if (index == 0) {
          // What it passes on to its songs: its ratings as sent, changed in Jellyfin since they were fetched or not.
          for (final field in _ratings) {
            items[0][field] = item[field];
          }
          // Kept before it's sent, even when a song had none: Jellyfin leaves it out then, and saving it without one
          // clears the album's.
          for (var song = 1; song < ids.length; song++) {
            kept[ids[song]] = {
              for (final field in _ratings) field: {"before": items[song][field], "album": items[0][field]},
            };
          }
          await _keep(who, kept);
          albumSent = true;
        }
        sent[index] = item;
        await _post(web, who, "/Items/${ids[index]}", item);
        await savedOne(index);
      }

      // An album first, then its songs; or a song alone.
      final isAlbum = album || ids.length > 1;
      // The first (the album) not saved: nothing has changed.
      try {
        await send(0);
        saved.add(ids[0]);
      } catch (e) {
        _logger.warning("Couldn't save the genres of ${ids[0]}", e);
        if (!isAlbum && e is! _Refused && await _saved(web, who, ids[0], sent[0])) {
          // Saved all the same, its answer lost.
          await savedOne(0);
          saved.add(ids[0]);
        } else {
          // Not sent or turned down, so its songs keep their ratings.
          if (!albumSent || e is _Refused) await _keep(who, keptBefore);
          // Otherwise it may have been saved, its answer lost, and Jellyfin may yet be passing its rating on (showing
          // the album saved before that's done): its songs get their own ratings back on their next save.
          throw GenreEditException(const [], ids.length, "$e");
        }
      }
      // Once it is, every song goes back even when one fails, and those that did get one more try.
      final failed = <int, Object>{};
      for (final round in [1, 2]) {
        for (final index in round == 1 ? [for (var i = 1; i < ids.length; i++) i] : failed.keys.toList()) {
          try {
            await send(index);
            saved.add(ids[index]);
            failed.remove(index);
          } catch (e) {
            _logger.warning("Couldn't save the genres of ${ids[index]} (try $round)", e);
            // Saved all the same, its answer lost.
            if (e is! _Refused && await _saved(web, who, ids[index], sent[index])) {
              await savedOne(index);
              saved.add(ids[index]);
              failed.remove(index);
            } else {
              failed[index] = e;
            }
          }
        }
      }
      try {
        await _keep(who, kept);
      } catch (e) {
        // Saved all the same: those saved still show it.
        _logger.warning("Couldn't update the kept ratings", e);
        throw GenreEditException(saved, ids.length, "$e");
      }
      if (failed.isNotEmpty) throw GenreEditException(saved, ids.length, "${failed.values.first}");
      _logger.info("Saved genres $wanted for ${saved.length} items");
      return saved;
    } finally {
      web.close();
    }
  }

  /// The id of the music genre [name], which Jellyfin makes when there's none yet; null when that can't be had.
  static Future<BaseItemId?> _musicGenre(http.Client web, GenreEditorAccount who, String name) async {
    try {
      final json = await _get(web, who, "/MusicGenres/${Uri.encodeComponent(name)}", {"userId": who.userId});
      if (json["Id"] case final String id when id.isNotEmpty) return BaseItemId(id);
      return null;
    } catch (e) {
      _logger.warning("Couldn't make the genre $name", e);
      return null;
    }
  }

  /// The items right under [id], songs or not, with their ratings and what's locked.
  static Future<List<Map<String, dynamic>>> _childrenOf(http.Client web, GenreEditorAccount who, String id) async {
    final json = await _get(web, who, "/Items", {
      "ParentId": id,
      "UserId": who.userId,
      // Settings: what's locked.
      "Fields": "CustomRating,Settings",
    });
    return [...(json["Items"] as List? ?? const []).whereType<Map<String, dynamic>>()];
  }

  /// Whether no parental controls hide items from the account [who].
  static Future<bool> _seesAll(http.Client web, GenreEditorAccount who) async {
    final policy = (await _get(web, who, "/Users/${who.userId}", const {}))["Policy"];
    if (policy is! Map<String, dynamic>) return false;
    bool none(String field) => ((policy[field] as List?) ?? const []).isEmpty;
    return policy["MaxParentalRating"] == null &&
        none("BlockedTags") &&
        none("AllowedTags") &&
        none("BlockUnratedItems");
  }

  /// Kept by server (whatever address it's reached at, whichever account saves): item ids on another are other
  /// items.
  static String _keptKey(GenreEditorAccount who) => "genreEditorKeptRatings ${who.serverId}";

  /// The ratings kept for songs whose album was saved: by song, each rating's value before and the album's.
  @visibleForTesting
  /// Throws when they can't be read: saving then could lose the only copy of a song's own rating.
  @visibleForTesting
  static Future<Map<String, Map<String, dynamic>>> keptRatings([GenreEditorAccount? who]) async {
    final json = await SharedPreferencesAsync().getString(_keptKey(who ?? account()));
    if (json == null) return {};
    try {
      return {
        for (final MapEntry(:key, :value) in (jsonDecode(json) as Map<String, dynamic>).entries)
          if (value is Map<String, dynamic>) key: value,
      };
    } catch (e) {
      // Spoiled, so nothing in it can be put back: saves go on without it.
      _logger.warning("Couldn't read the kept ratings", e);
      return {};
    }
  }

  static Future<void> _keep(GenreEditorAccount who, Map<String, Map<String, dynamic>> kept) => kept.isEmpty
      ? SharedPreferencesAsync().remove(_keptKey(who))
      : SharedPreferencesAsync().setString(_keptKey(who), jsonEncode(kept));

  /// Whether the item [id] is in Jellyfin as [sent] (sent with its answer lost): its genres, locked, and its ratings.
  /// False when not sent, or when that can't be read.
  static Future<bool> _saved(http.Client web, GenreEditorAccount who, String id, Map<String, dynamic>? sent) async {
    if (sent == null) return false;
    try {
      final now = await _item(web, who, id);
      return listEquals(_genres(now), _genres(sent)) &&
          ((now["LockedFields"] as List?) ?? const []).contains("Genres") &&
          _ratings.every((field) => now[field] == sent[field]);
    } catch (e) {
      _logger.warning("Couldn't tell if $id was saved", e);
      return false;
    }
  }

  static List<String> _genres(Map<String, dynamic> item) => [
    ...((item["Genres"] as List?) ?? const []).whereType<String>(),
  ];

  /// The whole item, every field, as Jellyfin's own editor gets it.
  static Future<Map<String, dynamic>> _item(http.Client web, GenreEditorAccount who, String id) =>
      _get(web, who, "/Users/${who.userId}/Items/$id", const {});

  static Uri _uri(GenreEditorAccount who, String path, Map<String, String> query) {
    final base = Uri.parse(who.baseUrl);
    return base.replace(
      pathSegments: [...base.pathSegments.where((segment) => segment.isNotEmpty), ...Uri.parse(path).pathSegments],
      queryParameters: query.isEmpty ? null : query,
    );
  }

  /// How long Jellyfin is waited for: a busy server can take well over 20 seconds to answer, and a save not answered
  /// in time is taken for lost (which stops an album's).
  static const _readTimeout = Duration(seconds: 60);
  static const _saveTimeout = Duration(seconds: 90);

  static Future<Map<String, dynamic>> _get(
    http.Client web,
    GenreEditorAccount who,
    String path,
    Map<String, String> query,
  ) async {
    final response = await web
        .get(_uri(who, path, query), headers: {"Authorization": who.auth, "Accept": "application/json"})
        .timeout(_readTimeout);
    if (response.statusCode != 200) throw http.ClientException("Jellyfin answered ${response.statusCode}");
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  static Future<void> _post(http.Client web, GenreEditorAccount who, String path, Map<String, dynamic> body) async {
    final response = await web
        .post(
          _uri(who, path, const {}),
          headers: {"Authorization": who.auth, "Content-Type": "application/json"},
          body: jsonEncode(body),
        )
        .timeout(_saveTimeout);
    if (response.statusCode ~/ 100 != 2) {
      // Turned down (not lost or failed on the way): nothing changed.
      if (response.statusCode ~/ 100 == 4) throw _Refused(response.statusCode);
      throw http.ClientException("Jellyfin answered ${response.statusCode}");
    }
  }
}

/// Jellyfin turned an edit down.
/// Saving would lose something that can't be put back.
class _Unsafe implements Exception {
  const _Unsafe(this.message);

  final String message;

  @override
  String toString() => message;
}

class _Refused extends http.ClientException {
  _Refused(int status)
    : super(status == 403 ? "Only a Jellyfin administrator can change genres" : "Jellyfin answered $status");
}
