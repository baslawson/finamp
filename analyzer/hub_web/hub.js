'use strict';
const root = document.getElementById('app');
const base = location.pathname.slice(0, location.pathname.lastIndexOf('/hub/') + 4);
const page = location.pathname.slice(base.length).split('/').filter(Boolean)[0] || 'home';
let token = decodeURIComponent(location.hash.slice(1)) || sessionStorage.getItem(`finamp.hub.${page}`) || '';
if (token) sessionStorage.setItem(`finamp.hub.${page}`, token);
if (location.hash) history.replaceState(null, '', location.pathname);
let roomState, pollTimer, tab = 'radio', settings, status, busy = false;
function el(tag, text, className) {
  const element = document.createElement(tag);
  if (text != null) element.textContent = text;
  if (className) element.className = className;
  return element;
}
function append(parent, ...children) { children.filter(Boolean).forEach(child => parent.append(child)); return parent; }
function button(text, action, secondary = false) {
  const value = el('button', text, secondary ? 'secondary' : '');
  value.type = 'button'; value.onclick = () => act(action, value); return value;
}
function notice(message) {
  const node = document.getElementById('notice'); node.textContent = message; node.style.display = 'block';
  clearTimeout(notice.timer); notice.timer = setTimeout(() => node.style.display = 'none', 6000);
}
async function api(path, method = 'GET', data, capability = token, extra = {}) {
  const controller = new AbortController(); const timer = setTimeout(() => controller.abort(), 12000);
  try {
    const response = await fetch(base + path, {method, signal: controller.signal, cache:'no-store',
      headers: {...(capability ? {'Authorization': 'Bearer ' + capability} : {}), ...(data !== undefined ? {'Content-Type':'application/json'} : {}), ...extra},
      ...(data !== undefined ? {body:JSON.stringify(data)} : {})});
    if (!response.ok) {
      let message = 'Server request failed';
      try { const error = await response.json(); if (typeof error.detail === 'string') message = error.detail; } catch (_) {}
      const failure = new Error(message); failure.status = response.status; throw failure;
    }
    document.getElementById('connection').textContent = 'Connected';
    return await response.json();
  } finally { clearTimeout(timer); }
}
async function act(action, control) {
  if (busy) return;
  busy = true; if (control) control.disabled = true;
  try { await action(); } catch (error) { notice(error.name === 'AbortError' ? 'The server took too long. Try again.' : error.message); }
  finally { busy = false; if (control) control.disabled = false; }
}
function card(title, help) {
  const value = el('section', null, 'card'); append(value, el('h2', title), help ? el('p', help, 'muted') : null); return value;
}
function input(parent, label, value, type = 'text', min, max) {
  const wrap = el('label', label), field = el('input'); field.type = type; field.value = value ?? '';
  if (min !== undefined) field.min = min; if (max !== undefined) field.max = max;
  append(parent, append(wrap, field)); return field;
}
function check(parent, label, value) {
  const wrap = el('label', null, 'check'), field = el('input'); field.type = 'checkbox'; field.checked = value;
  append(parent, append(wrap, field, el('span', label))); return field;
}
function select(parent, label, value, options) {
  const wrap = el('label', label), field = el('select');
  options.forEach(([key, text]) => { const option = el('option', text); option.value = key; field.append(option); });
  field.value = value; append(parent, append(wrap, field)); return field;
}
function time(value) { value = Math.max(0, Math.floor((value || 0) / 1000)); return `${Math.floor(value / 60)}:${String(value % 60).padStart(2,'0')}`; }
function date(value) { return value ? new Date(value * 1000).toLocaleString() : 'Not yet'; }
// A guest's link uses the server's public address when it has one, so it works away from the home network too.
function link(pageName, capability, publicUrl) { return (publicUrl ? publicUrl + '/hub' : location.origin + base) + '/' + pageName + '/#' + encodeURIComponent(capability); }
async function copy(value) { try { await navigator.clipboard.writeText(value); notice('Link copied'); } catch (_) { prompt('Copy this link:', value); } }
function showPairing() {
  root.replaceChildren(el('h1','Karaoke on your TV'));
  const panel = card('Connect this screen', 'In Finamp, open Settings → Server hub → TV karaoke. Enter the code shown on your phone.');
  const code = input(panel, 'Pairing code', '', 'text'); code.inputMode = 'numeric'; code.maxLength = 6;
  panel.append(button('Connect TV', async () => {
    const result = await api('/api/pair', 'POST', {code:code.value}, '');
    token = result.token; sessionStorage.setItem('finamp.hub.tv', token); startTv();
  })); root.append(panel);
}

