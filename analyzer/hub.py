"""Finamp server features, mounted at /hub beside the existing analyzer API."""
import hashlib
import hmac
import json
import os
import re
import secrets
import sqlite3
import threading
import time
from contextlib import closing
from pathlib import Path
from urllib.parse import urlsplit
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

import requests
from fastapi import Body, Depends, FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, RedirectResponse, Response, StreamingResponse
from starlette.concurrency import run_in_threadpool

from hub_core import Actor, Capabilities, Jellyfin, Store, bounded_text, integer, revision, song_id
from hub_jobs import Jobs
from hub_party import Parties
from hub_radio import Radio
from hub_reports import LARGEST as LARGEST_REPORT, Reports
from hub_sync import Sync
from server_auth import token_problem
from server_http import HttpPool, ResultCache


class Hub:
    def __init__(self, data, jellyfin, token, karaoke_url, busy=lambda: False, runtime=None):
        self.data, self.jellyfin = Path(data), jellyfin
        self.token, self.karaoke_url = token, karaoke_url.rstrip('/')
        self.analyzer_busy = busy
        self.runtime, self.worker_http, self.priority_cache = runtime, HttpPool(), ResultCache(entries=4, items=200)
        self._store = self._caps = None
        self.stop_event = threading.Event()
        self.lock = threading.RLock()
        self.room_lock = threading.RLock()
        self.room_locks = {}
        self.actor_cache, self.room_checks, self.lyric_cache = {}, {}, {}
        self.pair_attempts = {}
        self.radio, self.jobs = Radio(self), Jobs(self)
        self.parties = Parties()
        self.reports = Reports(self.data / 'hub')

    @property
    def store(self):
        with self.lock:
            if self._store is None:
                self._store = Store(self.data / 'hub')
            return self._store

    @property
    def caps(self):
        with self.lock:
            if self._caps is None:
                self._caps = Capabilities(self.store.root)
            return self._caps

    @property
    def sync(self):
        return Sync(self.store)

    def start(self):
        self.store
        self.caps
        self.stop_event.clear()
        self.jobs.start()
        self.radio.start()

    def stop(self):
        self.stop_event.set()
        self.radio.stop_audio()
        process = self.jobs.process
        if process and process.poll() is None:
            process.terminate()
        self.worker_http.close()
        if isinstance(self.jellyfin, Jellyfin):
            self.jellyfin.http.close()

    def playback_count(self):
        count = self.jellyfin.active_players()
        with self.store.connect() as db:
            rooms = db.execute('SELECT state FROM rooms WHERE expires>?', (time.time(),)).fetchall()
        count += sum(bool(json.loads(row[0]).get('playing')) for row in rooms)
        return count + int(self.radio.state()['listeners'] > 0)

    def analysis_priorities(self):
        values = []
        with self.store.connect() as db:
            for row in db.execute('SELECT payload FROM snapshots WHERE updated>? ORDER BY updated DESC LIMIT 10', (time.time() - 900,)):
                queue = json.loads(row[0])
                values.extend(queue['ids'][queue['index']:queue['index'] + 7])
            recent = [row[0] for row in db.execute('SELECT payload FROM history ORDER BY started DESC LIMIT 100')]
        owner = self.store.settings()['owner']
        if owner:
            try:
                favourites = self.priority_cache.get(owner,
                    lambda: self.jellyfin.items(owner, favorites=True, limit=200), seconds=60)
                values.extend(song_id(item['Id']) for item in favourites)
            except HTTPException:
                pass
        values.extend(json.loads(row)['song'] for row in recent)
        return list(dict.fromkeys(values))[:512]

    def cached_actor(self, *, token=None, owner=None):
        key = ('token:' + hashlib.sha256(token.encode()).hexdigest()) if token else 'owner:' + song_id(owner)
        now = time.monotonic()
        with self.lock:
            cached = self.actor_cache.get(key)
            if cached and cached[0] > now:
                return cached[1]
        actor = self.jellyfin.actor(token=token, owner=owner)
        with self.lock:
            if len(self.actor_cache) > 256:
                self.actor_cache.clear()
            self.actor_cache[key] = (now + 30, actor)
        return actor

    def actor(self, request):
        bearer = request.headers.get('authorization', '')
        if bearer.startswith('Bearer '):
            cap = self.caps.read(bearer[7:], {'session'})
            return self.cached_actor(owner=cap['owner'])
        supplied = request.headers.get('x-api-key', '')
        token = request.headers.get('x-jellyfin-token', '')
        if token_problem(self.token) or not hmac.compare_digest(supplied.encode(), self.token.encode()):
            raise HTTPException(401, 'The server rejected the analyzer token')
        if not token or len(token) > 4096 or '\n' in token or '\r' in token:
            raise HTTPException(401, 'Sign in to Jellyfin to use server features')
        return self.cached_actor(token=token)

    @staticmethod
    def administrator(actor):
        if not actor.admin:
            raise HTTPException(403, 'A Jellyfin administrator manages server-wide features')

    def adopt(self, actor):
        if actor.admin and not self.store.settings()['owner']:
            self.store.save_settings({'owner': actor.id})

    def karaoke(self, method, path, **kwargs):
        if not self.karaoke_url:
            raise HTTPException(503, 'Server karaoke is not configured')
        try:
            response = self.worker_http.request(method, self.karaoke_url + path,
                headers={'X-Api-Key': self.token}, timeout=(5, 30), **kwargs)
        except requests.RequestException:
            raise HTTPException(503, 'The karaoke worker is temporarily unavailable') from None
        with response:
            if response.status_code >= 300:
                raise HTTPException(response.status_code, 'The karaoke worker could not complete this request')
            return response.json() if response.content else {}

    def karaoke_busy(self):
        try:
            return self.karaoke('GET', '/karaoke', params={'state': 'processing', 'limit': 1})['total'] > 0
        except (HTTPException, KeyError):
            return True

    def busy(self):
        return self.analyzer_busy() or self.karaoke_busy()

    def karaoke_file(self, version, guide):
        if not re.fullmatch('[0-9a-f]{64}', version) or guide not in (0, 25, 50, 75, 100):
            raise HTTPException(400, 'Invalid karaoke mix')
        root = (self.data / 'karaoke').resolve()
        directory = (root / version).resolve()
        if directory.parent != root:
            raise HTTPException(400, 'Invalid karaoke cache')
        path = (directory / f'mix-{guide}.flac').resolve()
        if path.parent != directory or not path.is_file():
            raise HTTPException(404, 'Prepare this karaoke mix again')
        return path

    def touch_cache(self, version):
        if re.fullmatch('[0-9a-f]{64}', version):
            root = (self.data / 'karaoke').resolve()
            directory = (root / version).resolve()
            if directory.parent == root and directory.is_dir():
                marker = directory / '.last-used'
                if not marker.exists() or time.time() - marker.stat().st_mtime >= 60:
                    marker.touch()

    def blocked(self, owner):
        user = self.store.user(owner)
        if not user['guard']:
            return set()
        with self.store.connect() as db:
            rows = db.execute("SELECT * FROM health WHERE state='broken' OR (? AND state='warning')", (user['warnings'],)).fetchall()
        by_id = {row['id']: row for row in rows}
        result = set()
        ids = list(by_id)
        for start in range(0, len(ids), 200):
            for item in self.jellyfin.items(owner, ids=ids[start:start + 200], limit=200):
                try:
                    value = song_id(item['Id'])
                    if revision(self.jellyfin.path(item)) == by_id[value]['revision']:
                        result.add(value)
                except (OSError, HTTPException):
                    continue
        return result

    def update_settings(self, actor, body):
        self.administrator(actor)
        allowed = {'radioEnabled', 'radioProgram', 'timezone', 'healthEnabled', 'healthHour', 'nightlyEnabled',
            'nightlyStart', 'nightlyEnd', 'nightlyLimit', 'nightlyFavorites', 'nightlySongs', 'cacheGB', 'cacheDays',
            'backupEnabled', 'backupHour', 'backupMinute', 'backupKeep', 'radioPrograms'}
        if set(body) - allowed:
            raise HTTPException(400, 'Unknown server setting')
        booleans = {'radioEnabled', 'healthEnabled', 'nightlyEnabled', 'nightlyFavorites', 'backupEnabled'}
        ranges = {'healthHour': (0, 23), 'nightlyStart': (0, 23), 'nightlyEnd': (1, 24), 'nightlyLimit': (1, 20),
            'cacheGB': (1, 100), 'cacheDays': (1, 365), 'backupHour': (0, 23), 'backupMinute': (0, 59), 'backupKeep': (2, 30)}
        for name in booleans & body.keys():
            if type(body[name]) is not bool:
                raise HTTPException(400, 'Invalid switch value')
        for name in ranges.keys() & body.keys():
            integer(body[name], *ranges[name])
        if 'timezone' in body:
            try:
                ZoneInfo(bounded_text(body['timezone'], 80))
            except (ZoneInfoNotFoundError, ValueError):
                raise HTTPException(400, 'Choose a valid time zone') from None
        if 'nightlySongs' in body:
            if not isinstance(body['nightlySongs'], list) or len(body['nightlySongs']) > 200:
                raise HTTPException(400, 'Choose at most 200 songs')
            body['nightlySongs'] = list(dict.fromkeys(song_id(value) for value in body['nightlySongs']))
            visible = {song_id(item['Id']) for item in self.jellyfin.items(actor.id, ids=body['nightlySongs'], limit=200)}
            if set(body['nightlySongs']) != visible:
                raise HTTPException(404, 'Some selected songs are unavailable to your account')
        programs = body.get('radioPrograms', self.store.settings()['radioPrograms'])
        if not isinstance(programs, list) or not 1 <= len(programs) <= 8:
            raise HTTPException(400, 'Choose one to eight Radio programs')
        clean = []
        for program in programs:
            value = {'id': bounded_text(program.get('id'), 30), 'name': bounded_text(program.get('name'), 60),
                'start': integer(program.get('start'), 0, 23), 'mode': program.get('mode'),
                'discovery': integer(program.get('discovery', 50), 0, 100)}
            if not re.fullmatch('[a-z0-9-]{1,30}', value['id']) or value['mode'] not in ('favourites', 'discovery', 'chill'):
                raise HTTPException(400, 'Invalid Radio program')
            clean.append(value)
        if len({value['id'] for value in clean}) != len(clean) or len({value['start'] for value in clean}) != len(clean):
            raise HTTPException(400, 'Radio program names and start hours must be unique')
        if body.get('radioProgram', self.store.settings()['radioProgram']) not in {'scheduled', *(value['id'] for value in clean)}:
            raise HTTPException(400, 'Choose a valid Radio program')
        body['radioPrograms'] = clean
        current = self.store.settings()
        if body.get('nightlyStart', current['nightlyStart']) >= body.get('nightlyEnd', current['nightlyEnd']):
            raise HTTPException(400, 'The overnight end hour must be after its start hour')
        self.adopt(actor)
        settings = self.store.save_settings(body)
        if body.get('radioEnabled') is False:
            self.radio.stop_audio()
        return settings

    def create_room(self, actor, body):
        value, nonce, now = secrets.token_hex(16), secrets.token_hex(16), time.time()
        state = {'name': bounded_text(body.get('name', 'Karaoke party'), 60), 'song': None, 'queue': [],
            'requests': [], 'guide': 0, 'playing': False, 'positionMs': 0, 'updated': now,
            'commandRev': 0, 'mediaReady': False, 'message': 'Choose a song on your phone',
            'pairCode': f'{secrets.randbelow(1000000):06}', 'pairUntil': now + 600}
        store = self.store
        with store.lock, store.connect() as db:
            db.execute('DELETE FROM rooms WHERE expires<?', (now,))
            if db.execute('SELECT COUNT(*) FROM rooms WHERE owner=?', (actor.id,)).fetchone()[0] >= 3:
                raise HTTPException(429, 'Close an existing TV room before creating another')
            db.execute('INSERT INTO rooms VALUES(?,?,?,?,?)', (value, actor.id, nonce, json.dumps(state), now + 21600))
        return self.room_links(value, actor)

    def lock_for(self, value):
        """One room's lock: a slow karaoke worker or Jellyfin then holds up only that room, not every TV."""
        with self.lock:
            if len(self.room_locks) > 256:
                # Rooms close and expire; their locks are no longer needed.
                with self.store.connect() as db:
                    live = {row[0] for row in db.execute('SELECT id FROM rooms WHERE expires>?', (time.time(),))}
                self.room_locks = {key: lock for key, lock in self.room_locks.items() if key in live}
            return self.room_locks.setdefault(value, threading.RLock())

    def room_links(self, value, actor):
        with self.lock_for(value):
            return self._room_links(value, actor)

    def _room_links(self, value, actor):
        room = self.room(value)
        if room['owner'] != actor.id and not actor.admin:
            raise HTTPException(403, 'This TV room belongs to another account')
        state = json.loads(room['state'])
        if state.get('pairUntil', 0) < time.time():
            state.update(pairCode=f'{secrets.randbelow(1000000):06}', pairUntil=time.time() + 600)
            store = self.store
            with store.lock, store.connect() as db:
                db.execute('UPDATE rooms SET state=? WHERE id=?', (json.dumps(state), value))
        return {'id': value, 'name': state['name'], 'code': state['pairCode'], **{role: self.caps.issue('room', room['owner'],
            expires=int(room['expires']), room=value, nonce=room['nonce'], role=role)
            for role in ('screen', 'control', 'guest')}}

    def room(self, value):
        with self.store.connect() as db:
            row = db.execute('SELECT * FROM rooms WHERE id=? AND expires>?', (song_id(value), time.time())).fetchone()
        if row is None:
            raise HTTPException(404, 'This TV room closed or expired')
        return dict(row)

    def room_cap(self, request, roles):
        bearer = request.headers.get('authorization', '')
        if not bearer.startswith('Bearer '):
            raise HTTPException(401, 'Open the room link from Finamp')
        cap = self.caps.read(bearer[7:], {'room'})
        room = self.room(cap.get('room'))
        if cap.get('role') not in roles or cap.get('nonce') != room['nonce'] or cap['owner'] != room['owner']:
            raise HTTPException(403, 'This link cannot control that TV room')
        self.cached_actor(owner=room['owner'])
        return room, cap

    @staticmethod
    def position(state):
        value = state.get('positionMs', 0)
        if state.get('playing') and state.get('mediaReady'):
            value += int(max(0, time.time() - state.get('updated', time.time())) * 1000)
        return min(value, (state.get('song') or {}).get('durationMs', value) or value)

    def prepare_room(self, value):
        room = self.room(value)
        state = json.loads(room['state'])
        if not state.get('song') or state.get('mediaReady'):
            return
        song = state['song']['id']
        try:
            result = self.karaoke('GET', f'/karaoke/{song}')
            if result.get('state') == 'ready':
                version = result['revision']
                self.karaoke_file(version, state['guide'])
                path = self.store.root / 'media' / f'{version}-{state["guide"]}.mp3'
                state['revision'] = version
                state['message'] = 'Preparing audio for the TV'
                if path.is_file():
                    state.update(mediaReady=True, message='Ready', updated=time.time())
                else:
                    self.store.enqueue('media', f'{version}-{state["guide"]}',
                        {'song': song, 'guide': state['guide'], 'revision': version})
            elif result.get('state') in ('queued', 'processing'):
                state['message'] = 'Preparing karaoke on the server'
            elif result.get('state') == 'failed':
                state['message'] = 'Preparation failed. Choose the song again to retry.'
            else:
                self.karaoke('POST', f'/karaoke/{song}')
                state['message'] = 'Karaoke preparation is queued'
        except HTTPException as error:
            state['message'] = str(error.detail)
        store = self.store
        with store.lock, store.connect() as db:
            current = db.execute('SELECT state FROM rooms WHERE id=?', (value,)).fetchone()
            latest = json.loads(current[0]) if current else None
            if latest and latest['commandRev'] == state['commandRev']:
                # Preparation may take seconds. Keep reports and guest requests
                # received while the worker was being contacted.
                for key in ('revision', 'message', 'mediaReady'):
                    if key in state:
                        latest[key] = state[key]
                if state.get('mediaReady') and not json.loads(current[0]).get('mediaReady'):
                    latest['updated'] = time.time()
                db.execute('UPDATE rooms SET state=? WHERE id=?', (json.dumps(latest), value))

    def refresh_rooms(self):
        with self.store.connect() as db:
            rooms = db.execute('SELECT id,state FROM rooms WHERE expires>?', (time.time(),)).fetchall()
        for room in rooms:
            state = json.loads(room['state'])
            if state['queue'] and self.idle(state):
                # A request whose start failed, as Jellyfin or the worker was away: try again.
                try:
                    self.room_command(self.room(room['id']), {'action': 'next', 'revision': state['commandRev']})
                except HTTPException:
                    pass
            elif state.get('song') and not state.get('mediaReady'):
                self.prepare_room(room['id'])

    @staticmethod
    def idle(state):
        """Nothing on the TV: no song yet, or the last one ran out with nothing after it."""
        return not state.get('song') or (state.get('finished') and not state.get('playing'))

    def room_state(self, room, cap):
        state = json.loads(room['state'])
        result = {**state, 'positionMs': self.position(state), 'room': room['id']}
        result.pop('revision', None)
        result.pop('pairCode', None)
        result.pop('pairUntil', None)
        result['requests'] = [{key: value for key, value in entry.items() if key != 'requester'} for entry in state.get('requests', [])]
        if state.get('queue'):
            songs = {song_id(item['Id']): self.jellyfin.brief(item) for item in
                self.jellyfin.items(room['owner'], ids=state['queue'], limit=40)}
            for entry in result['requests']:
                entry['title'] = songs.get(entry['song'], {}).get('name', 'Unavailable song')
        if state.get('song'):
            if cap['role'] == 'screen':
                cached = self.lyric_cache.get(state['song']['id'])
                result['lyricsRevision'] = cached[2] if self.lyrics_current(cached) else 'refresh'
            if state.get('mediaReady'):
                ticket = self.caps.issue('media', room['owner'], expires=int(room['expires']), room=room['id'], nonce=room['nonce'],
                    revision=state['revision'], guide=state['guide'])
                result['media'] = '/api/media/' + ticket
                result['mediaKey'] = f'{state["revision"]}:{state["guide"]}'
                self.touch_cache(state['revision'])
        if cap['role'] in ('screen', 'control'):
            result['guestToken'] = self.caps.issue('room', room['owner'], expires=int(room['expires']),
                room=room['id'], nonce=room['nonce'], role='guest')
            # Guests scan the TV's code on their own phones, often away from the home network.
            result['publicUrl'] = public_url()
        return result

    @staticmethod
    def lyrics_current(cached):
        return cached and time.monotonic() - cached[0] < (300 if cached[1] else 15)

    def room_lyrics(self, room):
        song = (json.loads(room['state']).get('song') or {}).get('id')
        if not song:
            return {'song': None, 'revision': None, 'lyrics': []}
        cached = self.lyric_cache.get(song)
        if not self.lyrics_current(cached):
            lines = self.jellyfin.lyrics(song)
            cached = (time.monotonic(), lines, hashlib.sha256(json.dumps(lines).encode()).hexdigest())
            if len(self.lyric_cache) > 100:
                self.lyric_cache.clear()
            self.lyric_cache[song] = cached
        return {'song': song, 'revision': cached[2], 'lyrics': cached[1]}

    def room_command(self, room, body):
        with self.lock_for(room['id']):
            selected = self._room_command(self.room(room['id']), body)
        self.after_command(room, selected)
        return {'ok': True}

    def after_command(self, room, selected):
        # The worker and Jellyfin are contacted after the command is saved, without holding up the room.
        if selected:
            try:
                self.store.enqueue('lyrics', f'lyrics:{song_id(selected)}', {'song': song_id(selected), 'owner': room['owner']})
            except HTTPException as error:
                if error.status_code != 429:
                    raise
            current = self.karaoke('GET', f'/karaoke/{song_id(selected)}')
            if current.get('state') in ('missing', 'failed'):
                self.karaoke('POST', f'/karaoke/{song_id(selected)}')
        self.prepare_room(room['id'])

    def prepared_songs(self, owner, search, limit=25):
        """Songs a guest can request: those with a karaoke mix ready, among the closest matches to [search], or the
        most recently prepared when nothing is typed."""
        if search.strip():
            items = self.jellyfin.items(owner, search=search, limit=200)
        else:
            ready = self.karaoke('GET', '/karaoke', params={'state': 'ready', 'limit': 100}).get('items', [])
            items = self.jellyfin.items(owner, ids=[entry['id'] for entry in ready], limit=100)
        if not items:
            return []
        states = self.karaoke('POST', '/karaoke/status', json={'ids': [item['Id'] for item in items]})
        return [self.jellyfin.brief(item) for item in items
            if (states.get(song_id(item['Id'])) or {}).get('state') == 'ready'][:limit]

    def _room_command(self, room, body):
        action = body.get('action')
        if action not in ('select', 'guide', 'play', 'pause', 'seek', 'next', 'remove'):
            raise HTTPException(400, 'Unknown playback command')
        state = json.loads(room['state'])
        if body.get('revision') != state['commandRev']:
            raise HTTPException(409, 'The TV changed; refresh and try again')
        if action in ('guide', 'seek', 'play') and not state.get('song'):
            raise HTTPException(409, 'Choose a song first')
        selected = body.get('song') if action == 'select' else None
        item = None
        if action == 'next':
            # A song gone from the library since it was requested is passed over, so it can't hold up the rest.
            while state['queue'] and not selected:
                candidate = state['queue'][0]
                state['queue'] = state['queue'][1:]
                state['requests'] = [entry for entry in state.get('requests', []) if entry['song'] != candidate]
                try:
                    item = self.jellyfin.item(room['owner'], candidate)
                    selected = candidate
                except HTTPException as error:
                    if error.status_code != 404:
                        raise
            # Nothing left to sing: a guest's next request can then start at once.
            state['finished'] = not selected
            if not selected:
                action = 'pause'
        elif action in ('select', 'play', 'pause', 'seek'):
            state['finished'] = False
        if selected:
            item = item or self.jellyfin.item(room['owner'], selected)
            state.update(song=self.jellyfin.brief(item), positionMs=0, playing=True, mediaReady=False,
                message='Preparing karaoke', updated=time.time())
            state.pop('revision', None)
        elif action == 'select':
            raise HTTPException(400, 'Choose a song')
        elif action == 'guide':
            guide = integer(body.get('guide'), 0, 100)
            if guide not in (0, 25, 50, 75, 100):
                raise HTTPException(400, 'Choose an available vocal level')
            state.update(positionMs=self.position(state), guide=guide, mediaReady=False, updated=time.time())
        elif action in ('play', 'pause'):
            state.update(positionMs=self.position(state), playing=action == 'play', updated=time.time())
        elif action == 'seek':
            position = integer(body.get('positionMs'), 0, (state.get('song') or {}).get('durationMs') or 86400000)
            state.update(positionMs=position, updated=time.time())
        elif action == 'remove':
            value = song_id(body.get('song'))
            state['queue'] = [item for item in state['queue'] if item != value]
            state['requests'] = [entry for entry in state.get('requests', []) if entry['song'] != value]
        state['commandRev'] += 1
        store = self.store
        with store.lock, store.connect() as db:
            current = db.execute('SELECT state FROM rooms WHERE id=?', (room['id'],)).fetchone()
            if not current or json.loads(current[0])['commandRev'] != body['revision']:
                raise HTTPException(409, 'A newer playback command was received')
            # Pairing a TV can happen alongside a command; keep its single-use code as it is now.
            latest = json.loads(current[0])
            for key in ('pairCode', 'pairUntil'):
                if key in latest:
                    state[key] = latest[key]
            db.execute('UPDATE rooms SET state=? WHERE id=?', (json.dumps(state), room['id']))
        return selected


