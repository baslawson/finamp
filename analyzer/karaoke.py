"""Authenticated, persistent, single-song karaoke queue. Originals are mounted read-only."""
import hashlib
import hmac
import json
import logging
import math
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import threading
import time
from contextlib import asynccontextmanager
from contextlib import ExitStack
from pathlib import Path

import requests
from fastapi import Depends, FastAPI, Header, HTTPException, Query
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field
from server_auth import token_problem
from server_http import HttpPool
from server_runtime import RuntimeGovernor

TOKEN = os.environ.get("ANALYZER_TOKEN", "")
ROOT = Path(os.environ.get("DATA_DIR", "/data")) / "karaoke"
MODEL = os.environ.get("KARAOKE_MODEL", "UVR_MDXNET_KARA_2.onnx")
JELLYFIN = os.environ.get("JELLYFIN_URL", "").rstrip("/")
KEY = os.environ.get("JELLYFIN_API_KEY", "")
PATH_MAP = [tuple(p.split("=", 1)) for p in os.environ.get("PATH_MAP", "").split(",") if "=" in p]
MAX_QUEUED = 20
MAX_SECONDS = 1200
lock = threading.RLock()
log = logging.getLogger("karaoke")
RUNTIME = None
HTTP = HttpPool()
# Song id -> (when checked, its original's current revision). Playing a mix makes many range requests; each one
# needn't ask Jellyfin again whether the original changed.
REVISIONS = {}
REVISION_SECONDS = 30


def track_id(value):
    value = value.replace("-", "").lower()
    if not re.fullmatch(r"[0-9a-f]{32}", value):
        raise HTTPException(400, "Invalid Jellyfin song ID")
    return value


def connect():
    connection = sqlite3.connect(ROOT / "jobs.db", timeout=15)
    connection.row_factory = sqlite3.Row
    return connection


def source_for(song):
    try:
        response = HTTP.request('GET', f"{JELLYFIN}/Items", params={"Ids": song, "Fields": "Path", "Limit": 1},
                                headers={"Authorization": f'MediaBrowser Token="{KEY}"'}, timeout=15)
        with response:
            response.raise_for_status()
            items = response.json().get("Items", [])
        if not items:
            raise HTTPException(404, "The song is no longer in Jellyfin")
        item = items[0]
    except (requests.RequestException, ValueError):
        raise HTTPException(502, "Could not read the song from Jellyfin") from None
    return source_item(item)


def source_item(item):
    if item.get('Type') != 'Audio' or not item.get('Path'):
        raise HTTPException(404, 'This item is not an audio file')
    original = item['Path']
    path = None
    maps = PATH_MAP or [(os.environ.get('MUSIC_DIR', '/music'), os.environ.get('MUSIC_DIR', '/music'))]
    for before, after in sorted(maps, key=lambda pair: -len(pair[0])):
        if original.startswith(before.rstrip("/") + "/"):
            candidate = (Path(after) / original[len(before.rstrip('/')) + 1:]).resolve()
            if candidate.is_relative_to(Path(after).resolve()):
                path = candidate
            break
    if path is None or not path.is_file():
        raise HTTPException(404, "The server cannot read this music file")
    stat = path.stat()
    revision = hashlib.sha256(f"{MODEL}:v2:{path}:{stat.st_size}:{stat.st_mtime_ns}".encode()).hexdigest()
    return path, revision


def sources_for(songs):
    if not songs:
        return {}
    try:
        response = HTTP.request('GET', f'{JELLYFIN}/Items',
            params={'Ids': ','.join(songs), 'Fields': 'Path', 'Limit': len(songs)},
            headers={'Authorization': f'MediaBrowser Token="{KEY}"'}, timeout=15)
        with response:
            response.raise_for_status()
            items = response.json().get('Items', [])
    except (requests.RequestException, ValueError):
        raise HTTPException(502, 'Could not read the songs from Jellyfin') from None
    result = {}
    for item in items:
        value = track_id(item['Id'])
        if value in songs:
            try:
                result[value] = source_item(item)
            except (HTTPException, OSError):
                continue
    return result


