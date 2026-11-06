"""Karaoke mixes as files: converted on request, then downloaded by the listener or through a link that expires."""
import hashlib
import hmac
import json
import logging
import os
import random
import re
import secrets
import subprocess
import threading
import time

from fastapi import HTTPException
from fastapi.responses import FileResponse, Response

from hub_core import NOT_VISIBLE, song_id

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
# What a shared link's page says to whoever opens it.
GONE = 'This download link has expired or was stopped'
UNAVAILABLE = 'This download is no longer available'
LATER = 'This download is not available right now. Try again later.'
# How long listing or making a link spends asking Jellyfin and the karaoke server: the app waits 15 seconds in all.
# The hourly cleanup, which nobody waits for, takes longer, but not so long as to hold up the jobs waiting after it.
LIST_SECONDS, LINK_SECONDS, SWEEP_SECONDS = 6, 10, 30
# How long a shared link's page asks them, so one posted where many open it doesn't keep the server's workers waiting.
SHARE_SECONDS = 10
# How long a shared link found working is taken as still so: a song prepared again ends it at most this much later.
RECHECK_SECONDS = 20
# How long one that can't be downloaded right now (Jellyfin or the karaoke server struggling, say) is taken as still so.
LATER_SECONDS = 5
# How long a link's page waits for the check another page opening it at the same moment is making: long enough for
# one with Jellyfin and the karaoke server answering (the account, the song, then the mix), short enough that many
# pages waiting on a slow one don't hold up the server's workers long.
WAIT_SECONDS = 1.5
log = logging.getLogger('hub')
# What becomes of a link: it works, it ended for good, or it can't be downloaded right now.
LIVE, ENDED, WAITING = 'live', 'ended', 'waiting'
# A shared link's owner's account disabled: its links stop working with it. A link stopped while its page waited.
DISABLED, STOPPED = 'disabled', 'stopped'
# Chat apps and sites fetching a link to show a preview of it.
PREVIEWS = re.compile(r'facebookexternalhit|WhatsApp|TelegramBot|Slackbot|Discordbot|Twitterbot|LinkedInBot|'
    r'SkypeUriPreview|Iframely|redditbot|Applebot|Googlebot|bingbot|vkShare|Pinterestbot|Embedly|Mastodon', re.I)