def public_url():
    """The server's address for people away from home (PUBLIC_URL, without a trailing slash), or None when it isn't set."""
    return os.environ.get('PUBLIC_URL', '').strip().rstrip('/') or None


def public_hosts(request):
    """The names this server is reached by: its Host header, and behind a reverse proxy the host the browser used
    (X-Forwarded-Host, or PUBLIC_URL when the proxy sends neither). A cross-site page can't set these headers."""
    hosts = {request.headers.get('host')}
    forwarded = request.headers.get('x-forwarded-host')
    if forwarded:
        hosts.add(forwarded.split(',')[0].strip())
    public = os.environ.get('PUBLIC_URL', '')
    if public:
        hosts.add(urlsplit(public).netloc)
    hosts.discard(None)
    hosts.discard('')
    return hosts


def create_app(hub):
    app = FastAPI(title='Finamp server hub', docs_url=None, redoc_url=None)

    @app.middleware('http')
    async def limits(request, call_next):
        if request.method in ('POST', 'PUT', 'PATCH', 'DELETE'):
            origin = request.headers.get('origin')
            if origin and urlsplit(origin).netloc not in public_hosts(request):
                return Response('Use the original server page', status_code=403)
            if request.url.path.endswith('/announcement'):
                limit = 8 * 1024 * 1024
            elif '/api/reports/' in request.url.path:
                limit = LARGEST_REPORT
            else:
                limit = 256 * 1024
            length = request.headers.get('content-length')
            if length and (not length.isdigit() or int(length) > limit):
                return Response('Request is too large', status_code=413)
            parts, count = [], 0
            async for part in request.stream():
                count += len(part)
                if count > limit:
                    return Response('Request is too large', status_code=413)
                parts.append(part)
            request._body = b''.join(parts)
        response = await call_next(request)
        response.headers.update({'Referrer-Policy': 'no-referrer', 'X-Content-Type-Options': 'nosniff',
            'Cache-Control': 'no-store', 'Content-Security-Policy': "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; media-src 'self' blob:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'"})
        return response

    def actor(request: Request):
        return hub.actor(request)

    def admin(user=Depends(actor)):
        hub.administrator(user)
        return user

    @app.get('/api/status')
    def status(user=Depends(actor)):
        hub.adopt(user)
        settings = hub.store.settings()
        radio = hub.radio.state() if user.admin or settings['owner'] == user.id else {'enabled': settings['radioEnabled']}
        return {'version': 1, 'administrator': user.admin, 'user': user.name, 'radio': radio,
            'sync': True, 'timezone': settings['timezone'], 'time': time.time()}

    @app.post('/api/session')
    def session(request: Request, user=Depends(actor)):
        # Only Finamp's own sign-in makes a session, so a copied link can't renew itself past its hour.
        if request.headers.get('authorization', '').startswith('Bearer '):
            raise HTTPException(403, 'Open a new link from Finamp')
        return {'token': hub.caps.issue('session', user.id, seconds=3600), 'administrator': user.admin}

    @app.get('/api/settings')
    def settings(user=Depends(admin)):
        hub.adopt(user)
        return hub.store.settings()

    @app.get('/api/runtime')
    def runtime(user=Depends(admin)):
        report = hub.runtime.status() if hub.runtime else {'workers': [], 'warnings': ['Runtime monitor is not enabled']}
        with hub.store.connect() as db:
            rows = db.execute("SELECT kind,state,message,created,updated FROM jobs WHERE state IN ('queued','processing') ORDER BY created LIMIT 100").fetchall()
        report['jobs'] = [{'kind': row['kind'], 'state': row['state'], 'message': row['message'],
            'ageSeconds': max(0, round(time.time() - row['created'])),
            'attention': row['state'] == 'processing' and time.time() - row['updated'] > 1800} for row in rows]
        karaoke_db = hub.data / 'karaoke' / 'jobs.db'
        if karaoke_db.is_file():
            try:
                with closing(sqlite3.connect(karaoke_db.resolve().as_uri() + '?mode=ro', uri=True, timeout=1)) as db:
                    queued = db.execute("SELECT state,message,queued FROM jobs WHERE state IN ('queued','processing') ORDER BY queued LIMIT 20").fetchall()
                report['jobs'].extend({'kind': 'karaoke', 'state': state, 'message': message,
                    'ageSeconds': max(0, round(time.time() - created)),
                    'attention': state == 'processing' and time.time() - created > 1800}
                    for state, message, created in queued)
            except sqlite3.Error:
                report['warnings'].append('Karaoke queue status is temporarily unavailable')
        if isinstance(hub.jellyfin, Jellyfin):
            report['requests'] = hub.jellyfin.http.status()
            report['metadataCache'] = hub.jellyfin.metadata.status()
        return report

    @app.put('/api/settings')
    def save_settings(body: dict = Body(...), user=Depends(admin)):
        return hub.update_settings(user, body)

    @app.get('/api/search')
    def search(q: str = '', favorites: bool = False, user=Depends(actor)):
        return [hub.jellyfin.brief(item) for item in hub.jellyfin.items(user.id, search=q, favorites=favorites, limit=30)]

    @app.get('/api/nightly/songs')
    def nightly_songs(user=Depends(admin)):
        return [hub.jellyfin.brief(item) for item in hub.jellyfin.items(user.id,
            ids=hub.store.settings()['nightlySongs'], limit=200)]

    @app.get('/api/sync')
    def read_sync(unless: str = '', user=Depends(actor)):
        return hub.sync.read(user.id, unless)

    @app.patch('/api/sync')
    def configure_sync(body: dict = Body(...), user=Depends(actor)):
        return hub.sync.configuration(user.id, body)

    @app.post('/api/sync/history')
    def history(body: dict = Body(...), user=Depends(actor)):
        return hub.sync.history(user.id, body)

    @app.put('/api/sync/queue')
    def queue_snapshot(body: dict = Body(...), user=Depends(actor)):
        return hub.sync.queue(user.id, body)

    @app.get('/api/sync/items')
    def sync_items(user=Depends(actor)):
        sync = hub.sync.read(user.id)
        ids = list(dict.fromkeys([entry['song'] for entry in sync['history']]))
        return [hub.jellyfin.brief(item) for item in hub.jellyfin.items(user.id, ids=ids, limit=100)]

    @app.get('/api/blocked')
    def blocked(user=Depends(actor)):
        return {'ids': sorted(hub.blocked(user.id))}

    @app.get('/api/health')
    def health(user=Depends(admin)):
        with hub.store.connect() as db:
            rows = db.execute("SELECT * FROM health ORDER BY CASE state WHEN 'healthy' THEN 1 ELSE 0 END,checked DESC LIMIT 500").fetchall()
            counts = dict(db.execute('SELECT state,COUNT(*) FROM health GROUP BY state'))
        details = {song_id(item['Id']): hub.jellyfin.brief(item) for item in
            hub.jellyfin.items(user.id, ids=[row['id'] for row in rows], limit=500)}
        return {'counts': counts, 'items': [{**dict(row), 'song': details[row['id']]} for row in rows if row['id'] in details]}

    @app.get('/api/jobs')
    def jobs(user=Depends(admin)):
        with hub.store.connect() as db:
            return [dict(row) for row in db.execute('SELECT id,kind,state,message,created,updated FROM jobs ORDER BY created DESC LIMIT 100')]

    @app.post('/api/jobs')
    def add_job(body: dict = Body(...), user=Depends(admin)):
        kind = body.get('kind')
        if kind not in ('health', 'nightly', 'cleanup', 'backup', 'verify'):
            raise HTTPException(400, 'Unknown job')
        hub.adopt(user)
        args = {'limit': integer(body.get('limit', 100), 1, 500)} if kind == 'health' else {}
        if kind == 'backup':
            args['reason'] = 'manual'
        if kind == 'verify':
            args['id'] = song_id(body.get('id'))
        return {'id': hub.store.enqueue(kind, f'manual:{kind}:{body.get("id", "default")}', args)}

    @app.get('/api/backups')
    def backups(user=Depends(admin)):
        with hub.store.connect() as db:
            return [dict(row) for row in db.execute('SELECT * FROM backups ORDER BY created DESC')]

    @app.post('/api/backups/{value}/download')
    def backup_download(value: str, user=Depends(admin)):
        with hub.store.connect() as db:
            row = db.execute('SELECT id FROM backups WHERE id=?', (song_id(value),)).fetchone()
        if row is None:
            raise HTTPException(404, 'Backup no longer exists')
        return {'ticket': hub.caps.issue('backup', user.id, seconds=120, backup=value)}

    @app.get('/api/download/{ticket}')
    def download(ticket: str):
        cap = hub.caps.read(ticket, {'backup'})
        hub.administrator(hub.cached_actor(owner=cap['owner']))
        with hub.store.connect() as db:
            row = db.execute('SELECT * FROM backups WHERE id=?', (song_id(cap.get('backup')),)).fetchone()
        if row is None:
            raise HTTPException(404, 'Backup no longer exists')
        root = (hub.store.root / 'backups').resolve()
        path = (root / row['name']).resolve()
        if path.parent != root or not path.is_file():
            raise HTTPException(404, 'Backup no longer exists')
        return FileResponse(path, filename=row['name'], media_type='application/gzip')

    @app.get('/api/radio')
    def radio(user=Depends(admin)):
        intros = [program['id'] for program in hub.store.settings()['radioPrograms']
            if (hub.store.root / 'announcements' / f'{program["id"]}.mp3').is_file()]
        return {**hub.radio.state(), 'token': hub.caps.issue('radio', user.id), 'introductions': intros}

    @app.post('/api/radio/announcement')
    def announcement(request: Request, body: bytes = Body(..., media_type='audio/wav'), user=Depends(admin)):
        store = hub.store
        program = bounded_text(request.headers.get('x-program', ''), 30)
        if program not in {value['id'] for value in store.settings()['radioPrograms']}:
            raise HTTPException(400, 'Choose a Radio program')
        if not 44 <= len(body) <= 8 * 1024 * 1024 or body[:4] != b'RIFF' or body[8:12] != b'WAVE':
            raise HTTPException(400, 'Upload a short WAV introduction')
        directory = store.root / 'announcements'
        directory.mkdir(exist_ok=True, mode=0o700)
        source = directory / f'{program}.wav'
        temporary = directory / f'.{program}.{secrets.token_hex(8)}.upload'
        with open(temporary, 'wb') as output:
            os.chmod(temporary, 0o600)
            output.write(body)
        version = hashlib.sha256(body).hexdigest()
        with hub.lock:
            temporary.replace(source)
        return {'id': store.enqueue('announcement', f'{program}:{version}', {'program': program, 'version': version})}

    @app.delete('/api/radio/announcement/{program}')
    def remove_announcement(program: str, user=Depends(admin)):
        store = hub.store
        if program not in {value['id'] for value in store.settings()['radioPrograms']}:
            raise HTTPException(400, 'Choose a Radio program')
        with hub.lock:
            for suffix in ('wav', 'mp3'):
                (store.root / 'announcements' / f'{program}.{suffix}').unlink(missing_ok=True)
        return {'removed': True}

    @app.get('/api/lyrics')
    def lyrics(user=Depends(admin)):
        plugins = hub.jellyfin.json('GET', '/Plugins')
        tasks = hub.jellyfin.json('GET', '/ScheduledTasks')
        task = next((value for value in tasks if value.get('Key') == 'DLLyrics'), {})
        return {'installed': any(value.get('Name') == 'Lyrics' and value.get('Status') in ('Active', 'Superseded', 'Restart') for value in plugins),
            'restartPending': any(value.get('Name') == 'Lyrics' and value.get('Status') == 'Restart' for value in plugins),
            'state': task.get('State', 'Unavailable'), 'lastRun': (task.get('LastExecutionResult') or {}).get('EndTimeUtc')}

    @app.post('/api/lyrics')
    def start_lyrics(user=Depends(admin)):
        tasks = hub.jellyfin.json('GET', '/ScheduledTasks')
        task = next((value for value in tasks if value.get('Key') == 'DLLyrics'), None)
        if not task:
            raise HTTPException(503, 'Install the Jellyfin lyrics service first')
        if task.get('State') != 'Running':
            hub.jellyfin.request('POST', f'/ScheduledTasks/Running/{song_id(task["Id"])}').close()
        return {'started': True}

    @app.get('/api/radio/state')
    def radio_state(request: Request):
        token = request.headers.get('authorization', '').removeprefix('Bearer ')
        cap = hub.caps.read(token, {'radio'})
        return {**hub.radio.state(), 'stream': '/api/radio/stream/' + hub.caps.issue('stream', cap['owner'], seconds=3600)}

    @app.get('/api/radio/stream/{ticket}')
    def radio_stream(ticket: str):
        hub.caps.read(ticket, {'stream'})
        if not hub.store.settings()['radioEnabled']:
            raise HTTPException(409, 'The station is off')
        return StreamingResponse(hub.radio.listen(), media_type='audio/mpeg', headers={'X-Accel-Buffering': 'no'})

    @app.get('/api/rooms')
    def rooms(user=Depends(actor)):
        with hub.store.connect() as db:
            rows = db.execute('SELECT id,state FROM rooms WHERE owner=? AND expires>?', (user.id, time.time())).fetchall()
        return [{'id': row['id'], 'name': json.loads(row['state'])['name']} for row in rows]

    @app.post('/api/rooms')
    def create_room(body: dict = Body(default={}), user=Depends(actor)):
        return hub.create_room(user, body)

    @app.post('/api/pair')
    def pair(request: Request, body: dict = Body(...)):
        address = request.client.host if request.client else 'local'
        now = time.time()
        with hub.lock:
            hub.pair_attempts = {key: value for key, value in hub.pair_attempts.items() if value[0] > now - 60}
            attempts = hub.pair_attempts.get(address, (now, 0))
            # Six-digit codes: at most 30 guesses a minute across every address, so a code can't be found by trying
            # from many addresses during its ten minutes.
            total = sum(value[1] for value in hub.pair_attempts.values())
            if attempts[1] >= 6 or total >= 30 or len(hub.pair_attempts) >= 1000:
                raise HTTPException(429, 'Wait a minute before trying another TV code')
            hub.pair_attempts[address] = (attempts[0], attempts[1] + 1)
        code = str(body.get('code', ''))
        if not re.fullmatch('[0-9]{6}', code):
            raise HTTPException(400, 'Enter the six-digit code from Finamp')
        store = hub.store
        with hub.room_lock, store.lock, store.connect() as db:
            rows = db.execute('SELECT * FROM rooms WHERE expires>?', (now,)).fetchall()
            matching = [row for row in rows if json.loads(row['state']).get('pairCode') == code
                and json.loads(row['state']).get('pairUntil', 0) > now]
            if len(matching) != 1:
                raise HTTPException(404, 'This code expired or was already used; open a new code in Finamp')
            room = matching[0]
            state = json.loads(room['state'])
            state['pairUntil'] = 0
            db.execute('UPDATE rooms SET state=? WHERE id=?', (json.dumps(state), room['id']))
        return {'token': hub.caps.issue('room', room['owner'], seconds=max(1, int(room['expires'] - now)),
            room=room['id'], nonce=room['nonce'], role='screen')}

    @app.post('/api/rooms/{value}/links')
    def room_links(value: str, user=Depends(actor)):
        return hub.room_links(song_id(value), user)

    @app.delete('/api/rooms/{value}')
    def close_room(value: str, user=Depends(actor)):
        room = hub.room(value)
        if room['owner'] != user.id and not user.admin:
            raise HTTPException(403, 'This room belongs to another account')
        store = hub.store
        with store.lock, store.connect() as db:
            db.execute('DELETE FROM rooms WHERE id=?', (value,))
        return {'closed': True}

    @app.get('/api/room/state')
    def room_state(request: Request):
        room, cap = hub.room_cap(request, {'screen', 'control', 'guest'})
        return hub.room_state(room, cap)

    @app.get('/api/room/lyrics')
    def room_lyrics(request: Request):
        room, _ = hub.room_cap(request, {'screen'})
        return hub.room_lyrics(room)

    @app.get('/api/room/search')
    def room_search(request: Request, q: str = ''):
        room, cap = hub.room_cap(request, {'control', 'guest'})
        if cap['role'] == 'guest':
            # Guests can only request what's prepared, so they're only shown that.
            return hub.prepared_songs(room['owner'], q)
        return [hub.jellyfin.brief(item) for item in hub.jellyfin.items(room['owner'], search=q, limit=25)]

    @app.post('/api/room/command')
    def command(request: Request, body: dict = Body(...)):
        room, _ = hub.room_cap(request, {'control'})
        return hub.room_command(room, body)

    @app.post('/api/room/report')
    def report(request: Request, body: dict = Body(...)):
        room, _ = hub.room_cap(request, {'screen'})
        state = json.loads(room['state'])
        if body.get('revision') != state['commandRev']:
            return {'accepted': False}
        expected_media = f'{state.get("revision")}:{state["guide"]}'
        if not state.get('mediaReady') or body.get('mediaKey') != expected_media:
            return {'accepted': False}
        if body.get('ended'):
            # With nothing queued, "next" pauses and marks the room as finished.
            return hub.room_command(room, {'action': 'next', 'revision': state['commandRev']})
        position = integer(body.get('positionMs', 0), 0, (state.get('song') or {}).get('durationMs') or 86400000)
        store = hub.store
        with store.lock, store.connect() as db:
            current = db.execute('SELECT state FROM rooms WHERE id=?', (room['id'],)).fetchone()
            if not current or json.loads(current[0])['commandRev'] != state['commandRev']:
                return {'accepted': False}
            latest = json.loads(current[0])
            latest.update(positionMs=position, updated=time.time())
            db.execute('UPDATE rooms SET state=? WHERE id=?', (json.dumps(latest), room['id']))
        return {'accepted': True}

    @app.post('/api/room/request')
    def guest_request(request: Request, body: dict = Body(...)):
        room, _ = hub.room_cap(request, {'guest', 'control'})
        value = song_id(body.get('song'))
        hub.jellyfin.item(room['owner'], value)
        ready = hub.karaoke('GET', f'/karaoke/{value}')
        if ready.get('state') != 'ready':
            raise HTTPException(409, 'Ask the host to prepare this song first')
        address = request.client.host if request.client else 'local'
        requester = hashlib.sha256(address.encode()).hexdigest()
        store = hub.store
        selected = None
        with hub.lock_for(room['id']):
            with store.lock, store.connect() as db:
                state = json.loads(db.execute('SELECT state FROM rooms WHERE id=?', (room['id'],)).fetchone()[0])
                if len(state['queue']) >= 40 or sum(entry['requester'] == requester for entry in state['requests']) >= 3:
                    raise HTTPException(429, 'Please wait for some of your requests to play')
                # A song that has run out can be asked for again.
                if value in state['queue'] or (value == (state.get('song') or {}).get('id') and not hub.idle(state)):
                    raise HTTPException(409, 'This song is already in the room queue')
                state['queue'].append(value)
                state['requests'].append({'song': value, 'guest': bounded_text(body.get('guest', 'Guest'), 30), 'requester': requester})
                db.execute('UPDATE rooms SET state=? WHERE id=?', (json.dumps(state), room['id']))
            # A TV with nothing on starts the queue, so a request isn't left waiting for the host to press "Next
            # song". Still under the room's lock, so no other command can come between.
            if hub.idle(state):
                try:
                    selected = hub._room_command(hub.room(room['id']), {'action': 'next', 'revision': state['commandRev']})
                except HTTPException:
                    # The request is in; the room tries starting it again shortly.
                    pass
        try:
            hub.after_command(room, selected)
        except HTTPException:
            # The request is in and the song chosen; the room retries preparing it if the worker is busy.
            pass
        return {'accepted': True, 'started': selected == value}

    @app.get('/api/media/{ticket}')
    def media(ticket: str):
        cap = hub.caps.read(ticket, {'media'})
        room = hub.room(cap.get('room'))
        state = json.loads(room['state'])
        if cap['owner'] != room['owner'] or cap.get('nonce') != room['nonce'] or cap.get('revision') != state.get('revision') or cap.get('guide') != state['guide']:
            raise HTTPException(409, 'The TV selected another karaoke mix')
        hub.karaoke_file(cap['revision'], cap['guide'])
        path = hub.store.root / 'media' / f'{cap["revision"]}-{cap["guide"]}.mp3'
        if not path.is_file():
            raise HTTPException(404, 'Browser audio is not ready')
        hub.touch_cache(cap['revision'])
        return FileResponse(path, media_type='audio/mpeg')

    @app.post('/api/reports/{kind}')
    def upload_report(kind: str, body: bytes = Body(..., media_type='application/zip'), user=Depends(actor)):
        return {'name': hub.reports.save(user.id, kind, body)}

    @app.get('/api/reports')
    def reports(user=Depends(actor)):
        return hub.reports.listing(user.id)

    @app.post('/api/parties')
    def open_party(data: dict = Body(default={}), user=Depends(actor)):
        value = hub.parties.open(user.id, data.get('id'))
        return {'id': value, 'token': hub.caps.issue('party', user.id, seconds=86400, party=value), 'publicUrl': public_url()}

    @app.delete('/api/parties/{value}')
    def close_party(value: str, user=Depends(actor)):
        hub.parties.close(user.id, value)
        return {'closed': True}

    @app.get('/api/parties/{value}/inbox')
    def party_inbox(value: str, wait: float = 25, user=Depends(actor)):
        return hub.parties.take(user.id, value, wait)

    @app.post('/api/parties/{value}/answers')
    def party_answers(value: str, data: dict = Body(...), user=Depends(actor)):
        answers = data.get('answers')
        hub.parties.answer(user.id, value, answers if isinstance(answers, list) else [])
        return {'ok': True}

    @app.api_route('/api/party/{name}', methods=['GET', 'POST'])
    async def party_guest(name: str, request: Request):
        bearer = request.headers.get('authorization', '')
        cap = hub.caps.read(bearer[7:] if bearer.startswith('Bearer ') else '', {'party'})
        guest = request.headers.get('x-party-guest', '')
        if not re.fullmatch('[A-Za-z0-9_-]{8,64}', guest):
            raise HTTPException(400, 'Reload the party page')
        body = (await request.body()) if request.method == 'POST' else b''
        if len(body) > 4096:
            raise HTTPException(413, 'Request is too large')
        query = {key: value[:200] for key, value in request.query_params.items() if key == 'q'}
        status, text = await run_in_threadpool(hub.parties.ask, cap, guest, request.method, '/api/' + name, query,
            body.decode('utf-8', 'replace'))
        return Response(text, status_code=status, media_type='application/json')

    @app.get('/api/room/qr')
    def qr(request: Request, ticket: str, url: str):
        import qrcode
        import qrcode.image.svg
        cap = hub.caps.read(ticket, {'room'})
        room = hub.room(cap.get('room'))
        if cap.get('nonce') != room['nonce'] or cap.get('role') != 'guest':
            raise HTTPException(403, 'Invalid room link')
        parsed = urlsplit(url)
        if parsed.scheme not in ('http', 'https') or parsed.netloc not in public_hosts(request) or parsed.fragment != ticket:
            raise HTTPException(400, 'Use the original room URL')
        svg = qrcode.make(url, image_factory=qrcode.image.svg.SvgPathImage)
        return Response(svg.to_string(), media_type='image/svg+xml')

    static = Path(__file__).with_name('hub_web')

    @app.get('/assets/{name}')
    def asset(name: str):
        if name not in ('hub.js', 'hub.css'):
            raise HTTPException(404)
        return FileResponse(static / name, media_type='text/javascript' if name.endswith('.js') else 'text/css')

    @app.get('/')
    def home():
        return RedirectResponse('home/')

    @app.get('/{page}/')
    def page(page: str = 'home'):
        if page not in ('home', 'admin', 'tv', 'remote', 'guest', 'listen', 'party'):
            raise HTTPException(404)
        return FileResponse(static / 'index.html', media_type='text/html')

    return app