def read_result(directory):
    manifest = json.loads((directory / 'result.json').read_text())
    mixes = manifest['mixes']
    for guide in (0, 25, 50, 75, 100):
        mix = mixes[str(guide)]
        size = mix['bytes']
        if type(size) is not int or size <= 0 or (directory / f'mix-{guide}.flac').stat().st_size != size:
            raise ValueError('Incomplete cached audio')
        if mix['version'] != 1 or not all(type(mix[key]) in (int, float) and math.isfinite(mix[key])
                                        for key in ('lufs', 'truePeak')):
            raise ValueError('Invalid cached loudness')
    seconds = manifest['seconds']
    if type(seconds) not in (int, float) or not math.isfinite(seconds) or seconds < 0:
        raise ValueError('Invalid preparation time')
    # Cache metadata cannot replace the queue's state or revision.
    return {key: manifest[key] for key in ('mixes', 'seconds', 'model') if key in manifest}


def describe(row):
    if row is None:
        return {"state": "missing", "progress": 0}
    result = {"state": row["state"], "revision": row["revision"], "progress": row["progress"],
              "message": row["message"], "seconds": row["seconds"]}
    if row["state"] == "ready":
        try:
            result.update(read_result(ROOT / row['revision']))
        except (OSError, ValueError, TypeError, KeyError):
            result.update(state="missing", progress=0, message="Prepare this song again")
    return result


def update(song, revision, **values):
    with lock, connect() as connection:
        connection.execute(f"UPDATE jobs SET {','.join(k + '=?' for k in values)} WHERE id=? AND revision=?",
                           [*values.values(), song, revision])


def work(stop):
    while not stop.wait(1):
        try:
            with ExitStack() as leases:
                work_one(stop, leases)
        except Exception as error:
            log.warning('Karaoke queue temporarily unavailable (%s)', type(error).__name__)
            stop.wait(5)


def work_one(stop, leases):
    runtime = RUNTIME
    with lock, connect() as connection:
        row = connection.execute("SELECT * FROM jobs WHERE state='queued' ORDER BY queued LIMIT 1").fetchone()
        if row is None:
            return
        if runtime:
            lease, reason = runtime.try_acquire('karaoke')
            if reason:
                connection.execute("UPDATE jobs SET message=? WHERE id=? AND message<>?", (reason, row['id'], reason))
                return
            leases.callback(runtime.release, 'karaoke', lease)
        connection.execute("UPDATE jobs SET state='processing',progress=0.02,message='Loading vocal separation model' WHERE id=?", (row["id"],))
    song, revision = row["id"], row["revision"]
    destination = ROOT / revision
    try:
        path, current = source_for(song)
        if current != revision:
            raise RuntimeError("The original song changed; prepare it again")
        duration = float(json.loads(subprocess.run(
            ['ffprobe', '-v', 'error', '-show_entries', 'format=duration', '-of', 'json', str(path)],
            capture_output=True, text=True, check=True, timeout=30,
        ).stdout)['format']['duration'])
        if duration <= 0 or duration > MAX_SECONDS:
            raise RuntimeError("Choose a song shorter than 20 minutes")
        if shutil.disk_usage(ROOT).free < 2 * 1024 ** 3:
            raise RuntimeError("The server needs at least 2 GB of free cache space")
        destination.mkdir(exist_ok=True)
        for file in destination.iterdir():
            if file.is_file() and file.suffix in ('.wav', '.flac', '.json', '.tmp'):
                file.unlink()
        with (destination / 'worker.log').open('w') as output:
            process = subprocess.Popen(
                [sys.executable, str(Path(__file__).with_name('karaoke_worker.py')), str(path),
                 str(destination), str(ROOT / 'models'), MODEL], stdout=output, stderr=output,
            )
            started = time.monotonic()
            while process.poll() is None:
                elapsed = time.monotonic() - started
                if stop.wait(2) or elapsed > max(3600, duration * 12):
                    process.kill()
                    process.wait()
                    raise RuntimeError("Preparation interrupted; tap Prepare to retry")
                # Stage progress, never an invented ETA or percentage for neural inference.
                count = len(list(destination.glob('mix-*.flac')))
                progress = destination / 'progress.json'
                separation = json.loads(progress.read_text()) if progress.is_file() else {
                    'progress': .05, 'message': 'Loading the model and separating vocals'}
                update(song, revision, **(separation if count == 0 else {
                    'progress': .75 + count * .04, 'message': f'Preparing guide-vocal mixes ({count}/5)'}))
            if process.returncode:
                raise RuntimeError("Vocal separation failed; the server may need more memory")
        if source_for(song)[1] != revision:
            raise RuntimeError("The original song changed during preparation; prepare it again")
        manifest = read_result(destination)
        update(song, revision, state='ready', progress=1, message='Ready', seconds=manifest['seconds'])
    except Exception as error:
        log.warning('Karaoke preparation failed for %s: %s', song, type(error).__name__)
        message = error.detail if isinstance(error, HTTPException) else str(error)
        # Finish cleanup before making the job available for retry or deletion.
        with lock:
            if destination.is_dir():
                for file in destination.iterdir():
                    if file.suffix in ('.wav', '.flac', '.json'):
                        file.unlink(missing_ok=True)
            update(song, revision, state='failed', progress=0, message=message[:180])


