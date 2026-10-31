"""Song recognition from a phone's microphone, by spectral landmarks.

A song's strongest spectrogram peaks survive what a room does to it (echo, noise, the phone's small speaker and
microphone, their gain control) far better than a Chromaprint fingerprint's bits do. Pairs of nearby peaks make
hashes, from both frequencies and the time between them; a recording is the song where many of its hashes line up
at one offset. The library's hashes take more room than fits in memory, so they live in their own SQLite file."""

import os
import sqlite3
import subprocess
import threading
import time

import numpy as np

RATE = 8000
WINDOW = 1024
HOP = 256
FRAMES_PER_SECOND = RATE / HOP
# Frequency bins used, about 250 Hz to 3.5 kHz: what a phone's speaker and microphone carry best. (Hashes keep
# a bin in 9 bits.)
LOWEST_BIN, HIGHEST_BIN = 32, 448
# A peak is the loudest point this many bins and frames either side, and well above the recording's typical level.
PEAK_BINS, PEAK_FRAMES = 6, 3
PEAK_ABOVE = 1.0
# The strongest peaks in each second, so loud and quiet passages both have their share; each is paired with this
# many after it, up to two seconds later and within about 750 Hz. A recording takes more of both: the track's
# peaks it hears need only be among them. (Tried against real music through a simulated room.)
PEAKS_PER_SECOND, FAN_OUT = 15, 4
CLIP_PEAKS_PER_SECOND, CLIP_FAN_OUT = 25, 8
MOST_FRAMES_APART = 63
MOST_BINS_APART = 96
# The most of a track indexed, as long as its Chromaprint fingerprint; times are frames, which this keeps below 2^16.
MOST_SECONDS = 15 * 60
# A match is this many hashes lined up at one offset (give or take a frame), and this many times as many as any
# other track has. (Set from 400 real tracks: unrelated recordings reached 17, with another track close behind.)
LEAST_MATCHES = 20
CLEAR_BY = 2.5
# Seconds of the recording its hashes that line up must spread over (most of them), so a few seconds a song shares
# with another - a sample, or the end of the song before - aren't taken for all of it. (Of 90 real recordings across a
# room, none lined up over less; of 10 with three seconds of a song before another, one would have been taken for it.)
LEAST_SPREAD = 3
# Tracks looked at closely, at most: all copies of one recording on compilations, and those in their way.
MOST_CONTENDERS = 50
# Bounds on one recording's work, however repetitive it is: a hash counted at most this many times, none in more
# than this many places in the library, and this many votes in all (24 MB).
MOST_REPEATS = 4
MOST_POSTINGS = 1000
MOST_VOTES = 1_000_000


def decode(path: str, seconds: float = MOST_SECONDS) -> np.ndarray:
    output = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", path, "-t", str(seconds), "-ac", "1", "-ar", str(RATE), "-f", "f32le", "-"],
        capture_output=True, check=True, timeout=300,
    ).stdout
    return np.frombuffer(output, dtype=np.float32)


def spectrogram(samples: np.ndarray) -> np.ndarray:
    """Log magnitudes, one row per frame, up to [HIGHEST_BIN]."""
    samples = np.asarray(samples, dtype=np.float32)
    if len(samples) < WINDOW:
        return np.zeros((0, HIGHEST_BIN + 1), dtype=np.float32)
    frames = np.lib.stride_tricks.sliding_window_view(samples, WINDOW)[::HOP]
    window = np.hanning(WINDOW).astype(np.float32)
    out = np.empty((len(frames), HIGHEST_BIN + 1), dtype=np.float32)
    # A few thousand frames at a time: a whole track's complex spectrum at once is hundreds of MB.
    for start in range(0, len(frames), 2048):
        magnitudes = np.abs(np.fft.rfft(frames[start : start + 2048] * window, axis=1))[:, : HIGHEST_BIN + 1]
        out[start : start + 2048] = np.log(magnitudes + 1e-6)
    return out