def link_owner(secret, link):
    """What a link's token says in place of its owner, as anyone with the link can read the token: signed with the
    hub's secret and different for each link, it can't be traced to an account or tie two links together."""
    return hmac.new(secret, f'karaoke-link:{link}'.encode(), hashlib.sha256).hexdigest()[:32]


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
        # What links' pages found (working, or not right now), and until when that's taken as still so; and the check
        # under way for each: a link opened by many at once (posted in a busy chat, say) asks Jellyfin and the karaoke
        # server once for all of them, and only so often while they struggle.
        self._found, self._checks, self._guard = {}, {}, threading.Lock()

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

    def current(self, value, part, **kwargs):
        """The ready mix's revision, which names its folder and changes when the song is prepared again."""
        job = self.hub.karaoke('GET', f'/karaoke/{value}', params={'part': part}, **kwargs)
        version = str(job.get('revision') or '')
        if job.get('state') != 'ready' or not re.fullmatch('[0-9a-f]{64}', version):
            raise HTTPException(409, 'Prepare this karaoke mix first')
        return version

    @staticmethod
    def _within(deadline):
        """The timeout for one question to Jellyfin or the karaoke server that must be answered by [deadline] (a
        time.monotonic() value; None for no deadline but their own): connecting and the answer together."""
        if deadline is None:
            return {}
        left = deadline - time.monotonic()
        if left < 0.5:
            raise HTTPException(504, 'The server took too long to answer; try again shortly')
        connect = min(2, left / 2)
        return {'timeout': (connect, left - connect)}

    def _checked(self, actor, values, deadline=None):
        value, part, guide, fmt = choice(values)
        # Only songs the listener can see in Jellyfin: the mixes are shared by everyone on the server.
        item = self.hub.jellyfin.item(actor.id, value, **self._within(deadline))
        version = self.current(value, part, **self._within(deadline))
        self.hub.karaoke_file(version, guide)
        return value, part, guide, fmt, version, details(item, part, guide, fmt)

    def _ready(self, actor, value, part, guide, fmt, version, about, target):
        ticket = self.hub.caps.issue('export', actor.id, seconds=TICKET_SECONDS, song=value, part=part,
            revision=version, guide=guide, format=fmt, tags=tag_key(about), name=about['name'])
        # Handing out a ticket counts as use, so the hourly cleanup doesn't take the file before it's downloaded: the
        # cleanup looks at a file's age and removes it under the same lock. Taken by it just before, there's no
        # ticket: the file is converted again.
        try:
            with self.hub.store.lock:
                os.utime(target)
                size = target.stat().st_size
        except FileNotFoundError:
            return None
        return {'state': 'ready', 'ticket': ticket, 'name': about['name'], 'bytes': size, 'revision': version}

    @staticmethod
    def _job_key(version, guide, fmt, about):
        return f'export:{version}:{guide}:{fmt}:{tag_key(about)}'

    def request(self, actor, values):
        """Starts converting the mix, or hands out a ticket for it when it's already converted."""
        value, part, guide, fmt, version, about = self._checked(actor, values)
        target = self.target(version, guide, fmt, tag_key(about))
        ready = self._ready(actor, value, part, guide, fmt, version, about, target)
        if ready:
            return ready
        job = self.hub.store.enqueue('export', self._job_key(version, guide, fmt, about),
            {'song': value, 'part': part, 'revision': version, 'guide': guide, 'format': fmt,
                **{key: about[key] for key in TAGS}})
        return {'state': 'preparing', 'job': job}

    def status(self, actor, values):
        """How a conversion is getting on, without starting one."""
        value, part, guide, fmt, version, about = self._checked(actor, values)
        target = self.target(version, guide, fmt, tag_key(about))
        ready = self._ready(actor, value, part, guide, fmt, version, about, target)
        if ready:
            return ready
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
        # All within the time the app waits, Jellyfin or the karaoke server slow or not.
        deadline = time.monotonic() + LINK_SECONDS
        value, part, guide, fmt, version, about = self._checked(actor, values, deadline)
        tags = tag_key(about)
        target = self.target(version, guide, fmt, tags)
        if not target.is_file():
            raise HTTPException(409, 'Prepare the file before sharing it')
        # Links that ended for good (the song got a new mix, say) don't take up a place.
        self._live_rows(actor.id, deadline)
        now, link = time.time(), secrets.token_hex(16)
        store = self.hub.store
        with store.lock, store.connect() as db:
            # Under the lock the hourly cleanup removes files under: the file is there, and stays while it's offered.
            if not target.is_file():
                raise HTTPException(409, 'Prepare the file before sharing it')
            db.execute('DELETE FROM links WHERE expires<=?', (now,))
            if db.execute('SELECT COUNT(*) FROM links WHERE owner=?', (actor.id,)).fetchone()[0] >= MOST_LINKS:
                raise HTTPException(429, f'Stop one of your download links first (at most {MOST_LINKS})')
            db.execute('INSERT INTO links VALUES(?,?,?,?,?,?,?,?,?,?,?,?)',
                (link, actor.id, value, part, version, guide, fmt, about['name'], now, now + hours * 3600, 0, tags))
        row = self._row(link)
        # Taken at once by the cleanup removing the mix it offers.
        if row is None:
            raise HTTPException(409, 'Prepare the file before sharing it')
        return self._describe(row, base)

    def _row(self, link):
        with self.hub.store.connect() as db:
            return db.execute('SELECT * FROM links WHERE id=?', (link,)).fetchone()

    def _describe(self, row, base):
        seconds = max(1, int(row['expires'] - time.time()))
        owner = link_owner(self.hub.caps.secret, row['id'])
        token = self.hub.caps.issue('link', owner, seconds=seconds, link=row['id'])
        return {'id': row['id'], 'name': row['name'], 'format': row['format'], 'expires': row['expires'],
            'created': row['created'], 'downloads': row['downloads'], 'url': f'{base}/dl/{token}'}

    def _state(self, row, known=None, deadline=None):
        """Whether a link works (LIVE); has ended for good (ENDED: its song got a new mix, or its owner can no longer
        see the song in Jellyfin), so that the same mix coming back doesn't revive it; or can't be downloaded right now
        (WAITING: the mix is being prepared again, or can't be read for a moment). When Jellyfin or the karaoke server
        can't say, the HTTPException is raised (504 once [deadline] is reached). [known] keeps the answers for other
        links to the same song."""
        known = {} if known is None else known
        access = ('access', row['owner'], row['song'])
        if access not in known:
            try:
                self.hub.jellyfin.item(row['owner'], row['song'], **self._within(deadline))
                known[access] = True
            except HTTPException as error:
                # Only Jellyfin's own word that the owner can't see the song: not a 404 from a proxy before it, say.
                if error.status_code != 404 or error.detail != NOT_VISIBLE:
                    raise
                known[access] = False
        if not known[access]:
            return ENDED
        # The mix as the karaoke server has it; None while the song's own file can't be read for a moment.
        mix = ('mix', row['song'], row['part'])
        if mix not in known:
            try:
                known[mix] = self.hub.karaoke('GET', f'/karaoke/{row["song"]}', params={'part': row['part']},
                    **self._within(deadline))
            except HTTPException as error:
                if error.status_code != 404:
                    raise
                known[mix] = None
        job = known[mix]
        if job is None:
            return WAITING
        revision = job.get('revision')
        # Ended: the song's file changed; the mix was replaced (whether or not the new one is ready); there's no mix
        # at all any more (deleted from the app, say); or preparing it again failed, so nothing is making it.
        if job.get('changed') is True or (revision and revision != row['revision']) or (
                job.get('state') == 'missing' and not revision) or job.get('state') == 'failed':
            return ENDED
        # Being prepared again, or its files unreadable for a moment.
        if job.get('state') != 'ready':
            return WAITING
        # The converted file gone while its mix stays (removed by hand, say): nothing makes it again.
        if not self.target(row['revision'], row['guide'], row['format'], row['tags']).is_file():
            return ENDED
        return LIVE

    def _drop(self, links):
        if not links:
            return
        store = self.hub.store
        with store.lock, store.connect() as db:
            db.executemany('DELETE FROM links WHERE id=?', [(link,) for link in links])

    def _sweep(self, rows, deadline):
        """[rows] less the links that ended for good, which are dropped. Jellyfin and the karaoke server are asked
        until [deadline], so the list comes in time to stop a link: the links not checked by then are kept as they
        were. So is a link they can't say about (one song Jellyfin fails on, say), and the check goes on with the next;
        once either doesn't answer at all (restarting, say), or answers something else than they would (a proxy's
        page), it isn't asked about the rest."""
        known, kept, ended = {}, [], []
        for index, row in enumerate(rows):
            try:
                (ended if self._state(row, known, deadline) == ENDED else kept).append(row)
            except HTTPException as error:
                if error.status_code in (503, 504):
                    kept.extend(rows[index:])
                    break
                kept.append(row)
            except Exception as error:
                log.warning('Download link check failed (%s)', type(error).__name__)
                kept.extend(rows[index:])
                break
        self._drop([row['id'] for row in ended])
        return kept

    def _live_rows(self, owner, deadline=None):
        """The owner's links, newest first, without those that ended for good."""
        with self.hub.store.connect() as db:
            rows = db.execute('SELECT * FROM links WHERE owner=? AND expires>? ORDER BY created DESC',
                (owner, time.time())).fetchall()
        return self._sweep(rows, deadline or time.monotonic() + LIST_SECONDS)

    def links(self, actor, base):
        return [self._describe(row, base) for row in self._live_rows(actor.id)]

    def stop_link(self, actor, link):
        if not isinstance(link, str) or not re.fullmatch('[0-9a-f]{32}', link):
            raise HTTPException(400, 'Invalid link')
        store = self.hub.store
        with store.lock, store.connect() as db:
            if db.execute('DELETE FROM links WHERE id=? AND owner=?', (link, actor.id)).rowcount == 0:
                raise HTTPException(404, 'This link already ended')
        return {'stopped': True}

    def _remembered(self, link):
        until, state = self._found.get(link, (0, None))
        return state if until > time.monotonic() else None

    def _shared_state(self, row, deadline):
        """[_state] for a shared link's page, its owner's account checked first: LIVE, ENDED (the link dropped),
        DISABLED (the owner's account, so not dropped: it works again with the account) or WAITING, which is also the
        answer when Jellyfin or the karaoke server can't say just now (a proxy's 404 while one restarts, say). One page
        checks at a time; the others opening it then wait a little for its answer (until [deadline] at most), so that
        many waiting don't keep the server's workers from everything else."""
        link = row['id']
        state = self._remembered(link)
        if state:
            return state
        # The check under way for the link, and how many pages are using it; it goes once none are.
        with self._guard:
            check = self._checks.setdefault(link, [threading.Lock(), 0])
            check[1] += 1
        try:
            return self._checked_state(row, deadline, check[0])
        finally:
            with self._guard:
                check[1] -= 1
                if not check[1] and self._checks.get(link) is check:
                    del self._checks[link]

    def _checked_state(self, row, deadline, check):
        link = row['id']
        if not check.acquire(timeout=max(0, min(deadline, time.monotonic() + WAIT_SECONDS) - time.monotonic())):
            return WAITING
        try:
            # Ended by the check another page was waited on for; or stopped (or expired) in the meantime.
            state = self._remembered(link)
            if state == ENDED:
                return state
            if self._row(link) is None:
                return STOPPED
            if state:
                return state
            try:
                try:
                    self.hub.cached_actor(owner=row['owner'], **self._within(deadline))
                except HTTPException as error:
                    # Only Jellyfin's word on the owner's account: not a 403 from a proxy on the way elsewhere.
                    if error.status_code != 403:
                        raise
                    state = DISABLED
                else:
                    state = self._state(row, deadline=deadline)
            except HTTPException:
                state = WAITING
            except Exception as error:
                # Jellyfin or the karaoke server answering something else than they would (a proxy's page, say).
                log.warning('Download link check failed (%s)', type(error).__name__)
                state = WAITING
            if state == ENDED:
                self._drop([link])
            with self._guard:
                if len(self._found) > 256:
                    self._found.clear()
                self._found[link] = (time.monotonic() + (RECHECK_SECONDS if state == LIVE else LATER_SECONDS), state)
            return state
        finally:
            check.release()

    def shared(self, token, ranged='', agent=''):
        """A download through a shared link, for someone without Finamp. Errors are plain text, and say no more than
        that the download is over or not there right now: nothing about the owner's account or the server."""
        def answer(message, status=410):
            return Response(f'{message}\n', status_code=status, media_type='text/plain; charset=utf-8')
        try:
            cap = self.hub.caps.read(token, {'link'})
        except HTTPException:
            return answer(GONE)
        try:
            row = self._row(cap.get('link')) if isinstance(cap.get('link'), str) else None
            # Links handed out before 1.6.98 name their owner plainly.
            if (row is None or cap['owner'] not in (row['owner'], link_owner(self.hub.caps.secret, row['id']))
                    or row['expires'] <= time.time()):
                return answer(GONE)
            state = self._shared_state(row, time.monotonic() + SHARE_SECONDS)
            # A disabled account's links stop working with it.
            if state in (DISABLED, STOPPED):
                return answer(GONE)
            if state == ENDED:
                return answer(UNAVAILABLE)
            if state == WAITING:
                return answer(LATER, 503)
            target = self.target(row['revision'], row['guide'], row['format'], row['tags'])
        except HTTPException:
            # The link's own details unusable.
            return answer(UNAVAILABLE)
        # A chat app looking at the link for a preview gets its name, without the file or a download counted.
        if PREVIEWS.search(agent or ''):
            return answer(f'{row["name"]} (karaoke download)', 200)
        try:
            response = self._send(target, row['format'], row['name'], row['revision'])
        except FileNotFoundError:
            # Removed in the moment since it was looked at.
            return answer(UNAVAILABLE)
        # A browser resuming a download asks for the rest; only a download from the start counts.
        if not ranged or ranged.replace(' ', '').startswith('bytes=0-'):
            store = self.hub.store
            with store.lock, store.connect() as db:
                db.execute('UPDATE links SET downloads=downloads+1 WHERE id=?', (row['id'],))
        return response

    def prune(self):
        """Drops expired links and those that ended for good, unfinished conversions, and converted files unused for
        [KEEP_DAYS] that no link offers."""
        now = time.time()
        store = self.hub.store
        with store.lock, store.connect() as db:
            db.execute('DELETE FROM links WHERE expires<=?', (now,))
        # Links nobody listed or used since their song got a new mix: they would keep the old files. Each hour in
        # another order (a song at a time), so that a slow Jellyfin doesn't leave the same links unchecked every time.
        with store.connect() as db:
            rows = db.execute('SELECT * FROM links ORDER BY owner, song').fetchall()
        songs = {}
        for row in rows:
            songs.setdefault((row['owner'], row['song']), []).append(row)
        groups = list(songs.values())
        random.shuffle(groups)
        self._sweep([row for group in groups for row in group], time.monotonic() + SWEEP_SECONDS)
        removed = 0
        for path in self.folder.iterdir():
            if path.is_symlink() or not path.is_file():
                continue
            # Looked at and removed under the lock that a ticket or a link for the file is handed out under.
            with store.lock, store.connect() as db:
                try:
                    age = now - path.stat().st_mtime
                except FileNotFoundError:
                    continue
                if path.name.startswith('.'):
                    old = age > 3600
                else:
                    old = age > KEEP_DAYS * 86400 and not any(
                        f'{row[0]}-{row[1]}-{row[3]}.{row[2]}' == path.name for row in db.execute(
                            'SELECT revision,guide,format,tags FROM links WHERE revision=?', (path.name[:64],)))
                if old:
                    path.unlink(missing_ok=True)
                    removed += 1
        return removed

    def linked(self):
        """The revisions of the mixes that links still offer."""
        with self.hub.store.connect() as db:
            return {row[0] for row in db.execute('SELECT revision FROM links WHERE expires>?', (time.time(),))}

    def remove_for(self, version):
        """A mix's converted files go with it, and so do the links offering them: the same song prepared again later
        can get the same revision, which mustn't bring a link back (one made while the cleanup was deciding, say)."""
        store = self.hub.store
        # Under the lock a link is made under, which checks the file is there.
        with store.lock, store.connect() as db:
            db.execute('DELETE FROM links WHERE revision=?', (version,))
            for path in self.folder.glob(f'{version}-*.*'):
                path.unlink(missing_ok=True)

    def size_of(self, version):
        return sum(path.stat().st_size for path in self.folder.glob(f'{version}-*.*')
            if path.is_file() and not path.is_symlink())
