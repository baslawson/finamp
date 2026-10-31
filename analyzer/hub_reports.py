"""Logs and bug reports the Finamp+ app uploads, so they can be read on the server instead of copied off the phone.

Each upload is one zip the app makes (its logs, and for a bug report a screenshot and a note). Each user keeps their
newest few log uploads; bug reports are removed after a week. Nothing here is served back: they're read on the server.
"""
import io
import itertools
import os
import re
import secrets
import threading
import time
import zipfile

from fastapi import HTTPException

KINDS = ('logs', 'bug')
# The newest this many log uploads are kept for each user.
MOST_LOGS = 5
# Bug reports are kept this long, and at most this many for each user.
BUG_DAYS = 7
MOST_BUGS = 20
LARGEST = 16 * 1024 * 1024
# Unpacked, a zip may be at most this large: a small zip can't fill the disk.
LARGEST_UNPACKED = 64 * 1024 * 1024
# The time, then a count, so names sort in the order they arrived, even several in one second.
_NAME = re.compile(r'(logs|bug)-(\d{14})-(\d{8})-([0-9a-f]{8})\.zip')


def checked_zip(body):
    """The upload when it's a sound zip of a sensible size; otherwise a 400 saying so."""
    if len(body) > LARGEST:
        raise HTTPException(413, 'The upload is too large')
    try:
        with zipfile.ZipFile(io.BytesIO(body)) as archive:
            entries = archive.infolist()
            if not entries or len(entries) > 20 or sum(entry.file_size for entry in entries) > LARGEST_UNPACKED:
                raise HTTPException(400, 'Upload a Finamp+ log zip')
            if archive.testzip() is not None:
                raise HTTPException(400, 'The upload is damaged')
    except zipfile.BadZipFile:
        raise HTTPException(400, 'Upload a Finamp+ log zip') from None
    return body


class Reports:
    def __init__(self, root):
        self.root = root / 'reports'
        self.lock = threading.Lock()
        self.pruned = float('-inf')
        self.sequence = itertools.count()

    def folder(self, user_id):
        # Jellyfin user ids are hex; anything else can't name a folder.
        if not re.fullmatch('[0-9a-fA-F-]{32,36}', user_id or ''):
            raise HTTPException(400, 'Unknown user')
        return self.root / user_id

    def save(self, user_id, kind, body, now=None):
        if kind not in KINDS:
            raise HTTPException(400, 'Choose logs or a bug report')
        checked_zip(body)
        now = now or time.time()
        folder = self.folder(user_id)
        stamp = time.strftime('%Y%m%d%H%M%S', time.gmtime(now))
        with self.lock:
            name = f'{kind}-{stamp}-{next(self.sequence) % 10 ** 8:08d}-{secrets.token_hex(4)}.zip'
            folder.mkdir(parents=True, exist_ok=True, mode=0o700)
            temporary = folder / f'.{name}.upload'
            with open(temporary, 'wb') as output:
                os.chmod(temporary, 0o600)
                output.write(body)
            temporary.replace(folder / name)
            self._prune_folder(folder, now)
        return name

    def listing(self, user_id):
        folder = self.folder(user_id)
        if not folder.is_dir():
            return []
        reports = []
        # An upload or the cleanup may remove one while this looks: it's left out.
        with self.lock:
            for path in sorted(folder.iterdir(), reverse=True):
                match = _NAME.fullmatch(path.name)
                try:
                    size = path.stat().st_size if match else None
                except FileNotFoundError:
                    continue
                if match:
                    reports.append({'name': path.name, 'kind': match[1], 'size': size})
        return reports

    def prune(self, now=None):
        """Removes old uploads for every user. Run often; does the work at most every 10 minutes."""
        now = now or time.time()
        if now - self.pruned < 600 or not self.root.is_dir():
            return
        self.pruned = now
        with self.lock:
            for folder in self.root.iterdir():
                if folder.is_dir() and not folder.is_symlink():
                    self._prune_folder(folder, now)

    @staticmethod
    def _prune_folder(folder, now):
        logs, bugs = [], []
        for path in folder.iterdir():
            match = _NAME.fullmatch(path.name)
            if path.name.endswith('.upload') and now - path.stat().st_mtime > 3600:
                # Left over from an upload that stopped half-way.
                path.unlink(missing_ok=True)
            elif match:
                (logs if match[1] == 'logs' else bugs).append(path)
        # Names start with the time, so sorting them sorts by age: newest first.
        logs.sort(reverse=True)
        bugs.sort(reverse=True)
        oldest = time.strftime('%Y%m%d%H%M%S', time.gmtime(now - BUG_DAYS * 86400))
        for path in logs[MOST_LOGS:]:
            path.unlink(missing_ok=True)
        for index, path in enumerate(bugs):
            if index >= MOST_BUGS or _NAME.fullmatch(path.name)[2] < oldest:
                path.unlink(missing_ok=True)
