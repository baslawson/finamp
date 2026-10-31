"""Bounded background jobs, karaoke cache policy and verified private backups."""
import hashlib
import json
import logging
import os
import re
import shutil
import sqlite3
import subprocess
import tarfile
import tempfile
import threading
import time
import zipfile
from contextlib import ExitStack
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo
from urllib.parse import quote

from fastapi import HTTPException

from hub_core import revision, song_id
from server_runtime import WorkDeferred, lower_worker_priority

log = logging.getLogger('hub')

def file_digest(path):
    with open(path, 'rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


class Jobs:
    def __init__(self, hub):
        self.hub = hub
        self.thread = None
        self.process = None

    def start(self):
        if self.thread is None or not self.thread.is_alive():
            self.thread = threading.Thread(target=self.run, daemon=True, name='hub-jobs')
            self.thread.start()

    def run(self):
        lower_worker_priority()
        self.remove_abandoned_backups()
        logged = float('-inf')
        while not self.hub.stop_event.wait(2):
            try:
                self.hub.reports.prune()
                self.schedule()
                self.run_one()
            except Exception as error:
                # A transient Jellyfin outage must not kill scheduling permanently. Logged at most every 10 minutes.
                if time.monotonic() - logged > 600:
                    logged = time.monotonic()
                    log.warning('Hub scheduling is unavailable (%s: %s); retrying', type(error).__name__,
                        getattr(error, 'detail', error))
                self.hub.stop_event.wait(10)

    def remove_abandoned_backups(self):
        """A backup stopped part way (by a restart) leaves its staging folder, holding database copies and API keys."""
        for folder in self.hub.store.root.glob('.backup-*'):
            if folder.is_dir() and not folder.is_symlink():
                shutil.rmtree(folder, ignore_errors=True)
                log.info('Removed an unfinished backup folder')

    def run_one(self):
        with ExitStack() as leases:
            return self._run_one(leases)

    def _run_one(self, leases):
        runtime, lease, row = self.hub.runtime, None, None
        busy = self.hub.busy() if not runtime else False
        blocked = {}
        store = self.hub.store
        with store.lock, store.connect() as db:
            pending = db.execute("SELECT * FROM jobs WHERE state='queued' ORDER BY CASE kind WHEN 'media' THEN 0 WHEN 'announcement' THEN 1 WHEN 'backup' THEN 2 ELSE 3 END,created LIMIT 100").fetchall()
            for candidate in pending:
                kind = candidate['kind']
                if kind == 'health' and busy:
                    continue
                if candidate['jobkey'].startswith('scheduled:') and kind in ('health', 'nightly', 'cleanup'):
                    settings = store.settings()
                    if datetime.now(ZoneInfo(settings['timezone'])).hour >= settings['nightlyEnd']:
                        db.execute("UPDATE jobs SET state='skipped',message='Quiet hours ended; next run is tomorrow' WHERE id=?", (candidate['id'],))
                        continue
                if runtime and kind in ('health', 'media', 'announcement', 'backup', 'verify'):
                    reason = blocked.get(kind)
                    if reason is None:
                        lease, reason = runtime.try_acquire(kind)
                        if lease is not None:
                            leases.callback(runtime.release, kind, lease)
                    if reason:
                        blocked[kind] = reason
                        db.execute("UPDATE jobs SET message=?,updated=? WHERE id=? AND message<>?",
                            (reason, time.time(), candidate['id'], reason))
                        continue
                row = candidate
                db.execute("UPDATE jobs SET state='processing',message='Working',updated=? WHERE id=?",
                    (time.time(), row['id']))
                break
        if row is None:
            return False
        args = json.loads(row['args'])
        try:
            result = {'health': self.health, 'media': self.media, 'nightly': self.nightly,
                'cleanup': self.cleanup, 'backup': self.backup, 'verify': self.verify_job,
                'announcement': self.announcement, 'lyrics': self.lyrics}[row['kind']](args)
            store.finish(row['id'], 'ready', result or 'Completed')
        except WorkDeferred as error:
            with store.lock, store.connect() as db:
                db.execute("UPDATE jobs SET state='queued',args=?,message=?,updated=? WHERE id=?",
                    (json.dumps(args), str(error), time.time(), row['id']))
        except Exception as error:
            message = error.detail if isinstance(error, HTTPException) else f'Job failed ({type(error).__name__})'
            if isinstance(error, HTTPException):
                log.warning('Hub %s job failed: %s', row['kind'], message)
            else:
                log.exception('Hub %s job failed', row['kind'])
            store.finish(row['id'], 'failed', str(message))
        return True

    def schedule(self, now=None):
        self.hub.refresh_rooms()
        settings = self.hub.store.settings()
        if not settings['owner']:
            return
        now = now or datetime.now(ZoneInfo(settings['timezone']))
        date = now.date().isoformat()
        hour, minute = now.hour, now.minute
        work = []
        if settings['backupEnabled'] and (hour, minute) >= (settings['backupHour'], settings['backupMinute']):
            work.append(('backup', {'reason': 'daily'}))
        if settings['healthEnabled'] and settings['healthHour'] <= hour < settings['nightlyEnd']:
            work.append(('health', {'limit': 100}))
        if settings['nightlyEnabled'] and settings['nightlyStart'] <= hour < settings['nightlyEnd']:
            work.append(('nightly', {}))
            work.append(('cleanup', {}))
        for kind, args in work:
            key = f'scheduled:{kind}:{date}'
            with self.hub.store.connect() as db:
                exists = db.execute('SELECT 1 FROM jobs WHERE jobkey=?', (key,)).fetchone()
            if not exists:
                self.hub.store.enqueue(kind, key, args)

    def health(self, args):
        settings = self.hub.store.settings()
        owner = settings['owner']
        limit = min(500, max(1, args.get('limit', 100)))
        offset, checked = args.get('_offset', 0), args.get('_checked', 0)
        while checked < limit and not self.hub.stop_event.is_set():
            items = self.hub.jellyfin.items(owner, limit=200, start=offset)
            if not items:
                break
            offset += len(items)
            for position, item in enumerate(items):
                if checked >= limit or self.hub.stop_event.is_set():
                    break
                if self.hub.runtime:
                    args.update(_offset=offset - len(items) + position, _checked=checked)
                    self.hub.runtime.checkpoint('health')
                elif self.hub.karaoke_busy():
                    return f'Checked {checked} songs; karaoke has priority'
                value = song_id(item['Id'])
                try:
                    path = self.hub.jellyfin.path(item)
                    version = revision(path)
                except (HTTPException, OSError):
                    # Missing sources are retried next time rather than becoming
                    # permanent exclusions during an unmounted music share.
                    continue
                with self.hub.store.connect() as db:
                    previous = db.execute('SELECT revision FROM health WHERE id=?', (value,)).fetchone()
                if previous and previous[0] == version and not args.get('force'):
                    continue
                with tempfile.TemporaryFile() as errors:
                    try:
                        self.process = subprocess.Popen(['ffmpeg', '-v', 'error', '-nostdin', '-threads', '1',
                            '-i', str(path), '-map', '0:a:0', '-vn', '-sn', '-dn', '-f', 'null', '-'],
                            stdout=subprocess.DEVNULL, stderr=errors)
                        code = self.process.wait(timeout=300)
                        errors.seek(0)
                        warning_lines = errors.read(65536).decode('utf-8', errors='replace').splitlines()
                        warnings = len(warning_lines)
                        state = 'broken' if code else 'warning' if warnings else 'healthy'
                    except subprocess.TimeoutExpired:
                        self.process.kill()
                        self.process.wait()
                        state, warnings = 'warning', 1
                    finally:
                        self.process = None
                store = self.hub.store
                with store.lock, store.connect() as db:
                    db.execute('INSERT OR REPLACE INTO health VALUES(?,?,?,?,?)',
                        (value, version, state, warnings, time.time()))
                checked += 1
            if len(items) < 200:
                break
        return f'Checked {checked} new or changed songs'

    def media(self, args):
        value, guide = song_id(args['song']), args['guide']
        if guide not in (0, 25, 50, 75, 100):
            raise HTTPException(400, 'Invalid guide vocal level')
        job = self.hub.karaoke('GET', f'/karaoke/{value}')
        if job.get('state') != 'ready' or job.get('revision') != args['revision']:
            raise HTTPException(409, 'Prepare this karaoke mix first')
        source = self.hub.karaoke_file(job['revision'], guide)
        directory = self.hub.store.root / 'media'
        directory.mkdir(exist_ok=True, mode=0o700)
        target = directory / f'{job["revision"]}-{guide}.mp3'
        if not target.is_file():
            temporary = directory / f'.{job["revision"]}-{guide}.partial.mp3'
            try:
                self.process = subprocess.Popen(['ffmpeg', '-nostdin', '-v', 'error', '-threads', '1',
                    '-i', str(source), '-map', '0:a:0', '-vn', '-c:a', 'libmp3lame', '-q:a', '3', '-y', str(temporary)],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                if self.process.wait(timeout=300):
                    raise HTTPException(502, 'The server could not prepare browser audio')
                if temporary.stat().st_size < 100:
                    raise HTTPException(502, 'Browser audio is empty')
                temporary.replace(target)
                os.chmod(target, 0o600)
            finally:
                if self.process and self.process.poll() is None:
                    self.process.kill()
                    self.process.wait()
                self.process = None
                temporary.unlink(missing_ok=True)
        self.hub.touch_cache(job['revision'])
        store = self.hub.store
        with store.lock, store.connect() as db:
            for room in db.execute('SELECT * FROM rooms WHERE expires>?', (time.time(),)).fetchall():
                state = json.loads(room['state'])
                if (state.get('song') or {}).get('id') == value and state.get('guide') == guide and state.get('revision') == job['revision']:
                    state.update(mediaReady=True, message='Ready', updated=time.time())
                    db.execute('UPDATE rooms SET state=? WHERE id=?', (json.dumps(state), room['id']))
        return 'Browser karaoke audio is ready'

    def announcement(self, args):
        program = args['program']
        if program not in {value['id'] for value in self.hub.store.settings()['radioPrograms']}:
            raise HTTPException(400, 'Radio program no longer exists')
        directory = self.hub.store.root / 'announcements'
        source, target = directory / f'{program}.wav', directory / f'{program}.mp3'
        temporary = directory / f'.{program}.partial.mp3'
        try:
            self.process = subprocess.Popen(['ffmpeg', '-nostdin', '-v', 'error', '-threads', '1', '-i', str(source),
                '-t', '30', '-map', '0:a:0', '-vn', '-c:a', 'libmp3lame', '-q:a', '3', '-y', str(temporary)],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if self.process.wait(timeout=60):
                raise HTTPException(400, 'The introduction could not be decoded')
            with self.hub.lock:
                if not source.is_file() or (args.get('version') and file_digest(source) != args['version']):
                    return 'Introduction was removed or replaced'
                temporary.replace(target)
                os.chmod(target, 0o600)
        finally:
            if self.process and self.process.poll() is None:
                self.process.kill()
                self.process.wait()
            self.process = None
            temporary.unlink(missing_ok=True)
        return 'Station introduction is ready'

    def lyrics(self, args):
        value = song_id(args['song'])
        item = self.hub.jellyfin.item(song_id(args['owner']), value)
        if self.hub.jellyfin.lyrics(value):
            return 'Timed lyrics are already available'
        def normal(text):
            return ''.join(char for char in str(text or '').casefold() if char.isalnum())
        artists = {normal(artist) for artist in item.get('Artists') or []}
        artists.add(normal(item.get('AlbumArtist')))
        artists.discard('')
        seconds = (item.get('RunTimeTicks') or 0) / 10000000
        matches = self.hub.jellyfin.json('GET', f'/Audio/{value}/RemoteSearch/Lyrics', timeout=45) or []
        eligible = []
        for match in matches:
            metadata = (match.get('Lyrics') or {}).get('Metadata') or {}
            length = (metadata.get('Length') or 0) / 10000000
            if metadata.get('IsSynced') and normal(metadata.get('Title')) == normal(item.get('Name')) and normal(metadata.get('Artist')) in artists and seconds > 0 and length > 0 and abs(seconds - length) <= 10:
                eligible.append((abs(seconds - length), match))
        if not eligible:
            return 'No timed lyrics matched this recording yet'
        match = min(eligible, key=lambda pair: pair[0])[1]
        self.hub.jellyfin.request('POST', f'/Audio/{value}/RemoteSearch/Lyrics/{quote(str(match["Id"]), safe="")}').close()
        self.hub.lyric_cache.pop(value, None)
        return 'Timed lyrics downloaded for the TV'

    def nightly(self, args):
        settings = self.hub.store.settings()
        songs = list(settings['nightlySongs'])
        if settings['nightlyFavorites']:
            songs.extend(item['Id'] for item in self.hub.jellyfin.items(settings['owner'], favorites=True, limit=500))
        songs = list(dict.fromkeys(song_id(value) for value in songs))
        count = 0
        skipped = 0
        visible, statuses = set(), {}
        for position, value in enumerate(songs):
            if count >= settings['nightlyLimit'] or self.hub.stop_event.is_set():
                break
            if position % 200 == 0:
                batch = songs[position:position + 200]
                visible = {song_id(item['Id']) for item in
                    self.hub.jellyfin.items(settings['owner'], ids=batch, limit=200)}
                allowed = [song for song in batch if song in visible]
                statuses = self.hub.karaoke('POST', '/karaoke/status', json={'ids': allowed}) if allowed else {}
            if value not in visible:
                skipped += 1
                continue
            try:
                status = statuses.get(value, {})
                if status.get('state') in ('ready', 'queued', 'processing'):
                    continue
                self.hub.karaoke('POST', f'/karaoke/{value}')
            except HTTPException as error:
                if error.status_code == 429:
                    break
                # A deleted song or an unreadable file must not hold up the rest of the night's songs.
                if error.status_code in (404, 409):
                    skipped += 1
                    continue
                raise
            count += 1
        if skipped:
            log.info('Overnight karaoke skipped %d unavailable songs', skipped)
            return f'Queued {count} songs for overnight preparation; {skipped} songs are no longer available'
        return f'Queued {count} songs for overnight preparation'

    def cleanup(self, args):
        settings = self.hub.store.settings()
        protected = set(settings['nightlySongs'])
        if settings['nightlyFavorites'] and settings['owner']:
            protected.update(song_id(item['Id']) for item in self.hub.jellyfin.items(settings['owner'], favorites=True, limit=1000))
        with self.hub.store.connect() as db:
            for row in db.execute('SELECT state FROM rooms WHERE expires>?', (time.time(),)):
                state = json.loads(row[0])
                protected.update(state.get('queue', []))
                if state.get('song'):
                    protected.add(state['song']['id'])
        root = self.hub.data / 'karaoke'
        database = root / 'jobs.db'
        if not database.is_file():
            return 'No cached mixes to clean'
        with sqlite3.connect(f'file:{database}?mode=ro', uri=True) as db:
            # Karaoke servers from before drum removal have no part column; all their mixes are vocal karaoke.
            columns = {column[1] for column in db.execute('PRAGMA table_info(jobs)')}
            part = 'part' if 'part' in columns else "'vocals'"
            rows = db.execute(f"SELECT id,revision,{part} FROM jobs WHERE state='ready'").fetchall()
        candidates, total = [], 0
        counted = set()
        for value, version, kind in rows:
            if not re.fullmatch('[0-9a-f]{64}', version):
                continue
            directory = (root / version).resolve()
            if directory.parent != root.resolve() or not directory.is_dir() or (root / version).is_symlink():
                continue
            size = sum(path.stat().st_size for path in directory.iterdir() if path.is_file() and not path.is_symlink())
            if version not in counted:
                total += size
                counted.add(version)
            marker = directory / '.last-used'
            # First adoption starts the expiry clock now, preserving old mixes.
            if not marker.exists():
                marker.touch()
            used = marker.stat().st_mtime
            candidates.append((used, value, version, size, kind))
        removed = 0
        for used, value, version, size, kind in sorted(candidates):
            if value in protected:
                continue
            expired = time.time() - used > settings['cacheDays'] * 86400
            over_budget = total > settings['cacheGB'] * 1024**3
            if not expired and not over_budget:
                continue
            # Vocal deletions stay as they were, so a karaoke server from before drum removal still accepts them.
            params = {'revision': version} if kind in ('vocals', 'mashup') else {'revision': version, 'part': kind}
            try:
                if kind == 'mashup':
                    vocals, backing = value.split('+')
                    self.hub.karaoke('DELETE', f'/mashup/{song_id(vocals)}/{song_id(backing)}', params=params)
                else:
                    self.hub.karaoke('DELETE', f'/karaoke/{song_id(value)}', params=params)
            except HTTPException as error:
                if error.status_code in (404, 409):
                    continue
                raise
            if not (root / version).exists():
                total -= size
                for media in (self.hub.store.root / 'media').glob(f'{version}-*.mp3'):
                    media.unlink(missing_ok=True)
            removed += 1
        return f'Removed {removed} unused server mixes'

    def backup(self, args):
        settings = self.hub.store.settings()
        directory = self.hub.store.root / 'backups'
        directory.mkdir(exist_ok=True, mode=0o700)
        native_root = Path(os.environ.get('JELLYFIN_BACKUP_DIR', '/jellyfin-backups')).resolve()
        if not native_root.is_dir():
            raise HTTPException(503, 'Jellyfin backup storage is not connected')
        manifest = self.hub.jellyfin.json('POST', '/Backup/Create',
            json={'Database': True, 'Metadata': False, 'Trickplay': False, 'Subtitles': False}, timeout=240)
        name = Path(manifest['Path']).name
        if not re.fullmatch(r'jellyfin-backup-[A-Za-z0-9_.-]+\.zip', name):
            raise HTTPException(502, 'Unexpected Jellyfin backup name')
        native = (native_root / name).resolve()
        if native.parent != native_root or not native.is_file():
            raise HTTPException(503, 'The Jellyfin backup is not available to the hub')
        with zipfile.ZipFile(native) as archive:
            if archive.testzip() is not None:
                raise HTTPException(502, 'Jellyfin backup verification failed')
        value = os.urandom(16).hex()
        filename = f'finamp-{datetime.now(ZoneInfo("UTC")).strftime("%Y%m%d-%H%M%S")}-{value[:8]}.tar.gz'
        target = directory / filename
        with tempfile.TemporaryDirectory(prefix='.backup-', dir=self.hub.store.root) as temporary:
            stage = Path(temporary)
            files = stage / 'files'
            files.mkdir()
            shutil.copy2(native, files / 'jellyfin.zip')
            for relative in ['analysis.db', 'loudness.db', 'karaoke/jobs.db', 'hub/hub.db']:
                source = self.hub.data / relative
                if source.is_file():
                    destination = files / relative.replace('/', '-')
                    with sqlite3.connect(f'file:{source}?mode=ro', uri=True) as original, sqlite3.connect(destination) as copied:
                        original.backup(copied)
                        if copied.execute('PRAGMA quick_check').fetchone()[0] != 'ok':
                            raise HTTPException(502, 'Database snapshot verification failed')
            configuration = {key: os.environ[key] for key in ['JELLYFIN_URL', 'JELLYFIN_API_KEY', 'ANALYZER_TOKEN',
                'KARAOKE_URL', 'PATH_MAP', 'ADVANCED_ANALYSIS'] if key in os.environ}
            (files / 'analyzer-settings.json').write_text(json.dumps(configuration))
            shutil.copy2(self.hub.store.root / '.capability-secret', files / 'hub-secret')
            inventory = {path.name: file_digest(path) for path in files.iterdir()}
            (stage / 'manifest.json').write_text(json.dumps({'format': 1, 'created': time.time(), 'files': inventory,
                'restore': 'See analyzer/README.md. Audio originals and rebuildable models/mixes are excluded.'}))
            try:
                with open(target, 'xb') as output:
                    os.chmod(target, 0o600)
                    with tarfile.open(fileobj=output, mode='w:gz') as archive:
                        archive.add(stage / 'manifest.json', arcname='manifest.json')
                        archive.add(files, arcname='files')
                self.verify_archive(target, self.hub.store.root)
            except Exception:
                target.unlink(missing_ok=True)
                raise
        store = self.hub.store
        with store.lock, store.connect() as db:
            db.execute('INSERT INTO backups VALUES(?,?,?,?,?,?)',
                (value, filename, target.stat().st_size, time.time(), time.time(), args.get('reason', 'manual')[:30]))
            old = db.execute('SELECT * FROM backups ORDER BY created DESC').fetchall()[settings['backupKeep']:]
            for row in old:
                path = (directory / row['name']).resolve()
                if path.parent == directory.resolve() and re.fullmatch(r'finamp-[0-9-]+-[0-9a-f]{8}\.tar\.gz', path.name):
                    path.unlink(missing_ok=True)
                    db.execute('DELETE FROM backups WHERE id=?', (row['id'],))
        if os.environ.get('HUB_REMOVE_NATIVE_BACKUP') == 'true':
            # Only the exact archive just created for this verified bundle.
            # Existing Jellyfin backups are never enumerated or removed.
            native.unlink(missing_ok=True)
        return 'Backup created and restored into an isolated verification folder successfully'

    @staticmethod
    def verify_archive(path, scratch=None):
        # Unpacked under [scratch] (the data volume), not the container's small /tmp; a folder left by a restart is
        # removed with the other unfinished backups.
        with tempfile.TemporaryDirectory(prefix='.backup-verify-', dir=scratch) as temporary:
            destination = Path(temporary)
            with tarfile.open(path, 'r:gz') as archive:
                names = archive.getnames()
                if len(names) != len(set(names)) or any(Path(name).is_absolute() or '..' in Path(name).parts for name in names):
                    raise HTTPException(400, 'Unsafe backup archive')
                if any(member.issym() or member.islnk() or member.isdev() for member in archive.getmembers()):
                    raise HTTPException(400, 'Unsafe backup archive member')
                archive.extractall(destination, filter='data')
            manifest = json.loads((destination / 'manifest.json').read_text())
            if manifest.get('format') != 1:
                raise HTTPException(400, 'Unknown backup format')
            for name, digest in manifest['files'].items():
                if Path(name).name != name:
                    raise HTTPException(400, 'Unsafe backup inventory')
                restored = destination / 'files' / name
                if file_digest(restored) != digest:
                    raise HTTPException(400, 'Backup checksum mismatch')
                if name.endswith('.db'):
                    with sqlite3.connect(f'file:{restored}?mode=ro', uri=True) as db:
                        if db.execute('PRAGMA quick_check').fetchone()[0] != 'ok':
                            raise HTTPException(400, 'Restored database is invalid')
                elif name == 'jellyfin.zip':
                    with zipfile.ZipFile(restored) as native:
                        if native.testzip() is not None:
                            raise HTTPException(400, 'Restored Jellyfin backup is invalid')
                        # Jellyfin 12 exports its database as JSON tables.
                        # Validate every table, not just the ZIP checksum.
                        for member in native.infolist():
                            if member.filename.endswith('.json'):
                                with native.open(member) as source:
                                    import ijson
                                    # Consume through EOF, including trailing data and truncation checks.
                                    for _ in ijson.basic_parse(source):
                                        pass

    def verify_job(self, args):
        with self.hub.store.connect() as db:
            row = db.execute('SELECT * FROM backups WHERE id=?', (song_id(args['id']),)).fetchone()
        if not row:
            raise HTTPException(404, 'Backup no longer exists')
        self.verify_archive(self.hub.store.root / 'backups' / row['name'], self.hub.store.root)
        store = self.hub.store
        with store.lock, store.connect() as db:
            db.execute('UPDATE backups SET verified=? WHERE id=?', (time.time(), row['id']))
        return 'Backup restore verification passed'
