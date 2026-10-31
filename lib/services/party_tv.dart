import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:finamp/services/analyzer_service.dart';
import 'package:finamp/services/jellyfin_api_helper.dart';
import 'package:finamp/services/music_player_background_task.dart';
import 'package:finamp/services/party_service.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:finamp/services/spectrum_reader.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';
import 'package:qr_flutter/qr_flutter.dart' show QrCode, QrErrorCorrectLevel, QrImage;

enum PartyTvStyle { spectrum, wave, ring }

/// The party on a TV: a page for the TV's web browser with the QR code guests scan, what's playing, what's next and a
/// visualizer moving with the music. The phone sends the band levels it measures as it plays, so the TV needs no
/// microphone. Its link has its own key, which only shows the screen: it can't add songs or vote.
class PartyTv {
  PartyTv._();

  static final _logger = Logger("PartyTv");
  static const maxScreens = 4;
  static const maxDelay = Duration(seconds: 1);
  static const _frame = Duration(milliseconds: 33);
  static const _maxArt = 5 << 20;

  static PartyTvStyle style = PartyTvStyle.spectrum;

  /// How long the TV holds the visualizer back, to match speakers that play late, like Bluetooth ones.
  static Duration delay = Duration.zero;
  static bool showUpNext = true;
  static bool showVotes = true;

  static final List<HttpResponse> _screens = [];
  static final List<StreamSubscription<dynamic>> _subscriptions = [];
  static Timer? _bands;
  static Timer? _heartbeat;
  static Timer? _pending;
  static bool _reading = false;
  static bool _silent = false;
  static String? _sent;
  static ({String url, Map<String, Object> code})? _qr;
  static String? _bpmFor;
  static double? _bpm;

  /// How many TVs are showing the party.
  static int get screens => _screens.length;

  /// Serves the TV page, its live feed and the cover of what's playing. Returns true when the response stays open
  /// for the live feed, so the caller mustn't close it.
  static Future<bool> handle(HttpRequest request) async {
    final response = request.response;
    switch ((request.method, request.uri.path)) {
      case ("GET", "/tv"):
        response.headers.set(HttpHeaders.contentTypeHeader, "text/html; charset=utf-8");
        response.write(_page);
      case ("GET", "/tv/events"):
        return _open(response);
      case ("GET", "/tv/art"):
        await _art(request.uri.queryParameters["id"], response);
      default:
        response.statusCode = HttpStatus.notFound;
    }
    return false;
  }

  /// Sends the TVs what they show, when it has changed.
  static void update() {
    if (_screens.isEmpty || _pending != null) return;
    // Changes come in bursts as a song ends and the queue moves on: send them together.
    _pending = Timer(const Duration(milliseconds: 100), () {
      _pending = null;
      if (_screens.isEmpty) return;
      final state = _state();
      if (state == _sent) return;
      _sent = state;
      _broadcast("state", state);
    });
  }

  /// Tells the TVs the party has ended and lets them go. They come back by themselves when the next party starts.
  static Future<void> close() async {
    final screens = [..._screens];
    for (final screen in screens) {
      _write(screen, "end", "{}");
    }
    // Before the party's server shuts, so the TVs hear that it ended rather than losing the phone.
    await Future.wait([
      for (final screen in screens) _drop(screen),
    ]).timeout(const Duration(seconds: 2), onTimeout: () => []);
  }

  /// [levels] from 0 to 1 as two hex digits each, which is all a TV needs 30 times a second.
  static String encodeBands(List<double> levels) =>
      [for (final level in levels) (level.clamp(0.0, 1.0) * 255).round().toRadixString(16).padLeft(2, "0")].join();

