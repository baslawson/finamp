import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/models/music_slices.dart';
import 'package:finamp/services/finamp_user_helper.dart';
import 'package:finamp/services/jellyfin_api_helper.dart';
import 'package:finamp/services/music_player_background_task.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:finamp/services/party_voting.dart';
export 'package:finamp/services/party_voting.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';

/// Party mode: a small web page served from the phone on the local network. Guests open it by scanning a QR
/// code, search the library and add songs to Next Up, either straight away or after the host approves.
/// Only people with the link (it carries a random key) can use it, and it stops when the host turns it off.
class PartyService {
  PartyService._();

  static final _logger = Logger("PartyService");
  static const _port = 8765;
  static const _maxBody = 4096;
  static const sourceId = "party";

  /// Songs one guest may have waiting for approval at a time.
  static const maxPendingPerGuest = 3;

  static HttpServer? _server;
  static String _key = "";
  static String? url;
  static bool autoAccept = true;
  static final List<PartyRequest> pending = [];
  static final List<PartyRequest> added = [];
  static final Map<String, PartyRequest> _adding = {};
  static final voting = PartyVoting();
  static bool votingEnabled = true;

  /// Whether the DJ gives requested songs a shout-out, with the guest's message when there is one.
  static bool shoutOuts = true;
  static const maxMessage = 80;

  /// Lets tests look up shout-outs without starting the web server.
  @visibleForTesting
  static bool pretendRunning = false;
  static Timer? _votingTimer;
  static StreamSubscription<dynamic>? _queueSubscription;
  static bool _pumping = false;
  static int _generation = 0;

  /// Fires whenever requests, approvals or the server state change.
  static final changes = StreamController<void>.broadcast();

  static bool get running => _server != null;

  static Future<String> start({InternetAddress? address, int port = _port}) async {
    await stop();
    final hostAddress = address ?? await localAddress();
    if (hostAddress == null) throw const SocketException("Not connected to a local network");
    final random = Random.secure();
    _key = List.generate(12, (_) => "abcdefghjkmnpqrstuvwxyz23456789"[random.nextInt(31)]).join();
    HttpServer server;
    try {
      server = await HttpServer.bind(address ?? InternetAddress.anyIPv4, port);
    } on SocketException {
      server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    }
    _server = server;
    server.listen((request) => unawaited(_handle(request)));
    url = "http://${hostAddress.address}:${server.port}/?k=$_key";
    _logger.info("Party mode on at ${hostAddress.address}:${server.port}");
    _votingTimer = Timer.periodic(const Duration(seconds: 5), (_) => unawaited(queueWinner()));
    _queueSubscription = GetIt.instance<QueueService>().getQueueStream().listen((_) => unawaited(queueWinner()));
    changes.add(null);
    return url!;
  }

  static Future<void> stop() async {
    _generation++;
    _key = '';
    _votingTimer?.cancel();
    await _queueSubscription?.cancel();
    _queueSubscription = null;
    await _server?.close(force: true);
    _server = null;
    url = null;
    pending.clear();
    voting.clear();
    added.clear();
    _adding.clear();
    changes.add(null);
  }

  /// The phone's address on the local network, preferring Wi-Fi.
  static Future<InternetAddress?> localAddress() async {
    final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
    final candidates = [
      for (final interface in interfaces)
        for (final address in interface.addresses)
          if (!address.isLoopback && !address.isLinkLocal) (name: interface.name, address: address),
    ];
    bool isPrivate(InternetAddress address) {
      final bytes = address.rawAddress;
      return bytes[0] == 10 ||
          (bytes[0] == 192 && bytes[1] == 168) ||
          (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] < 32);
    }