def _widest(values: np.ndarray, reach: int, axis: int) -> np.ndarray:
    """Each value's neighbourhood maximum, [reach] either side along [axis]."""
    pad = [(0, 0), (0, 0)]
    pad[axis] = (reach, reach)
    padded = np.pad(values, pad, constant_values=-np.inf)
    return np.lib.stride_tricks.sliding_window_view(padded, 2 * reach + 1, axis=axis).max(axis=-1)


def peaks(spectrum: np.ndarray, per_second: int | None = None) -> tuple[np.ndarray, np.ndarray]:
    """The spectrum's landmark peaks as (frames, bins), in time order."""
    if not len(spectrum):
        return np.zeros(0, dtype=np.int64), np.zeros(0, dtype=np.int64)
    highest = _widest(_widest(spectrum, PEAK_BINS, 1), PEAK_FRAMES, 0)
    # Relative to the recording's own level, so a quiet or loud recording finds the same peaks.
    found = (spectrum == highest) & (spectrum > np.median(spectrum[:, LOWEST_BIN:]) + PEAK_ABOVE)
    found[:, :LOWEST_BIN] = False
    frames, bins = np.nonzero(found)
    second = frames * HOP // RATE
    order = np.lexsort((-spectrum[frames, bins], second))
    frames, bins, second = frames[order], bins[order], second[order]
    keep = np.arange(len(second)) - np.searchsorted(second, second) < (per_second or PEAKS_PER_SECOND)
    frames, bins = frames[keep], bins[keep]
    order = np.lexsort((bins, frames))
    return frames[order], bins[order]


def hashes(frames: np.ndarray, bins: np.ndarray, fan_out: int | None = None) -> tuple[np.ndarray, np.ndarray]:
    """Hashes of pairs of [peaks], each with its first peak's frame."""
    frames, bins, fan_out = frames.tolist(), bins.tolist(), fan_out or FAN_OUT
    found, times = [], []
    for i, (frame, low) in enumerate(zip(frames, bins)):
        paired = 0
        for j in range(i + 1, len(frames)):
            apart = frames[j] - frame
            if apart > MOST_FRAMES_APART:
                break
            if apart < 1 or abs(bins[j] - low) > MOST_BINS_APART:
                continue
            found.append(low << 15 | bins[j] << 6 | apart)
            times.append(frame)
            paired += 1
            if paired == fan_out:
                break
    return np.array(found, dtype=np.uint32), np.array(times, dtype=np.uint32)


def landmarks(samples: np.ndarray, per_second: int | None = None, fan_out: int | None = None):
    return hashes(*peaks(spectrogram(samples), per_second), fan_out)