async function admin() {
  if (!token) return welcome();
  clearTimeout(pollTimer);
  try {
    status = await api('/api/status');
    if (status.administrator) settings = await api('/api/settings');
    root.replaceChildren(el('h1', 'Your music, around the house'), el('p', `Welcome, ${status.user}. Your server keeps working when your phone is away.`, 'muted'));
    const navigation = el('nav');
    const sections = status.administrator ? [['radio','Radio'],['tv','TV karaoke'],['nightly','Overnight'],['lyrics','Lyrics'],['health','Audio health'],['sync','Across devices'],['backups','Backups'],['runtime','Server status']] : [['tv','TV karaoke'],['sync','Across devices']];
    if (!sections.some(([key]) => key === tab)) tab = sections[0][0];
    sections.forEach(([key, name]) => {
      const control = button(name, async () => { tab = key; await admin(); }); control.className = 'tab' + (tab === key ? ' active' : ''); navigation.append(control);
    }); root.append(navigation);
    if (tab === 'radio') await radioAdmin();
    if (tab === 'tv') await tvAdmin();
    if (tab === 'nightly') await overnightAdmin();
    if (tab === 'health') await healthAdmin();
    if (tab === 'backups') await backupAdmin();
    if (tab === 'lyrics') await lyricsAdmin();
    if (tab === 'sync') await syncAdmin();
    if (tab === 'runtime') await runtimeAdmin();
    if (status.administrator && !['tv','sync'].includes(tab)) {
      const jobs = await api('/api/jobs');
      const panel = card('Recent server jobs');
      jobs.slice(0,8).forEach(job => append(panel, append(el('div',null,'song'), append(el('div'), el('strong', `${job.kind} · ${job.state}`), el('small', job.message)))));
      if (!jobs.length) panel.append(el('p','Jobs will appear here when scheduled or started.','muted'));
      panel.append(button('Refresh status', admin, true)); root.append(panel);
    }
  } catch (error) { failed(error); }
}
async function runtimeAdmin() {
  const state = await api('/api/runtime');
  const panel = card('Listening comes first', state.policy || 'Background workload status');
  const machine = state.machine;
  if (machine) {
    const stats = el('div', null, 'field-grid');
    const memory = machine.memoryAvailable == null ? 'Unavailable' : `${Math.round(machine.memoryAvailable / 1048576)} MB`;
    const free = `${(machine.diskFree / 1073741824).toFixed(1)} GB`;
    const players = state.playback?.available ? String(state.playback.players) : 'Checking';
    [[players,'Active players'],[memory,'Available memory'],[free,'Free working space'],
      [`${machine.load[0].toFixed(2)} / ${machine.cpus} cores`,'Server load']].forEach(([value,label])=>{
        append(stats,append(el('div',null,'card'),el('h3',value),el('p',label,'muted')));
      });
    panel.append(stats);
  }
  (state.warnings || []).forEach(message => panel.append(el('p', message, 'pill')));
  const workers = state.workers || [];
  workers.forEach(worker => append(panel, append(el('div',null,'song'),
    append(el('div'),el('strong',`${worker.worker} · ${worker.state}`),el('small',worker.message)))));
  if (!workers.length) panel.append(el('p','No background worker has reported recent status.','muted'));
  append(panel,el('p','Running audio is left alone. New heavy jobs wait when memory, storage or playback need the capacity.','muted'),
    button('Refresh server status',admin,true));
  root.append(panel);
  const queued = card('Background queue');
  const jobs = state.jobs || [];
  jobs.forEach(job => append(queued, append(el('div',null,'song'),append(el('div'),
    el('strong',`${job.kind} · ${job.state}`),
    el('small',job.message),
    el('small',`${Math.floor(job.ageSeconds / 60)} minutes since queued${job.attention ? ' · Taking longer than expected; check the worker status above' : ''}`)))));
  if (!jobs.length) queued.append(el('p','No background jobs are waiting.','muted'));
  if (state.requests) queued.append(el('p',`Jellyfin requests: ${state.requests.requests}. Recent response time (95th percentile): ${state.requests.recentP95Ms ?? '—'} ms.`,'muted'));
  root.append(queued);
}
async function save(values) { settings = await api('/api/settings','PUT',values); notice('Saved'); }
async function job(kind, extra = {}) { await api('/api/jobs','POST',{kind,...extra}); notice('Added to the server queue'); }
async function radioAdmin() {
  const state = await api('/api/radio');
  const panel = card('A station that stays on', 'The server broadcasts whenever someone is listening, and rests when nobody is. Closing Finamp does not stop it. Share the listening link with your household.');
  append(panel, el('h3', state.song?.name || state.message), el('p', state.song?.artist || '', 'muted'));
  const enabled = check(panel, 'Station on', settings.radioEnabled);
  const program = select(panel, 'What to play', settings.radioProgram, [['scheduled','Follow the daily schedule'], ...settings.radioPrograms.map(p => [p.id,p.name])]);
  panel.append(button('Save station', async () => { await save({radioEnabled:enabled.checked,radioProgram:program.value}); await admin(); }));
  append(panel, el('p',`Schedule uses ${settings.timezone}.`,'muted'), button('Open player', () => window.open(link('listen',state.token),'_blank','noopener'),true), button('Copy listening link',() => copy(link('listen',state.token)),true));
  root.append(panel);
  const schedule = card('Daily programs','Each program starts at its hour and continues until the next. A song finishes before the program changes.');
  const timezone=input(schedule,'Time zone',settings.timezone);
  const fields = settings.radioPrograms.map(p => {
    const row = el('div', null, 'card');
    const name = input(row,'Program name',p.name), hour = input(row,'Start hour (0–23)',p.start,'number',0,23);
    const mode = select(row,'Music',p.mode,[['favourites','Favourites'],['discovery','Discovery'],['chill','Calmer songs']]);
    const discovery = input(row,'Target unplayed songs (%)',p.discovery,'number',0,100);
    schedule.append(row); return {p,name,hour,mode,discovery};
  });
  schedule.append(button('Save schedule', async () => { await save({timezone:timezone.value,radioPrograms:fields.map(f => ({id:f.p.id,name:f.name.value,start:Number(f.hour.value),mode:f.mode.value,discovery:Number(f.discovery.value)}))}); await admin(); }));
  schedule.append(el('p','You can create a station introduction using your DJ voice in Finamp → Server hub.','muted'));
  for (const id of state.introductions || []) {
    const program=settings.radioPrograms.find(p=>p.id===id);
    if(program)schedule.append(button('Remove '+program.name+' introduction',async()=>{await api('/api/radio/announcement/'+id,'DELETE');await admin();},true));
  }
  root.append(schedule);
}
async function tvAdmin() {
  const panel = card('Put karaoke on a bigger screen','Create a room, open the TV page on a TV or laptop, and enter its pairing code. Your phone becomes the remote.');
  const name = input(panel,'Room name','Karaoke party');
  panel.append(button('Create TV room', async () => { const room = await api('/api/rooms','POST',{name:name.value}); showRoom(panel,room); }));
  const existing = await api('/api/rooms');
  existing.forEach(room => {
    const row = append(el('div',null,'song'),el('strong',room.name));
    append(row, append(el('div',null,'row'), button('Open',async()=>showRoom(panel,await api('/api/rooms/'+room.id+'/links','POST')),true),
      button('Close',async()=>{ if(confirm('Close this TV room and its links?')) { await api('/api/rooms/'+room.id,'DELETE'); await admin(); } },true)));
    panel.append(row);
  }); root.append(panel);
}
function showRoom(panel,room) {
  panel.querySelector('.room-links')?.remove();
  const links = card(room.name, 'Open this address on your TV or laptop, then enter the code:'); links.classList.add('room-links');
  append(links,el('p',location.origin + base + '/tv/'),el('p',room.code,'code'),el('small','Pairing code lasts ten minutes. The room lasts six hours.'),
    append(el('div',null,'row'),button('Open TV screen',()=>window.open(link('tv',room.screen),'_blank','noopener')),button('Open phone remote',()=>window.open(link('remote',room.control),'_blank','noopener'),true),button('Copy TV link',()=>copy(link('tv',room.screen)),true)));
  panel.append(links);
}
async function overnightAdmin() {
  const panel = card('Ready before the party','Karaoke preparation runs one song at a time. Overnight jobs add a small batch while the server is quiet.');
  const enabled = check(panel,'Prepare karaoke overnight',settings.nightlyEnabled), favorites = check(panel,'Include my favourites',settings.nightlyFavorites);
  const grid = el('div',null,'field-grid');
  const start = input(grid,'Start hour',settings.nightlyStart,'number',0,23), end = input(grid,'End hour',settings.nightlyEnd,'number',1,24), limit = input(grid,'New songs per night',settings.nightlyLimit,'number',1,20); panel.append(grid);
  const chosen = new Set(settings.nightlySongs);
  panel.append(el('h3','Chosen songs'));
  const selected=el('div',null,'list'),count=el('p',null,'muted');panel.append(selected,count);
  const details=new Map((await api('/api/nightly/songs')).map(song=>[song.id,song]));
  const renderChosen=()=>{selected.replaceChildren();count.textContent=`${chosen.size} songs selected. Favourites are included separately.`;for(const id of chosen){const song=details.get(id);selected.append(append(el('div',null,'song'),append(el('div'),el('strong',song?.name||'Unavailable song'),el('small',song?.artist||'')),button('Remove',async()=>{chosen.delete(id);renderChosen();},true)));}};
  renderChosen();
  const search = input(panel,'Find a song to prepare','');
  const results = el('div',null,'list'); panel.append(results);
  search.oninput = debounce(async()=>{
    const songs = await api('/api/search?q='+encodeURIComponent(search.value)); results.replaceChildren();
    songs.forEach(song=>{
      const row = append(el('div',null,'song'), append(el('div'),el('strong',song.name),el('small',song.artist)));
      details.set(song.id,song);row.append(button(chosen.has(song.id)?'Remove':'Add',async()=>{ chosen.has(song.id)?chosen.delete(song.id):chosen.add(song.id); row.lastChild.textContent=chosen.has(song.id)?'Remove':'Add';renderChosen(); },true)); results.append(row);
    });
  });
  append(panel, button('Save overnight plan',async()=>{ await save({nightlyEnabled:enabled.checked,nightlyFavorites:favorites.checked,nightlyStart:Number(start.value),nightlyEnd:Number(end.value),nightlyLimit:Number(limit.value),nightlySongs:[...chosen]}); await admin(); }), button('Queue a batch now',()=>job('nightly'),true));
  root.append(panel);
  const cache = card('Keep cache storage under control','Old, unused server mixes can expire. Chosen songs, favourites and active TV-room songs are protected. Original music is preserved.');
  const size = input(cache,'Maximum karaoke cache (GB)',settings.cacheGB,'number',1,100), days = input(cache,'Expire unused mixes after (days)',settings.cacheDays,'number',1,365);
  append(cache,button('Save cache limits',()=>save({cacheGB:Number(size.value),cacheDays:Number(days.value)})),button('Clean unused mixes now',async()=>{if(confirm('Apply these cache limits and remove eligible server mixes?')) await job('cleanup');},true)); root.append(cache);
}
async function healthAdmin() {
  const [health,sync] = await Promise.all([api('/api/health'),api('/api/sync')]);
  const panel = card('Catch problem recordings','This scan decodes the audio, including warnings that a metadata check can miss. A warning does not always mean a song is unplayable.');
  const stats = el('div',null,'stats');
  [['healthy','Checked OK'],['warning','Warnings'],['broken','Failed']].forEach(([key,label])=>append(stats,append(el('div'),el('b',health.counts[key]||0),el('small',label)))); panel.append(stats);
  const enabled = check(panel,'Skip failed recordings in generated mixes',sync.guard), warnings=check(panel,'Also skip recordings with decoder warnings',sync.includeWarnings);
  append(panel,button('Save playback guard',async()=>{await api('/api/sync','PATCH',{guard:enabled.checked,includeWarnings:warnings.checked});notice('Playback guard saved');}),button('Check 100 new or changed songs',()=>job('health'),true));
  const list=el('div',null,'list'); health.items.filter(x=>x.state!=='healthy').slice(0,100).forEach(item=>append(list,append(el('div',null,'song'),append(el('div'),el('strong',item.song.name),el('small',`${item.song.artist} · ${item.state}${item.warnings?' · '+item.warnings+' decoder messages':''}`))))); panel.append(list); root.append(panel);
}
async function backupAdmin() {
  const backups=await api('/api/backups');
  const panel=card('A restore point for your server','Backups include Jellyfin settings and database, plus Finamp analysis, stations and history. Each archive is restored into a separate verification folder before it is marked verified.');
  const enabled=check(panel,'Create a daily backup',settings.backupEnabled), grid=el('div',null,'field-grid');
  const hour=input(grid,'Hour',settings.backupHour,'number',0,23), minute=input(grid,'Minute',settings.backupMinute,'number',0,59), keep=input(grid,'Backups to keep',settings.backupKeep,'number',2,30); panel.append(grid);
  append(panel,button('Save backup schedule',()=>save({backupEnabled:enabled.checked,backupHour:Number(hour.value),backupMinute:Number(minute.value),backupKeep:Number(keep.value)})),button('Create backup now',()=>job('backup'),true),el('p','Downloaded backups contain private server settings. Keep them somewhere private.','muted'));
  backups.forEach(backup=>{
    const row=append(el('div',null,'song'),append(el('div'),el('strong',date(backup.created)),el('small',`${(backup.bytes/1048576).toFixed(1)} MB · ${backup.verified?'Restore verified':'Not yet verified'}`)));
    append(row,append(el('div',null,'row'),button('Download',async()=>{const result=await api('/api/backups/'+backup.id+'/download','POST'); location.assign(base+'/api/download/'+result.ticket);},true),button('Verify',()=>job('verify',{id:backup.id}),true))); panel.append(row);
  }); if(!backups.length)panel.append(el('p','The first scheduled backup will appear here.','empty'));root.append(panel);
}
async function lyricsAdmin() {
  const lyrics=await api('/api/lyrics');
  const panel=card('Lyrics, ready when you press play','The lyrics service checks available timed lyrics in the background. Missing matches are retried gradually, and existing synced lyrics are kept.');
  append(panel,el('h3',lyrics.installed?'Lyrics service installed':'Lyrics service unavailable'),el('p',`Current job: ${lyrics.state || 'Idle'}`,'muted'),el('p','Checks up to 250 songs per run, with artist and duration matching. New lyrics are stored in Jellyfin’s metadata.','muted'),button('Check for lyrics now',async()=>{await api('/api/lyrics','POST',{});notice('Lyrics check started');})); root.append(panel);
}
async function syncAdmin() {
  const [sync,items]=await Promise.all([api('/api/sync'),api('/api/sync/items')]); const byId=new Map(items.map(item=>[item.id,item]));
  const panel=card('Pick up on another device','Finamp syncs your saved Radio stations, preferences, listening history and last queue to this account. Open Server hub in Finamp to resume the queue on that device.');
  append(panel,el('h3',sync.queue?.name||'No queue saved yet'),el('p',sync.queue?`${sync.queue.ids.length} songs · position ${time(sync.queue.positionMs)} · saved ${date(sync.queue.updated)}`:'Play music in Finamp to save a queue.','muted'));
  panel.append(el('h3',`${sync.stations.length} saved stations`));
  const list=el('div',null,'list'); sync.history.slice(0,30).forEach(play=>{const song=byId.get(play.song);if(song)append(list,append(el('div',null,'song'),append(el('div'),el('strong',song.name),el('small',`${song.artist} · ${new Date(play.startedMs).toLocaleString()}`))));});panel.append(list);root.append(panel);
}
function debounce(action) { let timer; return()=>{clearTimeout(timer);timer=setTimeout(()=>act(action),350);}; }
function failed(error) { document.getElementById('connection').textContent='Disconnected'; root.replaceChildren(el('h1','Open your server hub from Finamp'),el('p',error.message||'This link may have expired.','muted'),el('p','Settings → Server hub → Open server controls')); }
// The room was closed (or expired, or its link replaced): there is nothing left to wait for.
function roomGone(error) { return [401, 403, 404].includes(error?.status); }
function leaveRoom(message) {
  clearTimeout(pollTimer); token = ''; roomState = undefined;
  armed = false; mediaKey = ''; appliedRevision = -1; lyrics = []; lyricsKey = ''; lyricsSong = '';
  try { sessionStorage.removeItem(`finamp.hub.${page}`); } catch (_) {}
  if (tvAudio) { tvAudio.onerror = tvAudio.onended = tvAudio.ontimeupdate = null; tvAudio.pause(); tvAudio.removeAttribute('src'); tvAudio.load(); tvAudio = undefined; }
  document.body.classList.remove('tv'); document.getElementById('connection').textContent = 'Room closed';
  if (page === 'tv') showPairing(); else root.replaceChildren(el('h1','This karaoke room was closed'),el('p',message,'muted'));
  notice('This karaoke room was closed');
}
function welcome() { root.replaceChildren(el('h1','Your music server, connected'),el('p','Open Finamp → Settings → Server hub to manage Radio, TV karaoke, overnight jobs, audio health and backups.','muted'),button('Connect a TV screen',()=>location.assign(base+'/tv/'))); }