    final private = candidates.where((candidate) => isPrivate(candidate.address)).toList();
    return (private.where((candidate) => candidate.name.startsWith("wlan")).firstOrNull ?? private.firstOrNull)
        ?.address;
  }

  static Future<void> approve(PartyRequest request) async {
    if (!pending.contains(request)) return;
    if (votingEnabled) {
      if (!voting.add(request)) return;
      pending.remove(request);
      changes.add(null);
    } else {
      if (await _addToQueue(request)) pending.remove(request);
    }
  }

  static void decline(PartyRequest request) {
    pending.remove(request);
    changes.add(null);
  }

  static Set<BaseItemId> _queuedIds() {
    final queue = GetIt.instance<QueueService>().getQueue();
    return {
      for (final item in [...queue.nextUp, ...queue.queue])
        if (item.source.id == sourceId) item.baseItem.id,
    };
  }

  static List<PartyRequest> _waiting() {
    return {
      for (final request in [...pending, ...voting.requests, ..._adding.values, ..._queuedRequests()])
        request.id: request,
    }.values.toList();
  }

  static List<PartyRequest> _queuedRequests() {
    final queued = _queuedIds();
    final byTrack = <BaseItemId, PartyRequest>{};
    // A song may be requested again after it finishes. Only its latest request
    // owns the new queue entry, not older entries in the request history.
    for (final request in added) {
      if (queued.contains(request.track.id)) byTrack.putIfAbsent(request.track.id, () => request);
    }
    return byTrack.values.toList();
  }

  static Map<String, dynamic>? _requestProblem(String id, String address, {String? except}) {
    final waiting = _waiting().where((request) => request.id != except).toList();
    if (_queuedIds().any((queued) => queued.raw == id) || waiting.any((request) => request.track.id.raw == id)) {
      return {'ok': false, 'duplicate': true};
    }
    if (waiting.length >= PartyVoting.totalLimit ||
        waiting.where((request) => request.address == address).length >= maxPendingPerGuest) {
      return {'ok': false, 'tooMany': true};
    }
    return null;
  }

  static Future<bool> _addToQueue(PartyRequest request) async {
    if (_adding.containsKey(request.id) ||
        _requestProblem(request.track.id.raw, request.address, except: request.id) != null) {
      return false;
    }
    final generation = _generation;
    _adding[request.id] = request;
    try {
      await GetIt.instance<QueueService>().addToNextUp(
        PlayableSlice.simple(
          [request.track],
          QueueItemSource.rawId(
            type: QueueItemSourceType.unknown,
            name: QueueItemSourceName(
              type: QueueItemSourceNameType.preTranslated,
              pretranslatedName: "Party: ${request.guest}",
            ),
            id: sourceId,
          ),
        ),
      );
      if (generation != _generation) return false;
      added.insert(0, request);
      final queuedRequests = _queuedRequests().map((request) => request.id).toSet();
      for (var i = added.length - 1; i >= 50; i--) {
        if (!queuedRequests.contains(added[i].id)) added.removeAt(i);
      }
      changes.add(null);
      return true;
    } finally {
      _adding.remove(request.id);
    }
  }

  static Future<void> queueWinner({bool now = false}) async {
    if (!running || _pumping || (!votingEnabled && !now)) return;
    final winner = voting.next;
    if (winner == null || (!now && DateTime.now().difference(winner.time) < const Duration(seconds: 10))) return;
    final queue = GetIt.instance<QueueService>().getQueue();
    if (!now && [...queue.nextUp, ...queue.queue].any((item) => item.source.id == sourceId)) return;
    final generation = _generation;
    _pumping = true;
    try {
      if (!await _addToQueue(winner)) return;
      if (generation == _generation) {
        voting.complete(winner);
        changes.add(null);
      }
    } catch (error) {
      _logger.warning('Could not queue party winner', error);
      if (now) rethrow;
    } finally {
      _pumping = false;
    }
  }

  static Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      if (!running || _key.isEmpty || request.uri.queryParameters["k"] != _key) {
        response.statusCode = HttpStatus.forbidden;
        response.write("This party link isn't valid anymore. Ask the host for the new QR code.");
        return;
      }
      response.headers.set("Cache-Control", "no-store");
      response.headers.set('Referrer-Policy', 'no-referrer');
      switch ((request.method, request.uri.path)) {
        case ("GET", "/"):
          response.headers.set(HttpHeaders.contentTypeHeader, "text/html; charset=utf-8");
          response.write(_page);
        case ("GET", "/api/search"):
          await _json(response, await _search(request.uri.queryParameters["q"] ?? ""));
        case ("GET", "/api/state"):
          await _json(response, _state(request.connectionInfo?.remoteAddress.address ?? '?'));
        case ("POST", "/api/add" || "/api/vote"):
          if (request.contentLength > _maxBody) {
            response.statusCode = HttpStatus.requestEntityTooLarge;
            response.persistentConnection = false;
            return;
          }
          final bytes = <int>[];
          await for (final chunk in request) {
            bytes.addAll(chunk);
            // A song request is tiny; don't let anyone on the network fill the phone's memory.
            if (bytes.length > _maxBody) {
              response.statusCode = HttpStatus.requestEntityTooLarge;
              response.persistentConnection = false;
              return;
            }
          }
          final body = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
          final address = request.connectionInfo?.remoteAddress.address ?? '?';
          if (request.uri.path == '/api/vote') {
            await _json(response, {
              'ok': votingEnabled && body['id'] is String && voting.vote(body['id'] as String, address),
            });
            changes.add(null);
          } else {
            await _json(response, await _add(body, address));
          }
        default:
          response.statusCode = HttpStatus.notFound;
      }
    } on FormatException {
      response.statusCode = HttpStatus.badRequest;
    } on TypeError {
      response.statusCode = HttpStatus.badRequest;
    } catch (e) {
      _logger.warning("Party request failed", e);
      response.statusCode = HttpStatus.internalServerError;
    } finally {
      await response.close();
    }
  }

  static Future<void> _json(HttpResponse response, Object body) async {
    response.headers.set(HttpHeaders.contentTypeHeader, "application/json; charset=utf-8");
    response.write(jsonEncode(body));
  }

  static Map<String, dynamic> _track(BaseItemDto track) => {
    "id": track.id.raw,
    "name": track.name ?? "",
    "artist": track.artists?.join(", ") ?? track.albumArtist ?? "",
    "album": track.album ?? "",
  };

  static Future<List<Map<String, dynamic>>> _search(String query) async {
    if (query.trim().length < 2) return [];
    final tracks =
        await GetIt.instance<JellyfinApiHelper>().getItems(
          parentItem: GetIt.instance<FinampUserHelper>().currentUser?.currentView,
          includeItemTypes: BaseItemDtoType.track.jellyfinName,
          searchTerm: query.trim(),
          recursive: true,
          limit: 25,
        ) ??
        [];
    return [for (final track in tracks) _track(track)];
  }

  static Map<String, dynamic> _state(String address) {
    final queue = GetIt.instance<QueueService>().getQueue();
    final current = GetIt.instance<MusicPlayerBackgroundTask>().mediaItem.valueOrNull;
    return {
      "nowPlaying": current == null ? null : {"name": current.title, "artist": current.artist ?? ""},
      "upNext": [
        for (final item in [...queue.nextUp, ...queue.queue].take(10))
          {"name": item.item.title, "artist": item.item.artist ?? ""},
      ],
      "autoAccept": autoAccept,
      'voting': votingEnabled,
      'ballot': [
        for (final request in voting.ranked)
          {
            ..._track(request.track),
            'requestId': request.id,
            'guest': request.guest,
            'votes': request.voters.length,
            'voted': request.voters.contains(address),
          },
      ],
    };
  }

  /// A guest's note for the DJ on one line, without quotes or control characters, at most [maxMessage] long.
  static String cleanMessage(String text) {
    final clean = text.replaceAll(RegExp('[\\x00-\\x1F\\x7F"`“”«»]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    return clean.length > maxMessage ? clean.substring(0, maxMessage).trim() : clean;
  }

  /// The party request behind [item] when the DJ should give it a shout-out, else null.
  static PartyRequest? shoutOutFor(FinampQueueItem item) {
    if (!(running || pretendRunning) || !shoutOuts || item.source.id != sourceId) return null;
    final json = item.item.extras?["itemJson"];
    final id = json is Map ? json["Id"] : null;
    return added.where((request) => request.track.id.raw == id).firstOrNull;
  }

  static Future<Map<String, dynamic>> _add(Map<String, dynamic> body, String address) async {
    final generation = _generation;
    final id = body['id'];
    final guest = body['guest'] is String ? (body['guest'] as String).trim() : '';
    final message = body['message'] is String ? cleanMessage(body['message'] as String) : '';
    if (id is! String || id.isEmpty || id.length > 128) return {"ok": false};
    final initialProblem = _requestProblem(id, address);
    if (initialProblem != null) return initialProblem;
    final tracks = await GetIt.instance<JellyfinApiHelper>().getItems(itemIds: [BaseItemId(id)]);
    final track = tracks?.firstOrNull;
    if (track == null || track.type != 'Audio' || generation != _generation || !running) return {"ok": false};
    // Recheck after the network request: another guest may have submitted concurrently.
    final problem = _requestProblem(track.id.raw, address);
    if (problem != null) return problem;
    final request = PartyRequest(
      track: track,
      guest: guest.isEmpty ? "Guest" : guest.substring(0, min(guest.length, 24)),
      address: address,
      message: message,
    );
    if (autoAccept) {
      if (votingEnabled) {
        if (!voting.add(request)) return {'ok': false, 'tooMany': true};
        changes.add(null);
        return {'ok': true, 'queued': false, 'voting': true};
      }
      return await _addToQueue(request) ? {"ok": true, "queued": true} : {'ok': false, 'tooMany': true};
    }
    if (pending.where((waiting) => waiting.address == address).length >= maxPendingPerGuest) {
      return {"ok": false, "tooMany": true};
    }
    pending.add(request);
    changes.add(null);
    return {"ok": true, "queued": false};
  }

  // The guest page. Plain HTML so it works in any phone browser without installing anything.
  static const _page = r'''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Finamp+ party</title>
<style>
:root{color-scheme:dark;--bg:#12121a;--card:#1f1f2b;--text:#f2f2f7;--muted:#a0a0b4;--accent:#00a4dc}
*{box-sizing:border-box}body{margin:0;font:16px/1.4 system-ui,sans-serif;background:var(--bg);color:var(--text)}
main{max-width:560px;margin:0 auto;padding:16px}h1{font-size:22px;margin:4px 0 12px}
input{width:100%;padding:12px 14px;border-radius:12px;border:1px solid #333;background:var(--card);color:var(--text);font-size:16px}
.row{display:flex;align-items:center;gap:10px;padding:10px 12px;background:var(--card);border-radius:12px;margin:8px 0}
.row div{flex:1;min-width:0}.t{font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.s{color:var(--muted);font-size:14px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
button{background:var(--accent);color:#fff;border:0;border-radius:999px;padding:8px 16px;font-size:15px;font-weight:600}
button:disabled{background:#3a3a4a}h2{font-size:16px;color:var(--muted);margin:20px 0 4px}
#np{border:1px solid var(--accent)}#toast{position:fixed;left:50%;bottom:20px;transform:translateX(-50%);background:#333;padding:10px 16px;border-radius:12px;display:none}
</style></head><body><main>
<h1>🎉 Add a song</h1>
<input id="name" placeholder="Your name (optional)" maxlength="24" style="margin-bottom:8px">
<input id="msg" placeholder="Dedication for the DJ to read out (optional)" maxlength="80" style="margin-bottom:8px">
<input id="q" placeholder="Search for a song title" autocomplete="off" autofocus>
<div id="results"></div>
<h2>Now playing</h2><div id="nowplaying"></div>
<h2>Vote for the next song</h2><div id="ballot"></div>
<h2>Up next</h2><div id="upnext"></div>
</main><div id="toast"></div>
<script>
const key=new URLSearchParams(location.search).get("k");
const $=id=>document.getElementById(id);
const esc=s=>String(s).replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
const name=$("name");try{name.value=localStorage.getItem("partyName")||""}catch(e){}
name.onchange=()=>{try{localStorage.setItem("partyName",name.value)}catch(e){}};
function toast(t){const el=$("toast");el.textContent=t;el.style.display="block";clearTimeout(el.h);el.h=setTimeout(()=>el.style.display="none",2500)}
let timer;$("q").oninput=()=>{clearTimeout(timer);timer=setTimeout(search,300)};
async function search(){const q=$("q").value.trim();if(q.length<2){$("results").innerHTML="";return}
const r=await fetch(`/api/search?k=${key}&q=${encodeURIComponent(q)}`);const items=await r.json();
$("results").innerHTML=items.length?items.map(i=>`<div class="row"><div><div class="t">${esc(i.name)}</div><div class="s">${esc(i.artist)} · ${esc(i.album)}</div></div><button data-id="${esc(i.id)}">Add</button></div>`).join(""):`<p class="s">Nothing found</p>`;
document.querySelectorAll("#results button").forEach(b=>b.onclick=()=>add(b))}
async function send(path,body){const r=await fetch(`${path}?k=${key}`,{method:"POST",body:JSON.stringify(body)});if(!r.ok)throw new Error('Party unavailable');return r.json()}
async function add(b){b.disabled=true;try{const res=await send('/api/add',{id:b.dataset.id,guest:name.value,message:$("msg").value});
if(res.ok){$("msg").value="";b.textContent=res.queued?"Added ✓":"Requested ✓";toast(res.queued?"Added to the queue":res.voting?"Added to voting":"Sent to the host for approval");refresh()}
else{b.disabled=false;toast(res.tooMany?"Wait for your other requests":"That song is already requested or unavailable")}}
catch(e){b.disabled=false;toast('Party unavailable. Reconnect and try again.')}}
async function refresh(){try{const s=await(await fetch(`/api/state?k=${key}`)).json();
$("ballot").innerHTML=s.ballot.map(i=>`<div class="row"><div><div class="t">${esc(i.name)}</div><div class="s">${esc(i.guest)} · ${i.votes} votes</div></div><button data-request="${esc(i.requestId)}" ${i.voted||!s.voting?'disabled':''}>${i.voted?'Voted':'Vote'}</button></div>`).join("")||`<p class="s">Request a song to start voting. Guests take turns when possible.</p>`;
document.querySelectorAll("#ballot button").forEach(b=>b.onclick=async()=>{b.disabled=true;try{await send('/api/vote',{id:b.dataset.request});await refresh()}catch(e){b.disabled=false;toast('Could not save your vote. Try again.')}});
$("nowplaying").innerHTML=s.nowPlaying?`<div class="row" id="np"><div><div class="t">${esc(s.nowPlaying.name)}</div><div class="s">${esc(s.nowPlaying.artist)}</div></div></div>`:`<p class="s">Nothing playing</p>`;
$("upnext").innerHTML=s.upNext.map(i=>`<div class="row"><div><div class="t">${esc(i.name)}</div><div class="s">${esc(i.artist)}</div></div></div>`).join("")||`<p class="s">The queue is empty, add something!</p>`}catch(e){}}
refresh();setInterval(refresh,5000);
</script></body></html>''';
}
