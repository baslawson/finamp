"""Full-program EBU R128 measurements, independent of optional AI analysis.

Albums are measured as one continuous program so the relative gate is applied
to the whole album. Averaging track LUFS would give the wrong result.
"""
import hashlib
from contextlib import nullcontext
import json
import logging
import math
import os
import re
import sqlite3
import subprocess
import tempfile
import threading
import time

import requests
from server_http import HttpPool
from server_runtime import WorkDeferred, lower_worker_priority

log = logging.getLogger("loudness")
VERSION = 1
# A file that failed is measured again after this long, in case its share was only briefly unavailable.
RETRY_FAILED_SECONDS = 3 * 86400


def parse_summary(stderr):
    integrated = re.findall(r"I:\s*([-+\w.]+) LUFS", stderr)
    peaks = re.findall(r"Peak:\s*([-+\w.]+) dBFS", stderr)
    if not integrated or not peaks:
        raise ValueError("FFmpeg did not return a complete loudness measurement")
    values = float(integrated[-1]), float(peaks[-1])
    # Silence has no useful gain; never turn -inf into a huge boost.
    return values if all(math.isfinite(v) for v in values) and values[0] > -70 else (None, None)


def measure(paths):
    """Stream full decoded programs through a single true-peak R128 meter.

Stereo is the common playback layout; FFmpeg's standard downmix/upmix is used
consistently for both tracks and albums. No excerpts, gain, or compression.
Disk-backed stderr keeps memory bounded even for long albums.
"""
    with tempfile.TemporaryFile() as errors:
        meter = subprocess.Popen([
            "ffmpeg", "-hide_banner", "-nostats", "-threads", "1",
            "-f", "f32le", "-ar", "48000", "-ac", "2", "-i", "pipe:0",
            "-af", "ebur128=peak=true:framelog=verbose", "-f", "null", "-",
        ], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=errors)
        try:
            for path in paths:
                with tempfile.TemporaryFile() as decode_errors:
                    decoder = subprocess.run([
                        "ffmpeg", "-v", "error", "-nostdin", "-threads", "1", "-i", path,
                        "-map", "0:a:0", "-vn", "-ac", "2", "-ar", "48000",
                        "-f", "f32le", "pipe:1",
                    ], stdout=meter.stdin, stderr=decode_errors, timeout=7200)
                    if decoder.returncode:
                        raise ValueError("Audio decoding failed")
            meter.stdin.close()
            if meter.wait(timeout=300):
                raise ValueError("Loudness measurement failed")
            errors.seek(0)
            return parse_summary(errors.read().decode("utf-8", errors="replace"))
        finally:
            if meter.poll() is None:
                meter.kill()
                meter.wait()


