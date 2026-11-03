"""One continuous, bounded MP3 broadcast, independent of phone connections. It rests while nobody is listening."""
import hashlib
import logging
import queue
import random
import sqlite3
import subprocess
import threading
import time
from datetime import datetime
from zoneinfo import ZoneInfo

from fastapi import HTTPException

from hub_core import revision, song_id

log = logging.getLogger('hub')


def scheduled_program(settings, now=None):
    programs = sorted(settings['radioPrograms'], key=lambda value: value['start'])
    fixed = settings.get('radioProgram', 'scheduled')
    if fixed != 'scheduled':
        return next((program for program in programs if program['id'] == fixed), programs[0])
    hour = (now or datetime.now(ZoneInfo(settings['timezone']))).hour
    return next((program for program in reversed(programs) if program['start'] <= hour), programs[-1])


class Radio:
    # How long the station keeps playing after its last listener leaves, so a reconnecting phone hears it continue.
    IDLE_SECONDS = 120

    def __init__(self, hub):
        self.hub = hub
        self.thread = None
        self.lock = threading.RLock()
        self.encoder = self.decoder = None
        self.listeners = set()
        self.current = None
        self.message = 'Station is off'
        self.program = None
        self.recent = []
        self.last_artist = None
        # Starts resting: nothing is decoded or read from disk until someone tunes in.
        self.idle_since = time.monotonic() - self.IDLE_SECONDS
        self.wake = threading.Event()

    def start(self):
        if self.thread is None or not self.thread.is_alive():
            self.thread = threading.Thread(target=self.run, daemon=True, name='hub-radio')
            self.thread.start()

    def stop_audio(self):
        with self.lock:
            processes = [self.decoder, self.encoder]
            self.decoder = self.encoder = None
        for process in processes:
            if process is None:
                continue
            try:
                process.terminate()
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=3)
            except OSError:
                pass

    def state(self):
        with self.lock:
            return {'enabled': self.hub.store.settings()['radioEnabled'], 'program': self.program,
                'song': self.current, 'message': self.message, 'listeners': len(self.listeners)}

    def listen(self):
        listener = queue.Queue(maxsize=64)
        with self.lock:
            if len(self.listeners) >= 8:
                raise HTTPException(429, 'The station has reached its listener limit')
            self.listeners.add(listener)
            self.idle_since = None
        self.wake.set()

        def chunks():
            try:
                while not self.hub.stop_event.is_set() and self.hub.store.settings()['radioEnabled']:
                    try:
                        packet = listener.get(timeout=3)
                    except queue.Empty:
                        continue
                    if packet is None:
                        break
                    yield packet
            finally:
                with self.lock:
                    self.listeners.discard(listener)
                    self._note_left()
        return chunks()

    def _note_left(self):
        if not self.listeners and self.idle_since is None:
            self.idle_since = time.monotonic()

    def idle(self):
        """Nobody has listened for a while: the station rests instead of decoding and encoding for no one."""
        with self.lock:
            return self.idle_since is not None and time.monotonic() - self.idle_since >= self.IDLE_SECONDS

    def pump(self, encoder):
        try:
            while not self.hub.stop_event.is_set():
                packet = encoder.stdout.read(4096)
                if not packet:
                    break
                with self.lock:
                    for listener in list(self.listeners):
                        try:
                            listener.put_nowait(packet)
                        except queue.Full:
                            self.listeners.remove(listener)
                            # Make a slow consumer exit rather than grow memory.
                            while not listener.empty():
                                listener.get_nowait()
                            listener.put_nowait(None)
                    self._note_left()
        finally:
            encoder.stdout.close()

    def gain(self, item, path):
        try:
            with sqlite3.connect(f'file:{self.hub.data}/loudness.db?mode=ro', uri=True) as db:
                columns = {row[1] for row in db.execute('PRAGMA table_info(tracks)')}
                peak = 'true_peak' if 'true_peak' in columns else 'truePeak'
                if peak not in columns or 'lufs' not in columns:
                    return 0
                row = db.execute(f'SELECT lufs,{peak},signature,version FROM tracks WHERE id=? AND error IS NULL', (song_id(item['Id']),)).fetchone()
                stat = path.stat()
                expected = hashlib.sha256(f'{row[3]}:{path}:{stat.st_size}:{stat.st_mtime_ns}'.encode()).hexdigest() if row else None
                if row and row[2] == expected and row[0] is not None and row[1] is not None:
                    return max(-24, min(12, -14 - float(row[0]), -1 - float(row[1])))
        except (sqlite3.Error, ValueError, TypeError, OSError):
            pass
        return 0

    def candidates(self, settings, program):
        owner = settings['owner']
        values = self.hub.jellyfin.items(owner, limit=500, favorites=program['mode'] == 'favourites', random=True)
        if not values and program['mode'] == 'favourites':
            values = self.hub.jellyfin.items(owner, limit=500, random=True)
        blocked = self.hub.blocked(owner)
        values = [item for item in values if song_id(item['Id']) not in blocked]
        if program['mode'] == 'chill':
            try:
                with sqlite3.connect(f'file:{self.hub.data}/analysis.db?mode=ro', uri=True) as db:
                    energy = dict(db.execute('SELECT id,energy FROM tracks WHERE energy IS NOT NULL AND error IS NULL'))
                values.sort(key=lambda item: energy.get(song_id(item['Id']), 1e9))
                values = values[:max(20, len(values) // 3)]
            except sqlite3.Error:
                pass
        return values

    def choose(self, values, program):
        recent = set(self.recent[-min(50, max(0, len(values) - 1)):]) if len(values) > 1 else set()
        available = [item for item in values if song_id(item['Id']) not in recent] or values
        other_artists = [item for item in available if self.artist(item) != self.last_artist]
        if not other_artists:
            other_artists = [item for item in values if self.artist(item) != self.last_artist]
        if other_artists:
            available = other_artists
        unheard = random.randrange(100) < program.get('discovery', 50)
        matching = [item for item in available if
            ((item.get('UserData') or {}).get('PlayCount', 0) == 0 and not (item.get('UserData') or {}).get('Played')) == unheard]
        return random.choice(matching or available) if available else None

    @staticmethod
    def artist(item):
        return (item.get('AlbumArtist') or '|'.join(item.get('Artists') or [])).strip().casefold()

    def run(self):
        values, cache_key, refreshed = [], None, 0
        since_intro, last_program, logged = 5, None, float('-inf')
        while not self.hub.stop_event.is_set():
            settings = self.hub.store.settings()
            if not settings['radioEnabled'] or not settings['owner']:
                self.stop_audio()
                with self.lock:
                    self.current, self.message = None, 'Station is off'
                self.hub.stop_event.wait(2)
                continue
            if self.idle():
                self.stop_audio()
                with self.lock:
                    self.current, self.message = None, 'Waiting for a listener'
                # The station introduction plays again when someone tunes in.
                last_program = None
                self.wake.wait(2)
                self.wake.clear()
                continue
            try:
                program = scheduled_program(settings)
                key = (settings['owner'], program['id'])
                if key != cache_key or time.time() - refreshed > 600 or not values:
                    values = self.candidates(settings, program)
                    cache_key, refreshed = key, time.time()
                item = self.choose(values, program)
                if item is None:
                    raise RuntimeError('No matching songs; add music or change this station')
                path = self.hub.jellyfin.path(item)
                with self.lock:
                    self.program, self.current = program, self.hub.jellyfin.brief(item)
                    self.message = 'Broadcasting'
                if self.encoder is None or self.encoder.poll() is not None:
                    self.encoder = subprocess.Popen(['ffmpeg', '-nostdin', '-hide_banner', '-loglevel', 'error',
                        '-re', '-f', 's16le', '-ar', '48000', '-ac', '2', '-i', 'pipe:0', '-vn',
                        '-c:a', 'libmp3lame', '-b:a', '160k', '-f', 'mp3', 'pipe:1'],
                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
                    threading.Thread(target=self.pump, args=(self.encoder,), daemon=True).start()
                encoder = self.encoder
                intro = self.hub.store.root / 'announcements' / f'{program["id"]}.mp3'
                if intro.is_file() and (since_intro >= 5 or last_program != program['id']):
                    self.feed(intro, encoder)
                    since_intro = 0
                last_program = program['id']
                started = time.time()
                self.feed(path, encoder, self.gain(item, path))
                since_intro += 1
                self.last_artist = self.artist(item)
                self.recent = [*self.recent[-99:], song_id(item['Id'])]
                if time.time() - started < 1:
                    values = [other for other in values if other['Id'] != item['Id']]
                    self.hub.stop_event.wait(1)
            except Exception as error:
                self.stop_audio()
                with self.lock:
                    self.message = str(error) if isinstance(error, RuntimeError) else 'Station is reconnecting'
                if time.monotonic() - logged > 600:
                    logged = time.monotonic()
                    log.warning('Radio is reconnecting (%s: %s)', type(error).__name__, getattr(error, 'detail', error))
                self.hub.stop_event.wait(5)
        self.stop_audio()

    def feed(self, path, encoder, gain=0):
        decoder = subprocess.Popen(['ffmpeg', '-nostdin', '-hide_banner', '-loglevel', 'error',
            '-threads', '1', '-i', str(path), '-map', '0:a:0', '-vn', '-sn', '-dn',
            '-af', f'volume={gain}dB', '-f', 's16le', '-ar', '48000', '-ac', '2', 'pipe:1'],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        with self.lock:
            self.decoder = decoder
        try:
            while not self.hub.stop_event.is_set() and self.hub.store.settings()['radioEnabled'] and not self.idle():
                samples = decoder.stdout.read(32768)
                if not samples:
                    break
                encoder.stdin.write(samples)
            encoder.stdin.flush()
        finally:
            decoder.stdout.close()
            if decoder.poll() is None:
                decoder.terminate()
            try:
                decoder.wait(timeout=5)
            except subprocess.TimeoutExpired:
                decoder.kill()
                decoder.wait(timeout=3)
            with self.lock:
                if self.decoder is decoder:
                    self.decoder = None
