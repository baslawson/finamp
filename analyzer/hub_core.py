"""Small, private server hub. No Jellyfin credentials are stored in its database."""
import base64
import copy
import hashlib
import hmac
import json
import os
import re
import secrets
import sqlite3
import threading
import time
from dataclasses import dataclass
from pathlib import Path

import requests
from fastapi import HTTPException
from server_http import HttpPool, ResultCache


def song_id(value):
    value = str(value).replace('-', '').lower()
    if not re.fullmatch('[0-9a-f]{32}', value):
        raise HTTPException(400, 'Invalid song ID')
    return value


def bounded_text(value, limit=100):
    if not isinstance(value, str) or len(value) > limit:
        raise HTTPException(400, 'Text is too long or invalid')
    return value.strip()


def integer(value, low, high):
    if type(value) is not int or not low <= value <= high:
        raise HTTPException(400, 'Number is outside the supported range')
    return value


@dataclass(frozen=True)
class Actor:
    id: str
    name: str
    admin: bool = False


class Jellyfin:
    def __init__(self, url, key, path_map, music_dir):
        self.url, self.key = url.rstrip('/'), key
        self.path_map = path_map or [(music_dir, music_dir)]
        self.http = HttpPool()
        self.metadata = ResultCache()

    def request(self, method, path, *, token=None, timeout=20, **kwargs):
        try:
            response = self.http.request(method, self.url + path,
                headers={'Authorization': f'MediaBrowser Token="{token or self.key}"'}, timeout=timeout, **kwargs)
        except requests.RequestException:
            raise HTTPException(503, 'Jellyfin is unavailable; try again shortly') from None
        if response.status_code in (401, 403):
            response.close()
            raise HTTPException(401, 'Please sign in to Jellyfin again')
        if response.status_code >= 300:
            code = response.status_code
            response.close()
            raise HTTPException(404 if code == 404 else 502, 'Jellyfin could not complete this request')
        return response

    def json(self, method, path, **kwargs):
        with self.request(method, path, **kwargs) as response:
            return response.json() if response.content else None

    def actor(self, token=None, owner=None):
        user = self.json('GET', '/Users/Me' if token else f'/Users/{song_id(owner)}', token=token)
        policy = user.get('Policy') or {}
        if policy.get('IsDisabled'):
            raise HTTPException(403, 'This Jellyfin account is disabled')
        return Actor(song_id(user['Id']), user.get('Name', 'Listener'), bool(policy.get('IsAdministrator')))

    def items(self, owner, *, ids=None, search=None, limit=100, start=0, favorites=False, random=False):
        params = {'IncludeItemTypes': 'Audio', 'Recursive': 'true', 'Limit': min(limit, 1000),
            'StartIndex': start, 'Fields': 'Path,Genres,MediaSources,UserData', 'EnableUserData': 'true'}
        if ids is not None:
            if not ids:
                return []
            params['Ids'] = ','.join(song_id(value) for value in ids)
        if search:
            params['SearchTerm'] = bounded_text(search, 160)
        if favorites:
            params['Filters'] = 'IsFavorite'
        params['SortBy'] = 'Random' if random else 'SortName'
        owner = song_id(owner)
        def load():
            result = self.json('GET', f'/Users/{owner}/Items', params=params)
            return [item for item in result.get('Items', []) if item.get('Type') == 'Audio']
        # Random pools and favourites must reflect live choices. Large library
        # pages are deliberately excluded from the small metadata cache.
        if random or favorites or limit > 200:
            return load()
        return self.metadata.get((owner, tuple(sorted(params.items()))), load)

    def active_players(self):
        sessions = self.json('GET', '/Sessions', timeout=(2, 5))
        return sum(1 for session in sessions if session.get('NowPlayingItem')
            and not (session.get('PlayState') or {}).get('IsPaused', True))

    def item(self, owner, value):
        items = self.items(owner, ids=[value], limit=1)
        if not items:
            raise HTTPException(404, 'This song is not available to your account')
        return items[0]

    def path(self, item):
        original = item.get('Path', '')
        for before, after in sorted(self.path_map, key=lambda pair: -len(pair[0])):
            before = before.rstrip('/')
            if original.startswith(before + '/'):
                root = Path(after).resolve()
                path = (root / original[len(before) + 1:]).resolve()
                if path.is_relative_to(root) and path.is_file():
                    return path
        raise HTTPException(404, 'The server cannot read this music file')

    @staticmethod
    def brief(item):
        return {'id': song_id(item['Id']), 'name': item.get('Name', 'Unknown song'),
            'artist': ', '.join(item.get('Artists') or []) or item.get('AlbumArtist', ''),
            'durationMs': int((item.get('RunTimeTicks') or 0) / 10000)}

    def lyrics(self, value):
        try:
            data = self.json('GET', f'/Audio/{song_id(value)}/Lyrics') or {}
            return [{'timeMs': max(0, int(line['Start'] / 10000)), 'text': str(line.get('Text') or '')[:1000]}
                for line in data.get('Lyrics', [])[:10000] if type(line.get('Start')) in (int, float)]
        except HTTPException:
            return []