let tvAudio, tvStart, armed=false, mediaKey='', appliedRevision=-1, lyrics=[], lastLine=-2, tvStatus, tvTitle, tvArtist, lyricBox, progress, qrImage, lastReport=0;
let lyricsKey='', lyricsSong='', lyricsPending=false, lyricsRetry=0;
function startTv() {
  clearTimeout(pollTimer); document.body.classList.add('tv');
  root.replaceChildren(); tvTitle=el('h1','Karaoke party');tvArtist=el('p','','artist');tvStatus=el('p','Choose a song on your phone','muted');
  lyricBox=el('div',null,'lyrics');progress=el('p','0:00','progress');
  tvAudio=el('audio');tvAudio.preload='auto';
  const start=tvStart=button('Start TV audio',async()=>{armed=true;await applyTv();if(!tvAudio.paused)start.classList.add('hidden');if(document.documentElement.requestFullscreen)await document.documentElement.requestFullscreen().catch(()=>{});});
  const footer=el('div',null,'tv-footer'),qrWrap=el('div',null,'row');qrImage=el('img',null,'qr');qrImage.alt='Scan to request a karaoke song';
  append(qrWrap,qrImage,el('p','Scan to request a song.\nThe host controls playback.','muted'));append(footer,progress,qrWrap);
  append(root,tvTitle,tvArtist,tvStatus,start,lyricBox,tvAudio,footer);
  const currentAudio=()=>roomState?.mediaReady&&mediaKey===roomState.mediaKey&&appliedRevision===roomState.commandRev;
  tvAudio.ontimeupdate=()=>{renderLyrics();const now=Date.now();if(now-lastReport>2000&&currentAudio()){lastReport=now;api('/api/room/report','POST',{revision:roomState.commandRev,mediaKey,positionMs:Math.floor(tvAudio.currentTime*1000)}).catch(()=>{});}};
  tvAudio.onended=()=>{if(currentAudio()&&tvAudio.ended)api('/api/room/report','POST',{revision:roomState.commandRev,mediaKey,ended:true}).catch(e=>notice(e.message));};
  tvAudio.onerror=()=>{armed=false;mediaKey='';tvStart.classList.remove('hidden');tvStart.textContent='Retry TV audio';tvStatus.textContent='Audio could not play. Retry or choose another song on the remote.';};
  tvPoll();
}
async function tvPoll() {
  try {
    const state=await api('/api/room/state');roomState=state;tvTitle.textContent=state.song?.name||state.name;tvArtist.textContent=state.song?.artist||'';tvStatus.textContent=state.message;
    if(lyricsSong!==(state.song?.id||'')){lyricsSong=state.song?.id||'';lyrics=[];lyricsKey='';lyricsRetry=0;lastLine=-2;}
    if(state.guestToken&&qrImage.dataset.token!==state.guestToken){qrImage.dataset.token=state.guestToken;const url=link('guest',state.guestToken,state.publicUrl);qrImage.src=base+'/api/room/qr?ticket='+encodeURIComponent(state.guestToken)+'&url='+encodeURIComponent(url);}
    await applyTv();renderLyrics();
    refreshLyrics(state);
  }catch(error){if(roomGone(error))return leaveRoom(error.message);document.getElementById('connection').textContent='Reconnecting';tvStatus.textContent=error.message;}
  pollTimer=setTimeout(tvPoll,1000);
}
async function refreshLyrics(state){
  const key=(state.song?.id||'')+':'+state.lyricsRevision;
  if(!state.song||key===lyricsKey||lyricsPending||Date.now()<lyricsRetry)return;
  lyricsPending=true;
  try{
    const result=await api('/api/room/lyrics');
    if(result.song===roomState?.song?.id){lyrics=result.lyrics;lyricsKey=result.song+':'+result.revision;lastLine=-2;renderLyrics();}
  }catch(error){lyricsRetry=Date.now()+15000;}
  finally{lyricsPending=false;}
}
async function applyTv() {
  if(!roomState||!armed)return;
  const state=roomState,key=state.mediaKey||state.song?.id+':'+state.guide;
  if(!state.mediaReady||!state.media){tvAudio.pause();return;}
  if(key!==mediaKey){mediaKey=key;tvAudio.src=base+state.media;tvAudio.load();appliedRevision=-1;lastLine=-2;}
  if(appliedRevision!==state.commandRev){
    const position=state.positionMs/1000;
    if(tvAudio.readyState>=1){if(Math.abs(tvAudio.currentTime-position)>.3)tvAudio.currentTime=position;}
    else tvAudio.addEventListener('loadedmetadata',()=>{if(mediaKey===key)tvAudio.currentTime=position;},{once:true});
    appliedRevision=state.commandRev;
  }
  if(state.playing&&tvAudio.paused)await tvAudio.play().then(()=>tvStart.classList.add('hidden')).catch(()=>{armed=false;tvStart.classList.remove('hidden');tvStatus.textContent='Press Start TV audio to allow sound in this browser.';});
  if(!state.playing&&!tvAudio.paused)tvAudio.pause();
}
function renderLyrics(){
  if(!tvAudio)return;const ms=tvAudio.currentTime*1000;progress.textContent=time(ms)+' / '+time(roomState?.song?.durationMs);
  let current=-1;for(let i=0;i<lyrics.length;i++){if(lyrics[i].timeMs<=ms)current=i;else break;}
  if(current===lastLine)return;lastLine=current;lyricBox.replaceChildren();
  if(!lyrics.length){lyricBox.append(el('p',roomState?.song?'Timed lyrics are not available for this song yet.':'Your next song will appear here.','lyric current'));return;}
  for(let i=Math.max(0,current-2);i<Math.min(lyrics.length,current+3);i++)lyricBox.append(el('div',lyrics[i].text,'lyric'+(i===current?' current':'')));
}