class LandmarkIndex:
    """Every track's hashes, for finding a recording's track; tracks are added and removed as the library scan goes."""

    def __init__(self, path: str):
        self.path = path
        self.lock = threading.Lock()
        self.connection = self._connect()
        # The scan's writes go faster with more of the index at hand: 256 MB.
        self.connection.execute("PRAGMA cache_size=-262144")
        with self.connection:
            # [n] is never reused (AUTOINCREMENT), so a hash can't be taken for a newer track's.
            self.connection.execute(
                """CREATE TABLE IF NOT EXISTS tracks (
                    n INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE, mtime REAL NOT NULL,
                    marks BLOB, error TEXT, failed_at REAL)"""
            )
            # A track's [n] and frame in one number: [n] << 16 | frame.
            self.connection.execute(
                "CREATE TABLE IF NOT EXISTS landmarks (hash INTEGER NOT NULL, ref INTEGER NOT NULL, "
                "PRIMARY KEY (hash, ref)) WITHOUT ROWID"
            )

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.path, check_same_thread=False, timeout=30)
        # Recognition reads alongside the scan's writes.
        connection.execute("PRAGMA journal_mode=WAL")
        connection.execute("PRAGMA synchronous=NORMAL")
        return connection

    def current(self, track_id: str, mtime: float, retry_days: float) -> bool:
        """Whether [track_id] is indexed as of [mtime]; a file that failed is tried again after [retry_days]."""
        with self.lock:
            row = self.connection.execute(
                "SELECT mtime, error, failed_at FROM tracks WHERE id = ?", (track_id,)
            ).fetchone()
        if row is None or row[0] != mtime:
            return False
        return not row[1] or time.time() - (row[2] or 0) < retry_days * 86400

    def add(self, track_id: str, mtime: float, marks: tuple[np.ndarray, np.ndarray] | None = None,
            error: str | None = None):
        found, times = marks if marks is not None else (np.zeros(0, np.uint32), np.zeros(0, np.uint32))
        with self.lock, self.connection:
            self._drop(track_id)
            n = self.connection.execute(
                "INSERT INTO tracks (id, mtime, marks, error, failed_at) VALUES (?, ?, ?, ?, ?)",
                (track_id, mtime, np.stack([found, times]).astype(np.uint32).tobytes(), error,
                 time.time() if error else None),
            ).lastrowid
            refs = (np.int64(n) << 16) | times.astype(np.int64)
            # In hash order, so each page of the index is visited once: the library's are 100 million or more.
            order = np.argsort(found, kind="stable")
            self.connection.executemany(
                "INSERT OR IGNORE INTO landmarks (hash, ref) VALUES (?, ?)",
                zip(found[order].tolist(), refs[order].tolist()),
            )

    def remove(self, track_ids):
        with self.lock, self.connection:
            for track_id in track_ids:
                self._drop(track_id)

    def _drop(self, track_id: str):
        row = self.connection.execute("SELECT n, marks FROM tracks WHERE id = ?", (track_id,)).fetchone()
        if row is None:
            return
        n, marks = row
        found, times = np.frombuffer(marks or b"", dtype=np.uint32).reshape(2, -1)
        refs = (np.int64(n) << 16) | times.astype(np.int64)
        self.connection.executemany(
            "DELETE FROM landmarks WHERE hash = ? AND ref = ?", zip(found.tolist(), refs.tolist())
        )
        self.connection.execute("DELETE FROM tracks WHERE n = ?", (n,))

    def ids(self) -> set[str]:
        with self.lock:
            return {row[0] for row in self.connection.execute("SELECT id FROM tracks")}

    def mtime(self, track_id: str) -> float | None:
        """The modification time of the file [track_id] was indexed from."""
        with self.lock:
            row = self.connection.execute("SELECT mtime FROM tracks WHERE id = ?", (track_id,)).fetchone()
        return row[0] if row else None

    def indexed(self) -> int:
        with self.lock:
            return self.connection.execute("SELECT count(*) FROM tracks WHERE error IS NULL").fetchone()[0]

    def match(self, samples: np.ndarray, same_recording=None) -> tuple[str | None, int, int]:
        """The track [samples] (a recording at [RATE]) is from, or None when none clearly is; with how many of the
        recording's hashes line up with it, and with the most any other recording has. [same_recording] says whether
        two tracks (by id) are copies of one recording, as on an album and a compilation; either copy will do."""
        found, times = landmarks(samples, CLIP_PEAKS_PER_SECOND, CLIP_FAN_OUT)
        clip: dict[int, list[int]] = {}
        for value, frame in zip(found.tolist(), times.tolist()):
            # A held note repeats one hash all through; a few of its times say as much as all of them.
            if len(clip.setdefault(value, [])) < MOST_REPEATS:
                clip[value].append(frame)
        # Where in the recording each of its hashes is, in the order they're numbered.
        frame_of = np.array([frame for frames in clip.values() for frame in frames], dtype=np.int64)
        # Each vote: a track, the offset its hash is at from the recording's, and which of the recording's it was.
        tracks = np.empty(MOST_VOTES, dtype=np.int64)
        offsets = np.empty(MOST_VOTES, dtype=np.int64)
        entries = np.empty(MOST_VOTES, dtype=np.int64)
        votes, first, cut_short = 0, 0, False
        # Its own connection, as matching goes ahead while the scan holds the index's; and one snapshot of the index
        # throughout, so a track the scan indexes again meanwhile isn't counted as two.
        connection = sqlite3.connect(self.path, timeout=30, isolation_level=None)
        try:
            connection.execute("BEGIN")
            for value, frames in clip.items():
                refs = connection.execute(
                    "SELECT ref FROM landmarks WHERE hash = ? LIMIT ?", (value, MOST_POSTINGS + 1)
                ).fetchall()
                # In too many songs to tell them apart.
                if len(refs) > MOST_POSTINGS:
                    first += len(frames)
                    continue
                refs = np.fromiter((ref for (ref,) in refs), dtype=np.int64, count=len(refs))
                for at, frame in enumerate(frames):
                    if votes + len(refs) > MOST_VOTES:
                        cut_short = True
                        break
                    tracks[votes : votes + len(refs)] = refs >> 16
                    offsets[votes : votes + len(refs)] = (refs & 0xFFFF) - frame
                    entries[votes : votes + len(refs)] = first + at
                    votes += len(refs)
                first += len(frames)
            if not votes:
                return None, 0, 0
            tracks, offsets, entries = tracks[:votes], offsets[:votes], entries[:votes]
            # Every window of three offsets (give or take a frame, as a recording's peaks can fall a frame either side
            # of the track's), scored by how many of the recording's hashes line up in it, each once.
            entry_bits = max(1, int(entries.max()).bit_length())
            centre_bits = 18
            in_window = np.unique(np.concatenate([
                (tracks << (centre_bits + entry_bits)) | ((offsets + step + (1 << 17)) << entry_bits) | entries
                for step in (-1, 0, 1)
            ]))
            window_of = in_window >> entry_bits
            windows, scores = np.unique(window_of, return_counts=True)
            owners = windows >> centre_bits
            # Each track's best window, best first.
            order = np.lexsort((scores, owners))
            best = order[np.flatnonzero(np.r_[owners[order][1:] != owners[order][:-1], True])]
            best = best[np.argsort(-scores[best], kind="stable")]

            def spread(key: int) -> float:
                """Seconds of the recording most of window [key]'s hashes are spread over."""
                at, end = np.searchsorted(window_of, windows[key]), np.searchsorted(window_of, windows[key], "right")
                low, high = np.percentile(frame_of[in_window[at:end] & ((1 << entry_bits) - 1)], [10, 90])
                return float(high - low) / FRAMES_PER_SECOND

            def id_of(n: int) -> str | None:
                row = connection.execute("SELECT id FROM tracks WHERE n = ?", (n,)).fetchone()
                return row[0] if row else None

            winner = id_of(int(owners[best[0]]))
            score, noise = int(scores[best[0]]), 0
            # The best track that isn't another copy of this recording.
            for at, key in enumerate(best[1:], 1):
                if scores[key] < score / CLEAR_BY:
                    break
                if at == MOST_CONTENDERS:
                    noise = int(scores[key])
                    break
                other = id_of(int(owners[key]))
                if same_recording is None or winner is None or other is None or not same_recording(winner, other):
                    noise = int(scores[key])
                    break
            # A count cut short could be missing a track as close as this one, so it's as if there were one.
            if cut_short:
                return None, score, max(noise, score)
            if score < LEAST_MATCHES or score < CLEAR_BY * noise or spread(best[0]) < LEAST_SPREAD:
                return None, score, noise
            return winner, score, noise
        finally:
            connection.close()


def index_path(data_dir: str) -> str:
    return os.path.join(data_dir, "landmarks.db")