DEFAULTS = {
    'timezone': 'Australia/Brisbane', 'owner': None, 'radioEnabled': False,
    'radioProgram': 'scheduled', 'healthEnabled': True, 'healthHour': 1,
    'nightlyEnabled': True, 'nightlyStart': 2, 'nightlyEnd': 6, 'nightlyLimit': 3,
    'nightlyFavorites': True, 'nightlySongs': [], 'cacheGB': 20, 'cacheDays': 30,
    'backupEnabled': True, 'backupHour': 3, 'backupMinute': 15, 'backupKeep': 7,
    'radioPrograms': [
        {'id': 'morning', 'name': 'Morning favourites', 'start': 7, 'mode': 'favourites', 'discovery': 20},
        {'id': 'discovery', 'name': 'Afternoon discovery', 'start': 12, 'mode': 'discovery', 'discovery': 80},
        {'id': 'evening', 'name': 'Evening chill', 'start': 18, 'mode': 'chill', 'discovery': 40},
    ],
}


class Store:
    def __init__(self, root):
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.path = self.root / 'hub.db'
        self.lock = threading.RLock()
        self._settings_lock = threading.RLock()
        self._settings = None
        self._settings_checked = 0
        with self.connect() as db:
            db.executescript('''
                PRAGMA journal_mode=WAL;
                CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS users(id TEXT PRIMARY KEY, preferences TEXT, stations TEXT NOT NULL DEFAULT '{}',
                    revision INTEGER NOT NULL DEFAULT 0, guard INTEGER NOT NULL DEFAULT 0, warnings INTEGER NOT NULL DEFAULT 0);
                CREATE TABLE IF NOT EXISTS history(owner TEXT NOT NULL, id TEXT NOT NULL, started INTEGER NOT NULL,
                    payload TEXT NOT NULL, PRIMARY KEY(owner,id));
                CREATE INDEX IF NOT EXISTS history_owner_time ON history(owner,started);
                CREATE TABLE IF NOT EXISTS snapshots(owner TEXT PRIMARY KEY, device TEXT NOT NULL, payload TEXT NOT NULL,
                    playing INTEGER NOT NULL, updated REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS rooms(id TEXT PRIMARY KEY, owner TEXT NOT NULL, nonce TEXT NOT NULL,
                    state TEXT NOT NULL, expires REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS jobs(id TEXT PRIMARY KEY, kind TEXT NOT NULL, jobkey TEXT NOT NULL,
                    args TEXT NOT NULL, state TEXT NOT NULL, message TEXT NOT NULL, created REAL NOT NULL, updated REAL NOT NULL);
                CREATE INDEX IF NOT EXISTS jobs_state_created ON jobs(state,created);
                CREATE INDEX IF NOT EXISTS jobs_jobkey ON jobs(jobkey);
                CREATE INDEX IF NOT EXISTS jobs_created ON jobs(created);
                CREATE TABLE IF NOT EXISTS health(id TEXT PRIMARY KEY, revision TEXT NOT NULL, state TEXT NOT NULL,
                    warnings INTEGER NOT NULL, checked REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS backups(id TEXT PRIMARY KEY, name TEXT NOT NULL, bytes INTEGER NOT NULL,
                    verified REAL, created REAL NOT NULL, reason TEXT NOT NULL);
            ''')
            db.execute("UPDATE jobs SET state='queued',message='Resuming after server restart' WHERE state='processing'")
        os.chmod(self.path, 0o600)

    def connect(self):
        db = sqlite3.connect(self.path, timeout=20)
        db.row_factory = sqlite3.Row
        return db

    def settings(self, fresh=False):
        with self._settings_lock:
            if fresh or self._settings is None or time.monotonic() - self._settings_checked >= 5:
                with self.connect() as db:
                    row = db.execute("SELECT value FROM settings WHERE key='settings'").fetchone()
                self._settings = {**DEFAULTS, **(json.loads(row[0]) if row else {})}
                self._settings_checked = time.monotonic()
            return copy.deepcopy(self._settings)

    def save_settings(self, values):
        with self.lock, self._settings_lock:
            old = self.settings(fresh=True)
            old.update(values)
            with self.connect() as db:
                db.execute("INSERT OR REPLACE INTO settings VALUES('settings',?)", (json.dumps(old),))
            self._settings = copy.deepcopy(old)
            self._settings_checked = time.monotonic()
        return old

    def user(self, owner):
        with self.lock, self.connect() as db:
            db.execute('INSERT OR IGNORE INTO users(id) VALUES(?)', (owner,))
            row = db.execute('SELECT * FROM users WHERE id=?', (owner,)).fetchone()
        return dict(row)

    def enqueue(self, kind, key, args=None):
        with self.lock, self.connect() as db:
            row = db.execute("SELECT id FROM jobs WHERE kind=? AND jobkey=? AND state IN ('queued','processing')",
                (kind, key)).fetchone()
            if row:
                return row[0]
            if db.execute("SELECT COUNT(*) FROM jobs WHERE state IN ('queued','processing')").fetchone()[0] >= 100:
                raise HTTPException(429, 'The server job queue is full')
            value, now = secrets.token_hex(16), time.time()
            db.execute('INSERT INTO jobs VALUES(?,?,?,?,?,?,?,?)',
                (value, kind, key, json.dumps(args or {}), 'queued', 'Waiting', now, now))
            return value

    def finish(self, job, state, message):
        with self.lock, self.connect() as db:
            db.execute('UPDATE jobs SET state=?,message=?,updated=? WHERE id=?', (state, message[:300], time.time(), job))