let remoteTitle,remoteStatus,remoteProgress,remoteQueue;
async function remote(){
  root.replaceChildren(el('h1',page==='guest'?'Choose the next song':'Your karaoke remote'));
  const panel=card('Now on the TV');remoteTitle=el('h3','Connecting…');remoteStatus=el('p','','muted');remoteProgress=el('p','','progress');append(panel,remoteTitle,remoteStatus,remoteProgress);
  if(page!=='guest'){
    const controls=el('div',null,'row');
    append(controls,button('Play',()=>command('play')),button('Pause',()=>command('pause'),true),button('Next song',()=>command('next'),true));panel.append(controls);
    const guide=select(panel,'Guide vocals',0,[0,25,50,75,100].map(v=>[String(v),v+'%']));guide.onchange=()=>act(()=>command('guide',{guide:Number(guide.value)}));
    const seek=input(panel,'Seek to (seconds)',0,'number',0,86400);panel.append(button('Seek',()=>command('seek',{positionMs:Math.floor(Number(seek.value)*1000)}),true));
  }
  root.append(panel);
  const songs=card('Find a song',page==='guest'?'Only songs prepared for karaoke are listed. The host can prepare more in Finamp.':'Choose a song to play now. Karaoke is prepared on the server if needed.');
  const name=page==='guest'?input(songs,'Your name','Guest'):null,search=input(songs,'Song or artist',''),results=el('div',null,'list');songs.append(results);
  const find=async()=>{const items=await api('/api/room/search?q='+encodeURIComponent(search.value));results.replaceChildren();if(!items.length)results.append(el('p',page==='guest'?'No prepared songs match. Ask the host to prepare one.':'No songs match.','muted'));items.forEach(song=>{
    const row=append(el('div',null,'song'),append(el('div'),el('strong',song.name),el('small',song.artist)));
    row.append(button(page==='guest'?'Request':'Play',async()=>{if(page==='guest'){const result=await api('/api/room/request','POST',{song:song.id,guest:name.value});notice(result.started?'Starting your song on the TV':'Song requested');}else await command('select',{song:song.id});},true));results.append(row);
  });};search.oninput=debounce(find);root.append(songs);
  const queue=card('Up next');remoteQueue=el('div',null,'list');queue.append(remoteQueue);root.append(queue);
  await act(find);remotePoll();
}
async function command(action,extra={}){if(!roomState)return;await api('/api/room/command','POST',{action,revision:roomState.commandRev,...extra});await remotePoll(false);}
async function remotePoll(again=true){
  try{roomState=await api('/api/room/state');remoteTitle.textContent=roomState.song?.name||roomState.name;remoteStatus.textContent=roomState.message;remoteProgress.textContent=time(roomState.positionMs)+' / '+time(roomState.song?.durationMs);
    remoteQueue.replaceChildren();roomState.requests.forEach(request=>append(remoteQueue,append(el('div',null,'song'),append(el('div'),el('strong',request.title||'Karaoke request'),el('small','Requested by '+request.guest)),page==='guest'?null:button('Remove',()=>command('remove',{song:request.song}),true))));if(!roomState.requests.length)remoteQueue.append(el('p','No requests yet.','muted'));
  }catch(error){if(roomGone(error))return leaveRoom(error.message);notice(error.message);}if(again)pollTimer=setTimeout(remotePoll,1500);
}
// A party guest: the host's phone runs the party, and the server passes requests to it, so guests needn't share its Wi-Fi.
let partyGuest='';
function partyId(){
  try{partyGuest=localStorage.getItem('finamp.party.guest')||'';}catch(_){}
  if(!/^[A-Za-z0-9_-]{8,64}$/.test(partyGuest)){const bytes=new Uint8Array(12);crypto.getRandomValues(bytes);partyGuest=Array.from(bytes,b=>b.toString(16).padStart(2,'0')).join('');try{localStorage.setItem('finamp.party.guest',partyGuest);}catch(_){}}
  return partyGuest;
}
function partyApi(path,method='GET',data){return api('/api/party/'+path,method,data,token,{'X-Party-Guest':partyId()});}
async function party(){
  root.replaceChildren(el('h1','Add a song'));
  const you=card('You'),name=input(you,'Your name (optional)',''),message=input(you,'Dedication for the DJ to read out (optional)','');
  name.maxLength=24;message.maxLength=80;try{name.value=localStorage.getItem('finamp.party.name')||'';}catch(_){}
  name.onchange=()=>{try{localStorage.setItem('finamp.party.name',name.value);}catch(_){}};
  const songs=card('Find a song'),search=input(songs,'Song title',''),results=el('div',null,'list');songs.append(results);
  const now=card('Now playing'),nowBox=el('div',null,'list');now.append(nowBox);
  const vote=card('Vote for the next song','Guests take turns when possible.'),ballot=el('div',null,'list');vote.append(ballot);
  const next=card('Up next'),upNext=el('div',null,'list');next.append(upNext);
  append(root,you,songs,now,vote,next);
  // Its own searches, not the page's busy flag: the latest query always runs, and older answers arriving late are left.
  let searches=0,searchTimer;
  const find=async()=>{
    const ask=++searches,query=search.value.trim();
    if(query.length<2){results.replaceChildren();return;}
    let items;
    try{items=await partyApi('search?q='+encodeURIComponent(query));}catch(error){if(ask===searches)notice(error.message);return;}
    if(ask!==searches)return;
    results.replaceChildren();
    if(!items.length)results.append(el('p','Nothing found','muted'));
    items.forEach(song=>{const row=append(el('div',null,'song'),append(el('div'),el('strong',song.name),el('small',[song.artist,song.album].filter(Boolean).join(' · '))));
      const add=button('Add',async()=>{const result=await partyApi('add','POST',{id:song.id,guest:name.value,message:message.value});
        if(result.ok){message.value='';add.textContent=result.queued?'Added ✓':'Requested ✓';add.disabled=true;notice(result.queued?'Added to the queue':result.voting?'Added to voting':'Sent to the host for approval');await refresh();}
        else notice(result.tooMany?'Wait for your other requests':'That song is already requested or unavailable');},true);
      row.append(add);results.append(row);});
  };
  search.oninput=()=>{clearTimeout(searchTimer);searchTimer=setTimeout(find,350);};
  const refresh=async()=>{
    const state=await partyApi('state');
    nowBox.replaceChildren(state.nowPlaying?append(el('div',null,'song'),append(el('div'),el('strong',state.nowPlaying.name),el('small',state.nowPlaying.artist))):el('p','Nothing playing','muted'));
    ballot.replaceChildren();vote.classList.toggle('hidden',!state.voting);
    state.ballot.forEach(item=>{const row=append(el('div',null,'song'),append(el('div'),el('strong',item.name),el('small',item.guest+' · '+item.votes+' votes')));
      const choose=button(item.voted?'Voted':'Vote',async()=>{await partyApi('vote','POST',{id:item.requestId});await refresh();},true);choose.disabled=item.voted;row.append(choose);ballot.append(row);});
    if(!state.ballot.length)ballot.append(el('p','Request a song to start voting.','muted'));
    upNext.replaceChildren(...state.upNext.map(item=>append(el('div',null,'song'),append(el('div'),el('strong',item.name),el('small',item.artist)))));
    if(!state.upNext.length)upNext.append(el('p','The queue is empty, add something!','muted'));
  };
  const poll=async()=>{try{await refresh();document.getElementById('connection').textContent='Connected';}catch(error){document.getElementById('connection').textContent='Reconnecting';notice(error.message);}pollTimer=setTimeout(poll,5000);};
  await poll();
}
async function listen(){
  const panel=card('Your server station');panel.classList.add('radio-player');const title=el('h1','Connecting…'),artist=el('p','','artist'),program=el('p','','muted'),audio=el('audio');audio.controls=true;audio.preload='none';
  append(panel,el('div','◉','radio-art'),title,artist,program,audio);root.replaceChildren(panel);
  let state;
  const refresh=async()=>{try{state=await api('/api/radio/state');title.textContent=state.song?.name||state.message;artist.textContent=state.song?.artist||'';program.textContent=state.program?.name||'Station is off';if(!audio.src&&state.enabled)audio.src=base+state.stream;}catch(error){notice(error.message);}pollTimer=setTimeout(refresh,5000);};
  audio.onerror=()=>{notice('The stream disconnected. Press play to reconnect.');audio.removeAttribute('src');audio.load();};await refresh();
}
window.addEventListener('pagehide',()=>clearTimeout(pollTimer));
if(page==='tv'){if(token)startTv();else showPairing();}
else if(page==='remote'||page==='guest'){if(token)remote().catch(failed);else welcome();}
else if(page==='listen'){if(token)listen().catch(failed);else welcome();}
else if(page==='party'){if(token)party().catch(failed);else failed(new Error('Scan the party QR code again.'));}
else if(page==='admin')admin();else welcome();