  static bool _open(HttpResponse response) {
    // A TV that reloads leaves its old feed behind until the heartbeat notices: the newest takes the oldest's place.
    while (_screens.length >= maxScreens) {
      // Told to stay off: otherwise it would come straight back and push the next one off, round and round.
      final oldest = _screens.first;
      _write(oldest, "replaced", "{}");
      unawaited(_drop(oldest));
    }
    response.bufferOutput = false;
    response.headers.set(HttpHeaders.contentTypeHeader, "text/event-stream; charset=utf-8");
    _screens.add(response);
    // Completes, maybe with an error, when the TV goes away: the heartbeat makes sure a silent one is noticed.
    unawaited(response.done.then((_) {}, onError: (_) {}).whenComplete(() => _drop(response)));
    if (_screens.length == 1) _watch();
    _write(response, "state", _state());
    // The other TVs get any change still waiting to go out, rather than the new one's snapshot hiding it.
    update();
    PartyService.changes.add(null);
    return true;
  }

  static void _write(HttpResponse screen, String event, String data) {
    try {
      screen.write("event: $event\ndata: $data\n\n");
    } catch (_) {
      unawaited(_drop(screen));
    }
  }

  static void _broadcast(String event, String data) {
    for (final screen in [..._screens]) {
      _write(screen, event, data);
    }
  }

  static Future<void> _drop(HttpResponse screen) async {
    if (!_screens.remove(screen)) return;
    if (_screens.isEmpty) _unwatch();
    PartyService.changes.add(null);
    try {
      await screen.close();
    } catch (_) {}
  }

  static void _watch() {
    unawaited(SpectrumReader.setEnabled(true));
    final player = GetIt.instance<MusicPlayerBackgroundTask>();
    _subscriptions.addAll([
      PartyService.changes.stream.listen((_) => update()),
      GetIt.instance<QueueService>().getQueueStream().listen((_) => update()),
      player.mediaItem.listen((_) => update()),
      player.playbackState.map((state) => state.playing).distinct().listen((_) => update()),
    ]);
    _bands = Timer.periodic(_frame, (_) => unawaited(_pump()));
    _heartbeat = Timer.periodic(const Duration(seconds: 15), (_) {
      for (final screen in [..._screens]) {
        try {
          screen.write(":\n\n");
        } catch (_) {
          unawaited(_drop(screen));
        }
      }
    });
  }