class Capabilities:
    def __init__(self, root):
        path = Path(root) / '.capability-secret'
        try:
            descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError:
            pass
        else:
            with os.fdopen(descriptor, 'wb') as output:
                output.write(secrets.token_bytes(32))
        self.secret = path.read_bytes()
        if len(self.secret) != 32:
            raise RuntimeError('Invalid hub capability secret')

    def issue(self, kind, owner, *, seconds=21600, **values):
        payload = json.dumps({'kind': kind, 'owner': owner, 'expires': int(time.time()) + seconds, **values},
            separators=(',', ':'), sort_keys=True).encode()
        data = base64.urlsafe_b64encode(payload).rstrip(b'=')
        signature = hmac.new(self.secret, data, hashlib.sha256).digest()
        return (data + b'.' + base64.urlsafe_b64encode(signature).rstrip(b'=')).decode()

    def read(self, token, kinds):
        try:
            if not isinstance(token, str) or len(token) > 4096:
                raise ValueError()
            data, signature = token.encode().split(b'.')
            expected = hmac.new(self.secret, data, hashlib.sha256).digest()
            signature = base64.urlsafe_b64decode(signature + b'=' * (-len(signature) % 4))
            payload = json.loads(base64.urlsafe_b64decode(data + b'=' * (-len(data) % 4)))
            if not hmac.compare_digest(expected, signature) or payload['expires'] <= time.time() or payload['kind'] not in kinds:
                raise ValueError()
            song_id(payload['owner'])
            return payload
        except (ValueError, KeyError, TypeError, json.JSONDecodeError):
            raise HTTPException(401, 'This link expired; open a new link from Finamp') from None


def revision(path):
    stat = path.stat()
    return hashlib.sha256(f'{path}:{stat.st_size}:{stat.st_mtime_ns}'.encode()).hexdigest()


def validate_preferences(value):
    if not isinstance(value, dict):
        raise HTTPException(400, 'Invalid Radio preferences')
    return {'discovery': integer(value.get('discovery', 50), 0, 100), 'energy': integer(value.get('energy', 0), -1, 1),
        'genres': validate_strings(value.get('genres', []), 100),
        'excludedArtists': validate_strings(value.get('excludedArtists', []), 300)}


def validate_strings(values, limit):
    if not isinstance(values, list) or len(values) > limit:
        raise HTTPException(400, 'Too many choices')
    return list(dict.fromkeys(bounded_text(value, 200) for value in values))


def validate_station(value):
    if not isinstance(value, dict) or not isinstance(value.get('seed'), dict):
        raise HTTPException(400, 'Invalid saved station')
    station_id = bounded_text(value.get('id'), 64)
    if not re.fullmatch('[a-zA-Z0-9-]{1,64}', station_id):
        raise HTTPException(400, 'Invalid station ID')
    seed = value['seed']
    if value.get('mode') not in ('similar', 'continuous', 'albumMix', 'reshuffle', 'random'):
        raise HTTPException(400, 'Invalid saved station mode')
    return {'id': station_id, 'name': bounded_text(value.get('name'), 60),
        'seed': {'id': song_id(seed.get('id')), 'name': bounded_text(seed.get('name') or '', 200),
            'type': bounded_text(seed.get('type') or 'Audio', 40)},
        'mode': bounded_text(value.get('mode'), 40), 'preferences': validate_preferences(value.get('preferences', {}))}