@asynccontextmanager
async def lifespan(_):
    global RUNTIME
    ROOT.mkdir(parents=True, exist_ok=True)
    with connect() as connection:
        connection.execute('CREATE TABLE IF NOT EXISTS jobs (id TEXT PRIMARY KEY, revision TEXT, state TEXT, progress REAL, message TEXT, queued REAL, seconds REAL)')
        connection.execute("UPDATE jobs SET state='failed',progress=0,message='Server restarted; tap Prepare to retry' WHERE state='processing'")
    stop = threading.Event()
    RUNTIME = RuntimeGovernor(ROOT.parent, role='karaoke')
    RUNTIME.start()
    worker = threading.Thread(target=work, args=(stop,), daemon=True)
    worker.start()
    yield
    stop.set()
    worker.join(timeout=10)
    RUNTIME.close()
    RUNTIME = None
    HTTP.close()


app = FastAPI(title='Finamp+ karaoke', lifespan=lifespan)


def authorize(x_api_key: str = Header(default='')):
    if token_problem(TOKEN) or not hmac.compare_digest(x_api_key.encode(), TOKEN.encode()):
        raise HTTPException(401, 'Invalid API key')


@app.get('/healthz', include_in_schema=False)
def healthz():
    """For Docker's health check: answers without the token, and says nothing about the queue."""
    return {'ok': True}


@app.get('/karaoke', dependencies=[Depends(authorize)])
def catalogue(offset: int = Query(0, ge=0), limit: int = Query(50, ge=1, le=100), state: str = ''):
    if state not in ('', 'queued', 'processing', 'ready', 'failed'):
        raise HTTPException(400, 'Invalid karaoke state')
    where, parameters = (' WHERE state=?', [state]) if state else ('', [])
    with lock, connect() as connection:
        total = connection.execute('SELECT COUNT(*) FROM jobs' + where, parameters).fetchone()[0]
        rows = connection.execute('SELECT * FROM jobs' + where +
            " ORDER BY CASE state WHEN 'processing' THEN 0 WHEN 'queued' THEN 1 WHEN 'failed' THEN 2 ELSE 3 END, queued DESC, id LIMIT ? OFFSET ?",
            [*parameters, limit, offset]).fetchall()
    # Do not expose music paths, worker logs, API keys or cached file locations.
    return {'items': [{'id': row['id'], **describe(row)} for row in rows], 'total': total,
            'offset': offset, 'limit': limit}


def current_revision(song, fresh=True):
    now = time.monotonic()
    cached = REVISIONS.get(song)
    if not fresh and cached and now - cached[0] < REVISION_SECONDS:
        return cached[1]
    value = source_for(song)[1]
    if len(REVISIONS) > 512:
        REVISIONS.clear()
    REVISIONS[song] = (now, value)
    return value


class StatusRequest(BaseModel):
    ids: list[str] = Field(max_length=200)


@app.post('/karaoke/status', dependencies=[Depends(authorize)])
def statuses(request: StatusRequest):
    songs = list(dict.fromkeys(track_id(value) for value in request.ids))
    if not songs:
        return {}
    with lock, connect() as connection:
        rows = {row['id']: row for row in connection.execute(
            f"SELECT * FROM jobs WHERE id IN ({','.join('?' * len(songs))})", songs)}
    ready = [value for value, row in rows.items() if row['state'] == 'ready']
    sources = sources_for(ready)
    result = {}
    for value in songs:
        row = rows.get(value)
        if row and row['state'] == 'ready' and sources.get(value, (None, None))[1] != row['revision']:
            result[value] = {'state': 'missing', 'progress': 0,
                'message': 'The original song changed or is unavailable; prepare it again'}
        else:
            result[value] = describe(row)
    return result