class LoudnessIndex:
    def __init__(self, data_dir, jellyfin_url, api_key, music_dir, map_path, runtime=None):
        self.path = os.path.join(data_dir, "loudness.db")
        self.url, self.key, self.music_dir, self.map_path = jellyfin_url, api_key, music_dir, map_path
        self.runtime, self.http = runtime, HttpPool()
        self.lock = threading.Lock()
        self.scanning = False
        self.total = self.missing = 0
        self.connection = sqlite3.connect(self.path, check_same_thread=False)
        self.connection.executescript("""
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS tracks (
                id TEXT PRIMARY KEY, signature TEXT, album_id TEXT, path TEXT,
                lufs REAL, true_peak REAL, error TEXT, version INTEGER);
            CREATE TABLE IF NOT EXISTS albums (
                id TEXT PRIMARY KEY, signature TEXT, lufs REAL, true_peak REAL,
                error TEXT, version INTEGER);
        """)
        # Added later; failures from before it are measured once more.
        for table in ("tracks", "albums"):
            columns = {row[1] for row in self.connection.execute(f"PRAGMA table_info({table})")}
            if "failed_at" not in columns:
                self.connection.execute(f"ALTER TABLE {table} ADD COLUMN failed_at REAL")
        self.connection.commit()

    def library(self):
        if not self.url:
            from pathlib import Path
            return [{"Id": hashlib.sha1(str(p).encode()).hexdigest(), "Path": str(p)}
                    for p in Path(self.music_dir).rglob("*")
                    if p.suffix.lower() in {".mp3", ".flac", ".m4a", ".aac", ".ogg", ".opus", ".wav", ".alac", ".aiff", ".ape", ".wma"}]
        items, start = [], 0
        while True:
            response = self.http.request('GET', self.url + "/Items", headers={"Authorization": f'MediaBrowser Token="{self.key}"'}, params={
                "Recursive": "true", "IncludeItemTypes": "Audio", "Fields": "Path",
                "StartIndex": start, "Limit": 1000,
            }, timeout=60)
            with response:
                response.raise_for_status()
                batch = response.json()["Items"]
            items.extend(batch)
            if len(batch) < 1000:
                return items
            start += len(batch)

    def scan(self):
        self.scanning = True
        try:
            items = self.library()
            self.total, self.missing = len(items), 0
            albums, present, prepared, expected = {}, set(), [], {}
            for item in items:
                track_id = item["Id"].replace("-", "")
                present.add(track_id)
                album_id = (item.get("AlbumId") or "").replace("-", "")
                if album_id:
                    expected[album_id] = expected.get(album_id, 0) + 1
                path = self.map_path(item.get("Path", ""))
                try:
                    stat = os.stat(path)
                except OSError:
                    self.missing += 1
                    # Inaccessible or removed media must not retain stale gains.
                    with self.lock:
                        self.connection.execute("DELETE FROM tracks WHERE id=?", (track_id,))
                        self.connection.commit()
                    continue
                signature = hashlib.sha256(f"{VERSION}:{path}:{stat.st_size}:{stat.st_mtime_ns}".encode()).hexdigest()
                if album_id:
                    albums.setdefault(album_id, []).append((item.get("ParentIndexNumber", 0) or 0,
                        item.get("IndexNumber", 0) or 0, track_id, path, signature))
                prepared.append((track_id, path, signature, album_id))

            # Invalidate changed album programs before any slow audio decoding.
            # Otherwise an edited track could inherit an old album's boost for
            # the several hours that a large library's first pass can take.
            signatures = {}
            track_signatures = {track_id: signature for track_id, _, signature, _ in prepared}
            for album_id, members in albums.items():
                members.sort()
                if len(members) == expected[album_id]:
                    signatures[album_id] = hashlib.sha256(json.dumps(members).encode()).hexdigest()
            with self.lock:
                for album_id, signature in self.connection.execute("SELECT id,signature FROM albums").fetchall():
                    if signatures.get(album_id) != signature:
                        self.connection.execute("DELETE FROM albums WHERE id=?", (album_id,))
                for track_id, signature in self.connection.execute("SELECT id,signature FROM tracks").fetchall():
                    if track_signatures.get(track_id) != signature:
                        self.connection.execute("DELETE FROM tracks WHERE id=?", (track_id,))
                self.connection.commit()

            ordered = self.runtime.prioritize(prepared, lambda item: item[0]) if self.runtime else prepared
            for track_id, path, signature, album_id in ordered:
                with self.lock:
                    old = self.connection.execute("SELECT signature,error,album_id,failed_at FROM tracks WHERE id=?", (track_id,)).fetchone()
                if old and old[0] == signature and not self.retry_due(old[1], old[3]):
                    if old[2] != album_id:
                        with self.lock:
                            self.connection.execute("UPDATE tracks SET album_id=? WHERE id=?", (album_id, track_id))
                            self.connection.commit()
                    continue
                try:
                    with self.runtime.slot('loudness') if self.runtime else nullcontext():
                        lufs, peak = measure([path])
                    error = None
                except WorkDeferred:
                    return
                except Exception as exc:
                    log.warning("Track measurement failed: %s", path)
                    lufs = peak = None
                    error = type(exc).__name__
                with self.lock:
                    self.connection.execute("INSERT OR REPLACE INTO tracks (id,signature,album_id,path,lufs,true_peak,error,version,failed_at)"
                        " VALUES(?,?,?,?,?,?,?,?,?)",
                        (track_id, signature, album_id, path, lufs, peak, error, VERSION, time.time() if error else None))
                    self.connection.commit()
            # Do not publish partial albums when a member is missing.
            ordered_albums = self.runtime.prioritize(albums.items(), lambda item: [member[2] for member in item[1]]) if self.runtime else albums.items()
            for album_id, members in ordered_albums:
                if len(members) != expected[album_id]:
                    with self.lock:
                        self.connection.execute("DELETE FROM albums WHERE id=?", (album_id,))
                        self.connection.commit()
                    continue
                members.sort()
                signature = hashlib.sha256(json.dumps(members).encode()).hexdigest()
                with self.lock:
                    old = self.connection.execute("SELECT signature,error,failed_at FROM albums WHERE id=?", (album_id,)).fetchone()
                if old and old[0] == signature and not self.retry_due(old[1], old[2]):
                    continue
                try:
                    with self.runtime.slot('loudness') if self.runtime else nullcontext():
                        lufs, peak = measure([m[3] for m in members])
                    error = None
                except WorkDeferred:
                    return
                except Exception as exc:
                    log.warning("Album measurement failed: %s", album_id)
                    lufs = peak = None
                    error = type(exc).__name__
                with self.lock:
                    self.connection.execute("INSERT OR REPLACE INTO albums (id,signature,lufs,true_peak,error,version,failed_at)"
                        " VALUES(?,?,?,?,?,?,?)",
                        (album_id, signature, lufs, peak, error, VERSION, time.time() if error else None))
                    self.connection.commit()
            with self.lock:
                for (tid,) in self.connection.execute("SELECT id FROM tracks").fetchall():
                    if tid not in present:
                        self.connection.execute("DELETE FROM tracks WHERE id=?", (tid,))
                for (aid,) in self.connection.execute("SELECT id FROM albums").fetchall():
                    if aid not in albums:
                        self.connection.execute("DELETE FROM albums WHERE id=?", (aid,))
                self.connection.commit()
        finally:
            self.scanning = False

    def lookup(self, ids):
        result = {}
        with self.lock:
            for track_id in ids[:2000]:
                track_id = track_id.replace("-", "")
                row = self.connection.execute("""SELECT t.lufs,t.true_peak,a.lufs,a.true_peak,t.signature,a.signature
                    FROM tracks t LEFT JOIN albums a ON t.album_id=a.id AND a.error IS NULL
                    WHERE t.id=? AND t.error IS NULL AND t.lufs IS NOT NULL""", (track_id,)).fetchone()
                if row:
                    result[track_id] = dict(zip(("lufs", "truePeak", "albumLufs", "albumTruePeak", "revision", "albumRevision"), row)) | {"version": VERSION}
        return result

    @staticmethod
    def retry_due(error, failed_at):
        return bool(error) and (failed_at is None or time.time() - failed_at > RETRY_FAILED_SECONDS)

    def settled(self, ids):
        """Of [ids], the songs already measured as silent or undecodable, which asking again won't change."""
        values = [value.replace("-", "") for value in ids[:2000]]
        if not values:
            return set()
        with self.lock:
            return {row[0] for row in self.connection.execute(
                f"SELECT id FROM tracks WHERE id IN ({','.join('?' * len(values))})"
                " AND (error IS NOT NULL OR lufs IS NULL)", values)}

    def status(self):
        with self.lock:
            measured, failed = self.connection.execute("SELECT count(lufs),count(error) FROM tracks").fetchone()
            albums = self.connection.execute("SELECT count(lufs) FROM albums").fetchone()[0]
        return {"measured": measured, "failed": failed, "albums": albums,
                "total": self.total, "missing": self.missing, "scanning": self.scanning}

    def run(self, interval):
        lower_worker_priority()
        if self.runtime:
            self.runtime.run_scans('loudness', self.scan, interval, log)
            return
        while True:
            try:
                self.scan()
            except Exception:
                log.exception("Loudness scan failed")
            time.sleep(interval)
