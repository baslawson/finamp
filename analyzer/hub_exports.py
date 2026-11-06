"""Karaoke mixes as files: converted on request, then downloaded by the listener or through a link that expires."""
import hashlib
import json
import os
import re
import secrets
import subprocess
import time

from fastapi import HTTPException
from fastapi.responses import FileResponse, Response

from hub_core import song_id

# Media type, then ffmpeg's encoder and muxer settings. The mixes are 16-bit 44.1 kHz FLAC, so WAV stays 16-bit and FLAC
# is copied as it is, only its tags changed.
FORMATS = {
    'flac': ('audio/flac', ['-c:a', 'copy', '-f', 'flac']),
    'wav': ('audio/wav', ['-c:a', 'pcm_s16le', '-f', 'wav']),
    'mp3': ('audio/mpeg', ['-c:a', 'libmp3lame', '-b:a', '320k', '-id3v2_version', '3', '-f', 'mp3']),
}
PARTS = ('vocals', 'drums', 'both')
GUIDES = (0, 25, 50, 75, 100)
LINK_HOURS = (1, 24, 168)
MOST_LINKS = 20
# The phone downloads a prepared file straight away; the ticket only has to outlast a slow connection.
TICKET_SECONDS = 600
# A converted file nobody downloaded for this long is removed, unless a link still offers it.
KEEP_DAYS = 7
_CONTROL = re.compile(r'[\x00-\x1f\x7f]+')


def label(part, guide):
    """How a mix is described in its file name and title: "No vocals", "No drums, guide 25%"."""
    base = {'vocals': 'No vocals', 'drums': 'No drums', 'both': 'No vocals or drums'}[part]
    if not guide:
        return base
    # The guide brought back is the last part taken out: drums, when both were.
    return f'{base}, guide {"drums " if part == "both" else ""}{guide}%'


def clean(text, limit=300):
    return re.sub(r'\s+', ' ', _CONTROL.sub(' ', str(text or ''))).strip()[:limit]


def file_name(artist, title, part, guide, fmt):
    stem = f'{artist} - {title}' if artist else title
    # Characters that phones, Windows or a zip can't keep in a name.
    stem = re.sub(r'[/\\:*?"<>|]+', ' ', clean(stem, 400))
    # File systems allow 255 bytes in a name, and the phone adds ".partial" while downloading: 180 bytes leaves room
    # for that, the mix's label and the extension, in any script.
    stem = re.sub(r'\s+', ' ', stem).strip(' .').encode()[:180].decode(errors='ignore').strip(' .') or 'Karaoke'
    return f'{stem} ({label(part, guide)}).{fmt}'


def details(item, part, guide, fmt):
    """The file name and tags of a song's mix, from the song as Jellyfin has it."""
    title = clean(item.get('Name') or 'Unknown song')
    artist = clean(', '.join(item.get('Artists') or []) or item.get('AlbumArtist') or '')
    return {'title': clean(f'{title} ({label(part, guide)})'), 'artist': artist, 'album': clean(item.get('Album')),
        'album_artist': clean(item.get('AlbumArtist')), 'name': file_name(artist, title, part, guide, fmt)}


TAGS = ('title', 'artist', 'album', 'album_artist')


def tag_key(about):
    """Names a converted file's tags: a song whose details change in Jellyfin, or another entry sharing its mix, gets a
    file of its own."""
    return hashlib.sha256(json.dumps([clean(about.get(key)) for key in TAGS]).encode()).hexdigest()[:16]


def choice(values):
    """The song, part, guide level and format asked for, checked."""
    if not isinstance(values, dict):
        raise HTTPException(400, 'Invalid download request')
    value = song_id(values.get('song'))
    part = values.get('part', 'vocals')
    if part not in PARTS:
        raise HTTPException(400, 'Unknown karaoke part')
    guide = values.get('guide', 0)
    if type(guide) is not int or guide not in GUIDES:
        raise HTTPException(400, 'Guide levels are 0, 25, 50, 75 or 100')
    fmt = values.get('format')
    if fmt not in FORMATS:
        raise HTTPException(400, 'Choose FLAC, WAV or MP3')
    return value, part, guide, fmt