@app.get('/karaoke/{song}', dependencies=[Depends(authorize)])
def status(song: str):
    return job_status(track_id(song))


def job_status(song, fresh=True):
    with lock, connect() as connection:
        row = connection.execute('SELECT * FROM jobs WHERE id=?', (song,)).fetchone()
    if row and row['state'] == 'ready' and current_revision(song, fresh) != row['revision']:
        return {'state': 'missing', 'progress': 0, 'message': 'The original song changed; prepare it again'}
    return describe(row)


@app.post('/karaoke/{song}', dependencies=[Depends(authorize)], status_code=202)
def enqueue(song: str):
    song = track_id(song)
    _, revision = source_for(song)
    with lock, connect() as connection:
        row = connection.execute('SELECT * FROM jobs WHERE id=?', (song,)).fetchone()
        if row and row['revision'] == revision and describe(row)['state'] in ('queued', 'processing', 'ready'):
            return describe(row)
        if row and row['state'] == 'processing':
            raise HTTPException(409, 'Wait for the current preparation to finish')
        if connection.execute("SELECT COUNT(*) FROM jobs WHERE state IN ('queued','processing')").fetchone()[0] >= MAX_QUEUED:
            raise HTTPException(429, 'The karaoke queue is full; try again later')
        connection.execute('INSERT OR REPLACE INTO jobs VALUES (?,?,?,?,?,?,?)',
                           (song, revision, 'queued', 0, 'Waiting for the server', time.time(), None))
        row = connection.execute('SELECT * FROM jobs WHERE id=?', (song,)).fetchone()
    return describe(row)


@app.delete('/karaoke/{song}', dependencies=[Depends(authorize)])
def delete(song: str, revision: str = ''):
    song = track_id(song)
    with lock, connect() as connection:
        row = connection.execute('SELECT * FROM jobs WHERE id=?', (song,)).fetchone()
        if row is None:
            return {'state': 'missing'}
        if revision and revision != row['revision']:
            raise HTTPException(409, 'The karaoke preparation changed; refresh and try again')
        if row['state'] == 'processing':
            raise HTTPException(409, 'Wait for this karaoke preparation to finish before deleting it')
        # Duplicate Jellyfin entries can share one source revision and cache.
        shared = connection.execute('SELECT 1 FROM jobs WHERE revision=? AND id<>?',
                                    (row['revision'], song)).fetchone()
        if not shared:
            if not re.fullmatch(r'[a-f0-9]{64}', row['revision'] or ''):
                raise HTTPException(409, 'Invalid karaoke cache revision')
            directory = ROOT / row['revision']
            if directory.is_symlink() or directory.resolve().parent != ROOT.resolve():
                raise HTTPException(409, 'Invalid karaoke cache directory')
            if directory.exists():
                try:
                    shutil.rmtree(directory)
                except OSError:
                    raise HTTPException(500, 'Could not delete the karaoke cache; try again') from None
        connection.execute('DELETE FROM jobs WHERE id=?', (song,))
    return {'state': 'missing'}


@app.get('/karaoke/{song}/audio', dependencies=[Depends(authorize)])
def audio(song: str, guide: int = Query(0, ge=0, le=100), revision: str = ''):
    song = track_id(song)
    if guide not in (0, 25, 50, 75, 100):
        raise HTTPException(400, 'Guide vocals must be 0, 25, 50, 75 or 100')
    result = job_status(song, fresh=False)
    if result['state'] != 'ready' or result['revision'] != revision:
        raise HTTPException(409, 'This karaoke version is no longer available; prepare it again')
    marker = ROOT / revision / '.last-used'
    if not marker.exists() or time.time() - marker.stat().st_mtime >= 60:
        marker.touch()
    return FileResponse(ROOT / revision / f'mix-{guide}.flac', media_type='audio/flac',
                        headers={'Cache-Control': 'private, max-age=86400'})