  static void _unwatch() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    _bands?.cancel();
    _heartbeat?.cancel();
    _pending?.cancel();
    _bands = _heartbeat = _pending = null;
    _sent = null;
    _silent = false;
    unawaited(SpectrumReader.setEnabled(false));
  }

  static bool get _playing => GetIt.instance<MusicPlayerBackgroundTask>().playbackState.value.playing;

  static Future<void> _pump() async {
    if (_reading || _screens.isEmpty || !_playing) return;
    _reading = true;
    try {
      final levels = await SpectrumReader.read();
      final silent = levels.every((level) => level <= 0);
      // While it's quiet, one silent frame says so.
      if (_screens.isEmpty || (silent && _silent)) return;
      _silent = silent;
      _broadcast("b", encodeBands(levels));
    } finally {
      _reading = false;
    }
  }

  /// What the TVs are shown now.
  @visibleForTesting
  static String stateForTest() => _state();

  static String _state() {
    final queue = GetIt.instance<QueueService>().getQueue();
    final current = queue.currentTrack;
    final item = current?.baseItem;
    final request = current == null ? null : PartyService.requestFor(current);
    final id = item?.id.raw;
    if (id != _bpmFor) {
      _bpmFor = id;
      _bpm = null;
      // For when the phone can't measure the music, like while casting: the TV then pulses to the beat instead.
      if (id != null) unawaited(_loadBpm(id));
    }
    final guestUrl = PartyService.url ?? "";
    final ballot = showVotes && PartyService.votingEnabled
        ? PartyService.voting.ranked.take(3).toList()
        : const <PartyRequest>[];
    return jsonEncode({
      "qr": _qrFor(guestUrl),
      "anywhere": PartyService.relayed,
      "style": style.name,
      "delay": delay.inMilliseconds,
      "playing": _playing,
      "bands": SpectrumReader.available,
      "bpm": _bpm,
      "now": current == null
          ? null
          : {
              "id": id,
              "name": current.item.title,
              "artist": current.item.artist ?? "",
              "art": item?.imageId != null,
              "guest": request?.guest,
              "message": request?.message,
            },
      // As many as fit beside the QR code on a TV.
      "upNext": [
        if (showUpNext)
          for (final next in [...queue.nextUp, ...queue.queue].take(ballot.isEmpty ? 5 : 2))
            {"name": next.item.title, "artist": next.item.artist ?? "", "guest": PartyService.requestFor(next)?.guest},
      ],
      "ballot": [
        for (final request in ballot)
          {
            "name": request.track.name ?? "",
            "artist": request.track.artists?.join(", ") ?? request.track.albumArtist ?? "",
            "guest": request.guest,
            "votes": request.voters.length,
          },
      ],
    });
  }

  static Future<void> _loadBpm(String id) async {
    try {
      final analysis = (await AnalyzerService.cachedAnalysis([id]))[id];
      if (_bpmFor != id) return;
      _bpm = analysis?.beatBpm ?? analysis?.bpm;
      if (_bpm != null) update();
    } catch (_) {}
  }

  /// The QR code for [url] as an SVG path, one unit per module, so the TV draws it without a library or the internet.
  static Map<String, Object> _qrFor(String url) {
    if (_qr?.url == url) return _qr!.code;
    final code = <String, Object>{"size": 0, "path": ""};
    if (url.isNotEmpty) {
      final image = QrImage(QrCode.fromData(data: url, errorCorrectLevel: QrErrorCorrectLevel.M));
      final path = StringBuffer();
      for (var row = 0; row < image.moduleCount; row++) {
        var column = 0;
        while (column < image.moduleCount) {
          if (!image.isDark(row, column)) {
            column++;
            continue;
          }
          final start = column;
          while (column < image.moduleCount && image.isDark(row, column)) {
            column++;
          }
          path.write("M$start ${row}h${column - start}v1h-${column - start}z");
        }
      }
      code
        ..["size"] = image.moduleCount
        ..["path"] = path.toString();
    }
    _qr = (url: url, code: code);
    return code;
  }

  static Future<void> _art(String? id, HttpResponse response) async {
    final item = GetIt.instance<QueueService>().getQueue().currentTrack?.baseItem;
    // Only the cover of what's playing: the TV key mustn't open up the rest of the library.
    final url = item == null || id == null || item.id.raw != id
        ? null
        : GetIt.instance<JellyfinApiHelper>().getImageUrl(item: item, maxWidth: 640, maxHeight: 640);
    if (url == null) {
      response.statusCode = HttpStatus.notFound;
      return;
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final upstream = await (await client.getUrl(url)).close().timeout(const Duration(seconds: 15));
      final bytes = BytesBuilder(copy: false);
      if (upstream.statusCode == HttpStatus.ok) {
        await for (final chunk in upstream.timeout(const Duration(seconds: 15))) {
          bytes.add(chunk);
          if (bytes.length > _maxArt) break;
        }
      }
      if (upstream.statusCode != HttpStatus.ok || bytes.length > _maxArt) {
        response.statusCode = HttpStatus.notFound;
        return;
      }
      response.headers.set(HttpHeaders.contentTypeHeader, upstream.headers.contentType?.toString() ?? "image/jpeg");
      response.add(bytes.takeBytes());
    } catch (error) {
      _logger.info("Couldn't fetch the cover for the party TV", error);
      response.statusCode = HttpStatus.notFound;
    } finally {
      client.close(force: true);
    }
  }

  // The TV page. Plain HTML and a canvas, written for older TV browsers too, without anything from the internet.
  static const _page = r'''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Finamp+ party</title>
<style>
:root{color-scheme:dark;--text:#f5f5fa;--muted:rgba(245,245,250,.7);--glass:rgba(10,10,18,.58);--line:rgba(255,255,255,.12);--accent:#5cc8f0}
*{box-sizing:border-box}
html,body{margin:0;height:100%;overflow:hidden;background:#05050a;color:var(--text);font-family:system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
#viz{position:fixed;top:0;left:0;width:100%;height:100%}
#stage{position:fixed;top:0;left:0;right:0;bottom:0;display:flex;padding:5vh 4vw;gap:4vw}
#now{flex:1;display:flex;flex-direction:column;justify-content:flex-end;min-width:0}
#art{width:36vh;height:36vh;border-radius:2.2vh;object-fit:cover;box-shadow:0 2vh 6vh rgba(0,0,0,.55);margin-bottom:3.5vh;display:none}
#art.on{display:block}
#title{font-size:6.4vh;font-weight:800;line-height:1.1;overflow:hidden;text-overflow:ellipsis;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;text-shadow:0 .4vh 2vh rgba(0,0,0,.6)}
#artist{font-size:3.6vh;color:var(--muted);margin-top:1vh;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
#by{font-size:2.8vh;margin-top:1.6vh;color:var(--accent);font-weight:600;min-height:3.4vh}
#side{width:30vw;max-width:58vh;min-width:34vh;display:flex;flex-direction:column;gap:2vh;min-height:0;overflow:hidden}
.card{background:var(--glass);border:1px solid var(--line);border-radius:2.4vh;padding:2vh 2.2vh;flex:none}
#ballotCard,#upnextCard{flex:0 1 auto;min-height:0;overflow:hidden}
#qrbox{background:#fff;border-radius:1.6vh;padding:1.2vh;line-height:0;width:25vh;max-width:100%;margin:0 auto}
#qrsvg{width:100%;height:auto}
#scan{font-size:3.2vh;font-weight:800;text-align:center;margin-top:1.4vh}
#scan2{font-size:2vh;color:var(--muted);text-align:center;margin-top:.6vh}
h2{font-size:2vh;letter-spacing:.14em;text-transform:uppercase;color:var(--muted);margin:0 0 1vh;font-weight:700}
.list{overflow:hidden}.row{display:flex;gap:1.4vh;align-items:center;padding:.6vh 0;border-top:1px solid var(--line)}
.row:first-child{border-top:0}.row div{flex:1;min-width:0}
.t{font-size:2.3vh;font-weight:650;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.s{font-size:1.8vh;color:var(--muted);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.votes{font-size:2.6vh;font-weight:800;color:var(--accent)}
.hidden{display:none}
#toast{position:fixed;top:4vh;left:50%;max-width:80vw;transform:translate(-50%,-40vh);transition:transform .7s cubic-bezier(.2,.9,.3,1.2);background:var(--glass);border:1px solid var(--line);border-radius:3vh;padding:2.2vh 3.4vh;text-align:center}
#toast.on{transform:translate(-50%,0)}
#toastWho{font-size:3.2vh;font-weight:800}#toastMsg{font-size:2.6vh;color:var(--muted);margin-top:.6vh}
#overlay{position:fixed;top:0;left:0;right:0;bottom:0;display:none;align-items:center;justify-content:center;flex-direction:column;background:rgba(5,5,10,.82);text-align:center;padding:8vh}
#overlay.on{display:flex}#overlayTitle{font-size:5vh;font-weight:800}#overlayText{font-size:2.8vh;color:var(--muted);margin-top:2vh}
#fs{position:fixed;left:2vh;top:2vh;background:var(--glass);color:var(--text);border:1px solid var(--line);border-radius:999px;padding:1.2vh 2.4vh;font-size:2vh;transition:opacity .5s}
body.idle #fs{opacity:0}body.idle{cursor:none}
@media (max-aspect-ratio:1/1){#stage{flex-direction:column-reverse;padding:9vh 5vw 4vh;gap:3vh}#side{width:auto;max-width:none;min-width:0;flex:none;overflow:visible}#qrbox{width:24vh}#art{width:20vh;height:20vh;margin-bottom:2vh}#title{font-size:4.4vh}#artist{font-size:2.6vh}#by{font-size:2.2vh}#upnextCard,#ballotCard{display:none}}
</style></head><body>
<canvas id="viz"></canvas>
<div id="stage">
<div id="now"><img id="art" alt=""><div id="title">Getting the party ready…</div><div id="artist"></div><div id="by"></div></div>
<div id="side">
<div class="card"><div id="qrbox"><svg id="qrsvg" viewBox="0 0 1 1" xmlns="http://www.w3.org/2000/svg"><path id="qrpath" d="" fill="#000"/></svg></div>
<div id="scan">Scan to add songs</div><div id="scan2">Same Wi-Fi as the host, no app needed</div></div>
<div class="card hidden" id="ballotCard"><h2>Vote now</h2><div class="list" id="ballot"></div></div>
<div class="card hidden" id="upnextCard"><h2>Up next</h2><div class="list" id="upnext"></div></div>
</div></div>
<div id="toast"><div id="toastWho"></div><div id="toastMsg"></div></div>
<div id="overlay"><div id="overlayTitle"></div><div id="overlayText"></div></div>
<button id="fs">Full screen</button>
<script>
var key=new URLSearchParams(location.search).get("t")||"";
var $=function(id){return document.getElementById(id)};
var BANDS=32,DEFAULT=[[0,164,220],[123,92,255],[255,79,163]];
var state=null,frames=[],current=null,lastFrame=0,lastReal=-1e9,levels=[],palette=DEFAULT,artId=null,shown,qrPath=null,ended=false,toastTimer=0;
for(var i=0;i<BANDS;i++)levels.push(0);
function decode(hex){var out=[];for(var i=0;i+1<hex.length&&out.length<BANDS;i+=2)out.push(parseInt(hex.substr(i,2),16)/255);while(out.length<BANDS)out.push(0);return out}
function overlay(title,text){$("overlayTitle").textContent=title;$("overlayText").textContent=text;$("overlay").className=title?"on":""}
function fill(id,items,detail){var list=$(id);list.textContent="";
items.forEach(function(item){var row=document.createElement("div");row.className="row";var body=document.createElement("div");
var t=document.createElement("div");t.className="t";t.textContent=item.name;var s=document.createElement("div");s.className="s";s.textContent=detail(item);
body.appendChild(t);body.appendChild(s);row.appendChild(body);
if(item.votes!==undefined){var v=document.createElement("span");v.className="votes";v.textContent=String(item.votes);row.appendChild(v)}
list.appendChild(row)});
$(id+"Card").className=items.length?"card":"card hidden"}
function toast(who,message){$("toastWho").textContent="🎤 Requested by "+who;$("toastMsg").textContent=message?"“"+message+"”":"";
$("toast").className="on";clearTimeout(toastTimer);toastTimer=setTimeout(function(){$("toast").className=""},9000)}
function render(s){state=s;ended=false;overlay("","");
$("scan2").textContent=s.anywhere?"From any network, no app needed":"Same Wi-Fi as the host, no app needed";
if(s.qr&&s.qr.path!==qrPath){qrPath=s.qr.path;$("qrsvg").setAttribute("viewBox","-2 -2 "+(s.qr.size+4)+" "+(s.qr.size+4));$("qrpath").setAttribute("d",s.qr.path)}
var n=s.now;$("title").textContent=n?n.name:"Nothing playing yet";
$("artist").textContent=n?n.artist:"Scan the code and pick the first song";
$("by").textContent=n&&n.guest?"Requested by "+n.guest:"";
var id=n&&n.art?n.id:null;
if(id!==artId){artId=id;var art=$("art");art.className="";if(id)art.src="/tv/art?t="+encodeURIComponent(key)+"&id="+encodeURIComponent(id);else{art.removeAttribute("src");palette=DEFAULT}}
var nowId=n?n.id:null;if(shown!==undefined&&nowId!==shown&&n&&n.guest)toast(n.guest,n.message);shown=nowId;
fill("upnext",s.upNext,function(i){return i.guest?i.artist+" · for "+i.guest:i.artist});
fill("ballot",s.ballot,function(i){return i.artist+" · "+i.guest})}
function hue(r,g,b){var max=Math.max(r,g,b),min=Math.min(r,g,b),d=max-min;if(!d)return 0;var h=max===r?(g-b)/d%6:max===g?(b-r)/d+2:(r-g)/d+4;return(h<0?h+6:h)/6}
function pickPalette(data){var buckets=[];for(var k=0;k<12;k++)buckets.push({w:0,r:0,g:0,b:0});
for(var i=0;i+3<data.length;i+=4){var r=data[i],g=data[i+1],b=data[i+2],max=Math.max(r,g,b),min=Math.min(r,g,b),sat=max?(max-min)/max:0,val=max/255;
if(sat<.25||val<.2)continue;var w=sat*val,bucket=buckets[Math.floor(hue(r,g,b)*12)%12];bucket.w+=w;bucket.r+=r*w;bucket.g+=g*w;bucket.b+=b*w}
var picked=buckets.filter(function(b){return b.w>0}).sort(function(a,b){return b.w-a.w}).slice(0,3).map(function(b){
var c=[b.r/b.w,b.g/b.w,b.b/b.w],lift=200/Math.max(c[0],c[1],c[2],1);if(lift<1)lift=1;return c.map(function(v){return Math.round(Math.min(255,v*lift))})});
while(picked.length&&picked.length<3)picked.push(picked[picked.length-1].map(function(v,i){return picked[0][(i+1)%3]}));
return picked.length?picked:DEFAULT}
$("art").onload=function(){var art=$("art");art.className="on";try{var c=document.createElement("canvas");c.width=c.height=24;var x=c.getContext("2d");x.drawImage(art,0,0,24,24);palette=pickPalette(x.getImageData(0,0,24,24).data)}catch(e){}};
$("art").onerror=function(){$("art").className="";palette=DEFAULT};
function onBands(hex,now){frames.push({at:now,v:decode(hex)});if(frames.length>90)frames.shift()}
// The levels to show at [now]: frames are held back by the host's delay, rise fast and fall slowly like a meter.
function advance(now){var delay=state?state.delay:0,playing=!!(state&&state.playing);
while(frames.length&&frames[0].at<=now-delay){current=frames.shift().v;lastFrame=now;
for(var i=0;i<BANDS;i++)if(current[i]>.02){lastReal=now;break}}
if(now-lastFrame>400)current=null;
var synth=playing&&(!state.bands||now-lastReal>2500),bpm=state&&state.bpm?state.bpm:112;
var phase=(now/1000*bpm/60)%1,kick=Math.exp(-phase*6);
for(var i=0;i<BANDS;i++){var target;
if(!playing)target=.05+.035*Math.sin(now/900+i*.5);
else if(synth)target=Math.max(0,kick*(1-i/BANDS*.85)*.8+.12+.08*Math.sin(now/380+i*.7));
else target=current?current[i]:0;
levels[i]=target>levels[i]?target:levels[i]*.9+target*.1}
return levels}
function mix(t){var p=palette,s=t*(p.length-1),k=Math.min(p.length-2,Math.floor(s)),f=s-k,a=p[k],b=p[k+1];
return[a[0]+(b[0]-a[0])*f,a[1]+(b[1]-a[1])*f,a[2]+(b[2]-a[2])*f]}
function rgba(c,a){return"rgba("+Math.round(c[0])+","+Math.round(c[1])+","+Math.round(c[2])+","+a+")"}
function level(u){var x=Math.min(1,Math.max(0,u))*(BANDS-1),k=Math.floor(x),f=x-k;return levels[k]*(1-f)+(levels[Math.min(BANDS-1,k+1)]||0)*f}
var canvas=$("viz"),ctx=canvas.getContext("2d"),W=0,H=0;
function resize(){W=canvas.width=window.innerWidth;H=canvas.height=window.innerHeight}
function draw(now){var bass=(levels[0]+levels[1]+levels[2]+levels[3]+levels[4])/5,style=state?state.style:"spectrum";
var bg=ctx.createRadialGradient(W*.35,H*.6,0,W*.35,H*.6,Math.max(W,H)*.9);
bg.addColorStop(0,rgba(mix(.2).map(function(v){return v*(.16+.3*bass)}),1));bg.addColorStop(1,"#05050a");ctx.fillStyle=bg;ctx.fillRect(0,0,W,H);
if(style==="wave"){var mid=H*.5;for(var layer=2;layer>=0;layer--){ctx.beginPath();
var top=[];for(var x=0;x<=W;x+=8){var u=Math.abs(x/W*2-1),amp=(.02+level(u)*.3)*H*(1-layer*.22),wob=.65+.35*Math.sin(x*.011+now*.0016*(layer+1)+layer*2);top.push([x,mid-amp*wob])}
ctx.moveTo(0,mid);top.forEach(function(p){ctx.lineTo(p[0],p[1])});for(var j=top.length-1;j>=0;j--)ctx.lineTo(top[j][0],2*mid-top[j][1]);ctx.closePath();
ctx.fillStyle=rgba(mix(layer/2),.16+layer*.04);ctx.fill();ctx.strokeStyle=rgba(mix(layer/2),.55);ctx.lineWidth=2;ctx.stroke()}}
else if(style==="ring"){var art=$("art"),r=art.className==="on"?art.getBoundingClientRect():null,from=r?r.right:0,to=$("side").getBoundingClientRect().left,
wide=to-from>H*.5,cx=wide?(from+to)/2:W/2,cy=wide?H*.45:H*.3,radius=Math.min(wide?to-from:W,H)*.2*(1+bass*.06),count=96;
var glow=ctx.createRadialGradient(cx,cy,0,cx,cy,radius);glow.addColorStop(0,rgba(mix(.5),.18+.3*bass));glow.addColorStop(1,rgba(mix(.5),0));
ctx.fillStyle=glow;ctx.beginPath();ctx.arc(cx,cy,radius,0,2*Math.PI);ctx.fill();ctx.lineCap="round";ctx.lineWidth=Math.max(3,2*Math.PI*radius/count*.5);
for(var k=0;k<count;k++){var band=k<count/2?k/(count/2):(count-k)/(count/2),len=6+level(band)*radius*.75,a=k/count*2*Math.PI-Math.PI/2;
ctx.strokeStyle=rgba(mix(band),.85);ctx.beginPath();ctx.moveTo(cx+Math.cos(a)*radius,cy+Math.sin(a)*radius);ctx.lineTo(cx+Math.cos(a)*(radius+len),cy+Math.sin(a)*(radius+len));ctx.stroke()}}
else{var bars=64,slot=W/bars;ctx.lineCap="round";ctx.lineWidth=slot*.55;
for(var b=0;b<bars;b++){var u2=Math.abs((b+.5)/bars*2-1),h=Math.max(6,level(u2)*H*.42),x2=slot*(b+.5);
ctx.strokeStyle=rgba(mix(u2),.45);ctx.beginPath();ctx.moveTo(x2,H);ctx.lineTo(x2,H-h);ctx.stroke()}}}
function frame(now){advance(now);draw(now);requestAnimationFrame(frame)}
function connect(){var source=new EventSource("/tv/events?t="+encodeURIComponent(key));
source.addEventListener("state",function(e){render(JSON.parse(e.data))});
source.addEventListener("b",function(e){onBands(e.data,performance.now())});
source.addEventListener("replaced",function(){source.close();overlay("Another screen took this one's place","Too many screens are showing the party. Reload this page to bring it back.")});
source.addEventListener("end",function(){ended=true;overlay("The party has ended","This screen comes back by itself when the host starts the next party.")});
source.onerror=function(){if(source.readyState!==2){if(!ended)overlay("Reconnecting…","Looking for the host's phone on the Wi-Fi.");return}
// The feed was refused: only a link the phone no longer knows has expired, anything else is tried again.
fetch("/tv?t="+encodeURIComponent(key),{cache:"no-store"}).then(function(r){return r.status},function(){return 0}).then(function(status){
if(status===403)overlay("This TV link has expired","Open the TV link shown in Finamp's Party mode.");
else{if(!ended)overlay("Reconnecting…","Looking for the host's phone on the Wi-Fi.");setTimeout(connect,3000)}})};
return source}
$("fs").onclick=function(){var el=document.documentElement,go=el.requestFullscreen||el.webkitRequestFullscreen;if(go)go.call(el)};
var idleTimer=0;function wake(){document.body.className="";clearTimeout(idleTimer);idleTimer=setTimeout(function(){document.body.className="idle"},3000)}
function lock(){try{if(navigator.wakeLock)navigator.wakeLock.request("screen").catch(function(){})}catch(e){}}
document.addEventListener("mousemove",wake);document.addEventListener("keydown",wake);
document.addEventListener("visibilitychange",function(){if(!document.hidden)lock()});
window.addEventListener("resize",resize);resize();wake();lock();connect();requestAnimationFrame(frame);
</script></body></html>''';
}