class Exports:
    def __init__(self, hub):
        self.hub = hub

    @property
    def folder(self):
        folder = self.hub.store.root / 'exports'
        folder.mkdir(exist_ok=True, mode=0o700)
        return folder

    def target(self, version, guide, fmt, tags):
        if (not re.fullmatch('[0-9a-f]{64}', str(version)) or guide not in GUIDES or fmt not in FORMATS
                or not re.fullmatch('[0-9a-f]{16}', str(tags))):
            raise HTTPException(400, 'Invalid karaoke file')
        return self.folder / f'{version}-{guide}-{tags}.{fmt}'

    def current(self, value, part):
        """The ready mix's revision, which names its folder and changes when the song is prepared again."""
        job = self.hub.karaoke('GET', f'/karaoke/{value}', params={'part': part})
        version = str(job.get('revision') or '')
        if job.get('state') != 'ready' or not re.fullmatch('[0-9a-f]{64}', version):
            raise HTTPException(409, 'Prepare this karaoke mix first')
        return version

    def _checked(self, actor, values):
        value, part, guide, fmt = choice(values)
        # Only songs the listener can see in Jellyfin: the mixes are shared by everyone on the server.
        item = self.hub.jellyfin.item(actor.id, value)
        version = self.current(value, part)
        self.hub.karaoke_file(version, guide)
        return value, part, guide, fmt, version, details(item, part, guide, fmt)

    def _ready(self, actor, value, part, guide, fmt, version, about, target):
        ticket = self.hub.caps.issue('export', actor.id, seconds=TICKET_SECONDS, song=value, part=part,
            revision=version, guide=guide, format=fmt, tags=tag_key(about), name=about['name'])
        return {'state': 'ready', 'ticket': ticket, 'name': about['name'], 'bytes': target.stat().st_size,
            'revision': version}

    @staticmethod
    def _job_key(version, guide, fmt, about):
        return f'export:{version}:{guide}:{fmt}:{tag_key(about)}'

    def request(self, actor, values):
        """Starts converting the mix, or hands out a ticket for it when it's already converted."""
        value, part, guide, fmt, version, about = self._checked(actor, values)
        target = self.target(version, guide, fmt, tag_key(about))
        if target.is_file():
            return self._ready(actor, value, part, guide, fmt, version, about, target)
        job = self.hub.store.enqueue('export', self._job_key(version, guide, fmt, about),
            {'song': value, 'part': part, 'revision': version, 'guide': guide, 'format': fmt,
                **{key: about[key] for key in TAGS}})
        return {'state': 'preparing', 'job': job}

    def status(self, actor, values):
        """How a conversion is getting on, without starting one."""
        value, part, guide, fmt, version, about = self._checked(actor, values)
        target = self.target(version, guide, fmt, tag_key(about))
        if target.is_file():
            return self._ready(actor, value, part, guide, fmt, version, about, target)
        with self.hub.store.connect() as db:
            row = db.execute('SELECT state,message FROM jobs WHERE kind=? AND jobkey=? ORDER BY created DESC LIMIT 1',
                ('export', self._job_key(version, guide, fmt, about))).fetchone()
        if row and row['state'] in ('queued', 'processing'):
            return {'state': 'preparing'}
        if row and row['state'] == 'failed':
            return {'state': 'failed', 'message': row['message']}
        return {'state': 'missing'}

    def convert(self, args):
        """The export job: the mix converted to the format, tagged, in the exports folder."""
        version, guide, fmt = args['revision'], args['guide'], args['format']
        target = self.target(version, guide, fmt, tag_key(args))
        if self.current(song_id(args['song']), args['part']) != version:
            raise HTTPException(409, 'The song was prepared again; ask for the file again')
        source = self.hub.karaoke_file(version, guide)
        if target.is_file():
            return 'The file was already prepared'
        temporary = target.with_name(f'.{target.stem}.partial.{fmt}')
        command = ['ffmpeg', '-nostdin', '-v', 'error', '-threads', '1', '-i', str(source),
            '-map', '0:a:0', '-vn', '-map_metadata', '-1']
        for key in TAGS:
            if clean(args.get(key)):
                command += ['-metadata', f'{key}={clean(args.get(key))}']
        command += [*FORMATS[fmt][1], '-y', str(temporary)]
        jobs = self.hub.jobs
        try:
            jobs.process = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if jobs.process.wait(timeout=300):
                raise HTTPException(502, 'The server could not convert this mix')
            if temporary.stat().st_size < 100:
                raise HTTPException(502, 'The converted file is empty')
            temporary.replace(target)
            os.chmod(target, 0o600)
        finally:
            if jobs.process and jobs.process.poll() is None:
                jobs.process.kill()
                jobs.process.wait()
            jobs.process = None
            temporary.unlink(missing_ok=True)
        self.hub.touch_cache(version)
        return f'{fmt.upper()} file is ready'

    def _send(self, target, fmt, name, version):
        # Downloads count as use, for both the converted file and the mix it came from.
        os.utime(target)
        self.hub.touch_cache(version)
        return FileResponse(target, media_type=FORMATS[fmt][0], filename=name)

    def file(self, ticket):
        cap = self.hub.caps.read(ticket, {'export'})
        # A disabled account's tickets stop working with it.
        self.hub.cached_actor(owner=cap['owner'])
        target = self.target(cap.get('revision'), cap.get('guide'), cap.get('format'), cap.get('tags'))
        if not target.is_file():
            raise HTTPException(404, 'Prepare this file again')
        return self._send(target, cap['format'], str(cap.get('name') or target.name), cap['revision'])

    def create_link(self, actor, values, base):
        """A link anyone can download the converted file from until it expires or is stopped."""
        hours = values.get('hours', 24) if isinstance(values, dict) else None
        if type(hours) is not int or hours not in LINK_HOURS:
            raise HTTPException(400, 'Links last 1 hour, 24 hours or 7 days')
        value, part, guide, fmt, version, about = self._checked(actor, values)
        tags = tag_key(about)
        if not self.target(version, guide, fmt, tags).is_file():
            raise HTTPException(409, 'Prepare the file before sharing it')
        now, link = time.time(), secrets.token_hex(16)
        store = self.hub.store
        with store.lock, store.connect() as db:
            db.execute('DELETE FROM links WHERE expires<=?', (now,))
            if db.execute('SELECT COUNT(*) FROM links WHERE owner=?', (actor.id,)).fetchone()[0] >= MOST_LINKS:
                raise HTTPException(429, f'Stop one of your download links first (at most {MOST_LINKS})')
            db.execute('INSERT INTO links VALUES(?,?,?,?,?,?,?,?,?,?,?,?)',
                (link, actor.id, value, part, version, guide, fmt, about['name'], now, now + hours * 3600, 0, tags))
        return self._describe(self._row(link), base)

    def _row(self, link):
        with self.hub.store.connect() as db:
            return db.execute('SELECT * FROM links WHERE id=?', (link,)).fetchone()

    def _describe(self, row, base):
        seconds = max(1, int(row['expires'] - time.time()))
        token = self.hub.caps.issue('link', row['owner'], seconds=seconds, link=row['id'])
        return {'id': row['id'], 'name': row['name'], 'format': row['format'], 'expires': row['expires'],
            'created': row['created'], 'downloads': row['downloads'], 'url': f'{base}/dl/{token}'}

    def links(self, actor, base):
        with self.hub.store.connect() as db:
            rows = db.execute('SELECT * FROM links WHERE owner=? AND expires>? ORDER BY created DESC',
                (actor.id, time.time())).fetchall()
        return [self._describe(row, base) for row in rows]

    def stop_link(self, actor, link):
        if not isinstance(link, str) or not re.fullmatch('[0-9a-f]{32}', link):
            raise HTTPException(400, 'Invalid link')
        store = self.hub.store
        with store.lock, store.connect() as db:
            if db.execute('DELETE FROM links WHERE id=? AND owner=?', (link, actor.id)).rowcount == 0:
                raise HTTPException(404, 'This link already ended')
        return {'stopped': True}

    def shared(self, token, ranged=''):
        """A download through a shared link, for someone without Finamp: errors are plain text."""
        try:
            cap = self.hub.caps.read(token, {'link'})
            row = self._row(cap.get('link')) if isinstance(cap.get('link'), str) else None
            if row is None or row['owner'] != cap['owner'] or row['expires'] <= time.time():
                raise HTTPException(410, 'This download link has expired or was stopped')
            self.hub.cached_actor(owner=row['owner'])
            target = self.target(row['revision'], row['guide'], row['format'], row['tags'])
            if not target.is_file() or self.current(row['song'], row['part']) != row['revision']:
                raise HTTPException(410, 'This download is no longer available')
        except HTTPException as error:
            message = 'This download link has expired or was stopped' if error.status_code == 401 else error.detail
            return Response(f'{message}\n', status_code=410 if error.status_code == 401 else error.status_code,
                media_type='text/plain; charset=utf-8')
        # A browser resuming a download asks for the rest; only a download from the start counts.
        if not ranged or ranged.replace(' ', '').startswith('bytes=0-'):
            store = self.hub.store
            with store.lock, store.connect() as db:
                db.execute('UPDATE links SET downloads=downloads+1 WHERE id=?', (row['id'],))
        return self._send(target, row['format'], row['name'], row['revision'])

    def prune(self):
        """Drops expired links, unfinished conversions, and converted files unused for [KEEP_DAYS] that no link offers."""
        now = time.time()
        store = self.hub.store
        with store.lock, store.connect() as db:
            db.execute('DELETE FROM links WHERE expires<=?', (now,))
            offered = {f'{row[0]}-{row[1]}-{row[3]}.{row[2]}'
                for row in db.execute('SELECT revision,guide,format,tags FROM links')}
        removed = 0
        for path in self.folder.iterdir():
            if path.is_symlink() or not path.is_file():
                continue
            age = now - path.stat().st_mtime
            if (path.name.startswith('.') and age > 3600) or (
                    not path.name.startswith('.') and path.name not in offered and age > KEEP_DAYS * 86400):
                path.unlink(missing_ok=True)
                removed += 1
        return removed

    def linked(self):
        """The revisions of the mixes that links still offer."""
        with self.hub.store.connect() as db:
            return {row[0] for row in db.execute('SELECT revision FROM links WHERE expires>?', (time.time(),))}

    def remove_for(self, version):
        """A mix's converted files go with it."""
        for path in self.folder.glob(f'{version}-*.*'):
            path.unlink(missing_ok=True)

    def size_of(self, version):
        return sum(path.stat().st_size for path in self.folder.glob(f'{version}-*.*')
            if path.is_file() and not path.is_symlink())
