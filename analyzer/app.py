"""Finamp+ analyzer: audio analysis for a Jellyfin music library.

Runs next to Jellyfin, reads the music files directly and provides:
  * vibe search: describe a sound in words, get matching tracks (CLAP text-audio embeddings)
  * tempo, key and energy per track, for DJ-style transitions and harmonic queue ordering
  * song recognition: identify a short recording against the library (Chromaprint)
"""

import gc
import hashlib
import hmac
import json
import logging
import os
import re
import sqlite3
import subprocess
import tempfile
import threading
import time
from contextlib import asynccontextmanager, contextmanager
from pathlib import Path

import numpy as np
import requests
from fastapi import Depends, FastAPI, Header, HTTPException, Request
from pydantic import BaseModel
from starlette.concurrency import run_in_threadpool
from loudness import LoudnessIndex
import structure
from hub import Hub, create_app as create_hub_app
from hub_core import Jellyfin
from server_auth import token_problem
from server_runtime import RuntimeGovernor, WorkDeferred, lower_worker_priority

log = logging.getLogger("analyzer")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")


class HideTickets(logging.Filter):
    """Radio, TV audio and backup links carry an access ticket; the request log keeps the route, not the ticket."""

    PATTERN = re.compile(r"(/api/(?:radio/stream|media|download)/)[^\s?\"]+|((?:ticket|url)=)[^\s&\"]+")

    def filter(self, record):
        if isinstance(record.args, tuple):
            record.args = tuple(
                self.PATTERN.sub(lambda match: (match.group(1) or match.group(2)) + "…", value)
                if isinstance(value, str) else value
                for value in record.args
            )
        return True


logging.getLogger("uvicorn.access").addFilter(HideTickets())

JELLYFIN_URL = os.environ.get("JELLYFIN_URL", "").rstrip("/")
JELLYFIN_API_KEY = os.environ.get("JELLYFIN_API_KEY", "")
ANALYZER_TOKEN = os.environ.get("ANALYZER_TOKEN", "")
MUSIC_DIR = os.environ.get("MUSIC_DIR", "/music")
DATA_DIR = os.environ.get("DATA_DIR", "/data")
# Comma separated "jellyfin/path=container/path" prefixes, for when Jellyfin sees the files under another path.
PATH_MAP = [
    tuple(pair.split("=", 1)) for pair in os.environ.get("PATH_MAP", "").split(",") if "=" in pair
]
RESCAN_HOURS = float(os.environ.get("RESCAN_HOURS", "6"))
CLAP_MODEL = os.environ.get("CLAP_MODEL", "laion/clap-htsat-unfused")
ADVANCED_ANALYSIS = os.environ.get("ADVANCED_ANALYSIS", "true").lower() == "true"
LOUDNESS = None
RUNTIME = RuntimeGovernor(DATA_DIR, playback=lambda: HUB.playback_count())
AUDIO_EXTENSIONS = {".mp3", ".flac", ".m4a", ".aac", ".ogg", ".opus", ".wav", ".wma", ".alac", ".aiff", ".ape"}

SAMPLE_RATE = 48000
EXCERPT_SECONDS = 30
CLAP_WINDOW_SECONDS = 10
# A recording matches when its bit error rate at the best offset is low (unrelated audio sits around 0.5) and
# clearly lower than at the track's other offsets, since a real match lines up at exactly one spot.
MATCH_THRESHOLD = 0.3
MATCH_MIN_DIP = 0.12

# Krumhansl-Schmuckler key profiles.
MAJOR_PROFILE = np.array([6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88])
MINOR_PROFILE = np.array([6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17])
NOTES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
# Camelot wheel positions by pitch class.
CAMELOT_MAJOR = [8, 3, 10, 5, 12, 7, 2, 9, 4, 11, 6, 1]
CAMELOT_MINOR = [5, 12, 7, 2, 9, 4, 11, 6, 1, 8, 3, 10]


# --- storage -----------------------------------------------------------------------------------------------------

_db_lock = threading.Lock()


def db() -> sqlite3.Connection:
    connection = sqlite3.connect(os.path.join(DATA_DIR, "analysis.db"), check_same_thread=False)
    # The radio and backups read alongside the scan; with WAL neither waits for the other.
    connection.execute("PRAGMA journal_mode=WAL")
    connection.execute(
        """CREATE TABLE IF NOT EXISTS tracks (
            id TEXT PRIMARY KEY, path TEXT NOT NULL, mtime REAL NOT NULL,
            bpm REAL, key TEXT, camelot TEXT, energy REAL,
            embedding BLOB, fingerprint BLOB, error TEXT)"""
    )
    # Added later: tracks analyzed before have none of these, and are analyzed again.
    existing = {row[1] for row in connection.execute("PRAGMA table_info(tracks)")}
    for column, kind in STRUCTURE_COLUMNS.items():
        if column not in existing:
            connection.execute(f"ALTER TABLE tracks ADD COLUMN {column} {kind}")
    connection.commit()
    return connection


# Bumped when the analysis gains something new, so the library is analyzed again.
ANALYSIS_VERSION = 2
STRUCTURE_COLUMNS = {
    "version": "INTEGER", "duration": "REAL", "decoded": "REAL", "start": "REAL", "end_time": "REAL",
    "intro": "REAL", "outro": "REAL", "hidden": "REAL", "level": "REAL", "first_beat": "REAL", "last_beat": "REAL",
    "onset": "REAL", "brightness": "REAL", "beat_bpm": "REAL", "failed_at": "REAL",
}
# Columns filled from analyze()'s result under the same name, and under another.
RESULT_COLUMNS = [
    "bpm", "key", "camelot", "energy", "embedding", "fingerprint", "duration", "decoded", "start", "intro", "outro",
    "hidden", "level", "onset", "brightness",
]
RENAMED_COLUMNS = {"end_time": "end", "first_beat": "firstBeat", "last_beat": "lastBeat", "beat_bpm": "beatBpm"}


DB = None


# --- models ------------------------------------------------------------------------------------------------------

_clap = None
_clap_used = 0.0
_clap_users = 0
_clap_lock = threading.Lock()
# The model takes several hundred MB, so it's let go after this long without inference. 0 keeps it loaded.
CLAP_IDLE_SECONDS = float(os.environ.get("CLAP_IDLE_MINUTES", "30")) * 60


@contextmanager
def clap():
    """Loads CLAP on first use and keeps it loaded during inference."""
    global _clap, _clap_used, _clap_users
    with _clap_lock:
        if _clap is None:
            import torch
            from transformers import ClapModel, ClapProcessor

            # Leave cores free for playback and the other workers.
            torch.set_num_threads(1)
            log.info("Loading CLAP model %s", CLAP_MODEL)
            _clap = (ClapModel.from_pretrained(CLAP_MODEL).eval(), ClapProcessor.from_pretrained(CLAP_MODEL))
        _clap_users += 1
        model = _clap
    try:
        yield model
    finally:
        with _clap_lock:
            _clap_users -= 1
            _clap_used = time.monotonic()


def release_idle_clap():
    """Lets the model go when nothing has used it for a while; the next search loads it again."""
    global _clap
    with _clap_lock:
        if _clap is None or _clap_users or not CLAP_IDLE_SECONDS or time.monotonic() - _clap_used < CLAP_IDLE_SECONDS:
            return
        _clap = None
    gc.collect()
    log.info("Unloaded the CLAP model after %d idle minutes", CLAP_IDLE_SECONDS // 60)


def audio_embedding(samples: np.ndarray) -> np.ndarray:
    import torch

    with clap() as (model, processor):
        window = CLAP_WINDOW_SECONDS * SAMPLE_RATE
        windows = [samples[i : i + window] for i in range(0, max(len(samples) - window, 0) + 1, window)][:3]
        inputs = processor(audios=windows, sampling_rate=SAMPLE_RATE, return_tensors="pt")
        with torch.no_grad():
            features = model.get_audio_features(**inputs).numpy()
    mean = features.mean(axis=0)
    return (mean / np.linalg.norm(mean)).astype(np.float32)


def text_embedding(text: str) -> np.ndarray:
    import torch

    with clap() as (model, processor):
        inputs = processor(text=[text], return_tensors="pt", padding=True)
        with torch.no_grad():
            features = model.get_text_features(**inputs).numpy()[0]
    return (features / np.linalg.norm(features)).astype(np.float32)


# --- analysis ----------------------------------------------------------------------------------------------------


def decode(path: str, offset: float = 0, duration: float | None = None, sample_rate: int = SAMPLE_RATE) -> np.ndarray:
    command = ["ffmpeg", "-v", "error", "-ss", str(offset)]
    if duration:
        command += ["-t", str(duration)]
    command += ["-i", path, "-ac", "1", "-ar", str(sample_rate), "-f", "f32le", "-"]
    output = subprocess.run(command, capture_output=True, check=True, timeout=300).stdout
    return np.frombuffer(output, dtype=np.float32)


def duration_of(path: str) -> float:
    output = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "json", path],
        capture_output=True, check=True, timeout=60,
    ).stdout
    return float(json.loads(output)["format"].get("duration") or 0)


def fingerprint(path: str, length: int = 900) -> np.ndarray:
    output = subprocess.run(
        ["fpcalc", "-raw", "-json", "-length", str(length), path], capture_output=True, check=True, timeout=300
    ).stdout
    return np.array(json.loads(output)["fingerprint"], dtype=np.int64).astype(np.uint32)


def estimate_key(samples: np.ndarray, sample_rate: int) -> tuple[str, str]:
    import librosa
    chroma = librosa.feature.chroma_cqt(y=samples, sr=sample_rate).mean(axis=1)
    best = (-2.0, 0, True)
    for tonic in range(12):
        for major, profile in ((True, MAJOR_PROFILE), (False, MINOR_PROFILE)):
            score = np.corrcoef(chroma, np.roll(profile, tonic))[0, 1]
            if score > best[0]:
                best = (score, tonic, major)
    _, tonic, major = best
    if major:
        return f"{NOTES[tonic]} major", f"{CAMELOT_MAJOR[tonic]}B"
    return f"{NOTES[tonic]} minor", f"{CAMELOT_MINOR[tonic]}A"


def analyze(path: str) -> dict:
    import librosa
    total = duration_of(path)
    offset = max(0.0, min(total * 0.3, total - EXCERPT_SECONDS))
    samples = decode(path, offset, EXCERPT_SECONDS)
    if len(samples) < SAMPLE_RATE * 3:
        raise ValueError("track too short to analyze")

    low_rate = 22050
    low = librosa.resample(samples, orig_sr=SAMPLE_RATE, target_sr=low_rate)
    tempo, _ = librosa.beat.beat_track(y=low, sr=low_rate)
    key, camelot = estimate_key(low, low_rate)
    rms = librosa.feature.rms(y=low).mean()
    result = {
        "bpm": float(np.atleast_1d(tempo)[0]),
        "key": key,
        "camelot": camelot,
        "energy": float(20 * np.log10(max(rms, 1e-6))),
        "embedding": audio_embedding(samples).tobytes(),
        "fingerprint": fingerprint(path).tobytes(),
        "duration": total,
    }
    # Decode to disk; only small analysis windows and the beat envelope stay in RAM.
    with tempfile.TemporaryFile(dir=DATA_DIR) as whole, tempfile.TemporaryFile() as errors:
        subprocess.run(['ffmpeg', '-v', 'error', '-ss', '0', '-i', path, '-ac', '1',
            '-ar', str(STRUCTURE_RATE), '-f', 'f32le', '-'], stdout=whole, stderr=errors, check=True, timeout=300)
        result |= structure.analyze_file(whole, STRUCTURE_RATE, scratch=DATA_DIR)
    return result


STRUCTURE_RATE = 11025


# --- library indexing --------------------------------------------------------------------------------------------


def map_path(path: str) -> str:
    for source, target in PATH_MAP:
        if path.startswith(source):
            return target + path[len(source) :]
    return path


def library_items(fields: str = "Path,Genres") -> list[dict]:
    """Every track Jellyfin has, with [fields]."""
    items, start = [], 0
    headers = {"Authorization": f'MediaBrowser Token="{JELLYFIN_API_KEY}"'}
    while True:
        response = HUB.jellyfin.http.request(
            'GET', f"{JELLYFIN_URL}/Items",
            params={"Recursive": "true", "IncludeItemTypes": "Audio", "Fields": fields, "StartIndex": start, "Limit": 1000},
            headers=headers,
            timeout=60,
        )
        with response:
            response.raise_for_status()
            batch = response.json()["Items"]
        items.extend(batch)
        if len(batch) < 1000:
            return items
        start += 1000


def library_tracks() -> dict[str, str]:
    """Track id -> file path, from Jellyfin when configured, else every audio file in MUSIC_DIR."""
    if not JELLYFIN_URL:
        return {
            hashlib.sha1(str(file).encode()).hexdigest(): str(file)
            for file in Path(MUSIC_DIR).rglob("*")
            if file.suffix.lower() in AUDIO_EXTENSIONS
        }
    return {
        item["Id"].replace("-", ""): map_path(item["Path"]) for item in library_items("Path") if item.get("Path")
    }
class Index:
    """In-memory copies of the embeddings and fingerprints for fast search."""

    def __init__(self):
        self.lock = threading.Lock()
        self.ids: list[str] = []
        self.embeddings = np.zeros((0, 512), dtype=np.float32)
        self.fingerprints: list[tuple[str, np.ndarray]] = []
        self.intensity: dict[str, float] = {}
        self.total = 0
        self.missing = 0
        self.scanning = False
        self.revision = b''
        self._duplicates_lock = threading.Lock()
        self._duplicates = None

    def reload(self):
        with _db_lock:
            rows = DB.execute(
                "SELECT id, embedding, fingerprint FROM tracks WHERE error IS NULL AND embedding IS NOT NULL ORDER BY id"
            ).fetchall()
            features = DB.execute(
                "SELECT id, onset, brightness, level, bpm FROM tracks WHERE error IS NULL AND onset IS NOT NULL"
            ).fetchall()
        # Intensity is relative to the rest of the library, so it's worked out again as the library grows.
        ranked = structure.intensities(
            [{"onset": row[1], "brightness": row[2], "level": row[3], "bpm": row[4]} for row in features]
        )
        intensity = {row[0]: value for row, value in zip(features, ranked) if value is not None}
        digest = hashlib.sha256()
        for row in rows:
            for value in (row[0].encode(), row[1], row[2] or b''):
                digest.update(len(value).to_bytes(8, 'big'))
                digest.update(value)
        with self.lock:
            self.revision = digest.digest()
            self.intensity = intensity
            self.ids = [row[0] for row in rows]
            self.embeddings = (
                np.stack([np.frombuffer(row[1], dtype=np.float32) for row in rows])
                if rows
                else np.zeros((0, 512), dtype=np.float32)
            )
            self.fingerprints = [(row[0], np.frombuffer(row[2], dtype=np.uint32)) for row in rows if row[2]]

    def duplicates(self):
        with self._duplicates_lock:
            with self.lock:
                version, ids, embeddings = self.revision, self.ids, self.embeddings
                prints = dict(self.fingerprints)
            if self._duplicates is None or self._duplicates[0] != version:
                pairs = []
                for start in range(0, len(ids), 500):
                    scores = embeddings[start : start + 500] @ embeddings.T
                    for offset, row in enumerate(scores):
                        i = start + offset
                        for j in np.nonzero(row > 0.97)[0]:
                            if j > i and ids[i] in prints and ids[j] in prints:
                                if structure.same_recording(prints[ids[i]], prints[ids[j]]):
                                    pairs.append([ids[i], ids[j]])
                self._duplicates = (version, pairs)
            return [list(pair) for pair in self._duplicates[1]]


INDEX = Index()


def scan():
    INDEX.scanning = True
    try:
        tracks = library_tracks()
        INDEX.total = len(tracks)
        with _db_lock:
            known = {
                row[0]: row[1:]
                for row in DB.execute("SELECT id, path, mtime, version, error, failed_at FROM tracks")
            }
            removed = set(known) - set(tracks)
            DB.executemany("DELETE FROM tracks WHERE id = ?", [(track_id,) for track_id in removed])
            DB.commit()
        log.info("Library has %d tracks (%d removed)", len(tracks), len(removed))

        done, missing, reloaded = 0, 0, time.monotonic()
        for track_id, path in RUNTIME.prioritize(tracks.items(), lambda item: item[0]):
            try:
                mtime = os.path.getmtime(path)
            except OSError:
                missing += 1
                if missing <= 3:
                    log.warning("File not found: %s (is PATH_MAP right?)", path)
                continue
            old = known.get(track_id)
            if old and old[:3] == (path, mtime, ANALYSIS_VERSION) and not retry_due(old[3], old[4]):
                continue
            try:
                with RUNTIME.slot('analysis'):
                    result, error = analyze(path), None
            except WorkDeferred:
                return
            except Exception as exception:  # noqa: BLE001 - one bad file must not stop the scan
                log.warning("Failed to analyze %s: %s", path, exception)
                result, error = {}, str(exception)[:500]
            with _db_lock:
                row = {
                    "id": track_id, "path": path, "mtime": mtime, "error": error, "version": ANALYSIS_VERSION,
                    "failed_at": time.time() if error else None,
                    **{column: result.get(column) for column in RESULT_COLUMNS},
                    **{column: result.get(name) for column, name in RENAMED_COLUMNS.items()},
                }
                DB.execute(
                    f"INSERT OR REPLACE INTO tracks ({', '.join(row)}) VALUES ({', '.join('?' * len(row))})",
                    list(row.values()),
                )
                DB.commit()
            done += 1
            if done % 50 == 0:
                log.info("Analyzed %d new tracks", done)
            # New tracks become searchable as the first scan goes, without re-reading the whole table every few songs.
            if time.monotonic() - reloaded > 600:
                INDEX.reload()
                reloaded = time.monotonic()
        INDEX.missing = missing
        INDEX.reload()
        log.info("Scan finished, %d tracks analyzed this time, %d files not found", done, missing)
    finally:
        INDEX.scanning = False


def retry_due(error: str | None, failed_at: float | None) -> bool:
    """Whether a file that failed is tried again: a share that was briefly unavailable isn't a broken file. Failures
    from before failed_at was recorded are tried once more."""
    return bool(error) and (failed_at is None or time.time() - failed_at > RETRY_FAILED_DAYS * 86400)


RETRY_FAILED_DAYS = 3


def scan_loop():
    RUNTIME.run_scans('analysis', scan, RESCAN_HOURS * 3600, log)


def clap_loop():
    while not RUNTIME.stop.wait(300):
        release_idle_clap()


# --- matching ----------------------------------------------------------------------------------------------------


def match_fingerprint(clip: np.ndarray) -> tuple[str | None, float, float]:
    """Returns the best matching track, its bit error rate and how far that dips below the track's median."""
    best_id, best_error, best_dip = None, 1.0, 0.0
    with INDEX.lock:
        fingerprints = list(INDEX.fingerprints)
    for track_id, track in fingerprints:
        if len(track) < len(clip):
            continue
        windows = np.lib.stride_tricks.sliding_window_view(track, len(clip))
        errors = np.bitwise_count(windows ^ clip).sum(axis=1) / (32 * len(clip))
        error = float(errors.min())
        if error < best_error:
            best_id, best_error, best_dip = track_id, error, float(np.median(errors)) - error
    return best_id, best_error, best_dip


# --- API ---------------------------------------------------------------------------------------------------------


@asynccontextmanager
async def lifespan(_: FastAPI):
    global DB, LOUDNESS
    os.makedirs(DATA_DIR, exist_ok=True)
    DB = db()
    INDEX.reload()
    RUNTIME.start()
    LOUDNESS = LoudnessIndex(DATA_DIR, JELLYFIN_URL, JELLYFIN_API_KEY, MUSIC_DIR, map_path, runtime=RUNTIME)
    workers = [threading.Thread(target=LOUDNESS.run, args=(RESCAN_HOURS * 3600,), daemon=True)]
    if ADVANCED_ANALYSIS:
        workers.append(threading.Thread(target=scan_loop, daemon=True))
        workers.append(threading.Thread(target=clap_loop, daemon=True))
    for worker in workers:
        worker.start()
    HUB.start()
    try:
        yield
    finally:
        HUB.stop()
        RUNTIME.close()
        for worker in workers:
            worker.join(timeout=5)
        LOUDNESS.http.close()


app = FastAPI(title="Finamp+ analyzer", lifespan=lifespan)


if token_problem(ANALYZER_TOKEN):
    log.error("%s; every request will be refused until it is set to a long random secret",
              token_problem(ANALYZER_TOKEN))
elif len(ANALYZER_TOKEN) < 24:
    log.warning("ANALYZER_TOKEN is short; use a long random secret, for example the output of openssl rand -hex 24")


def authorize(x_api_key: str = Header(default="")):
    if token_problem(ANALYZER_TOKEN) or not hmac.compare_digest(x_api_key.encode(), ANALYZER_TOKEN.encode()):
        raise HTTPException(status_code=401, detail="Invalid API key")


from karaoke_proxy import router as karaoke_router
app.include_router(karaoke_router(authorize))

HUB = Hub(Path(DATA_DIR), Jellyfin(JELLYFIN_URL, JELLYFIN_API_KEY, PATH_MAP, MUSIC_DIR),
    ANALYZER_TOKEN, os.environ.get('KARAOKE_URL', ''),
    busy=lambda: INDEX.scanning or bool(LOUDNESS and LOUDNESS.scanning), runtime=RUNTIME)
RUNTIME.priority_loader = HUB.analysis_priorities
app.mount('/hub', create_hub_app(HUB))


@app.get("/healthz", include_in_schema=False)
def healthz():
    """For Docker's health check: answers without the token, and says nothing about the library."""
    return {"ok": True}


@app.get("/status", dependencies=[Depends(authorize)])
def status():
    with _db_lock:
        analyzed, failed = DB.execute(
            "SELECT COUNT(*) - COUNT(error), COUNT(error) FROM tracks"
        ).fetchone()
    loudness_status = LOUDNESS.status()
    return {
        "analyzed": analyzed if ADVANCED_ANALYSIS else loudness_status["measured"],
        "failed": failed if ADVANCED_ANALYSIS else loudness_status["failed"],
        "missing": max(INDEX.missing, loudness_status["missing"]),
        "total": max(INDEX.total, loudness_status["total"]),
        "scanning": INDEX.scanning or loudness_status["scanning"],
        "loudness": loudness_status,
        "advancedAnalysis": ADVANCED_ANALYSIS,
    }


@app.get("/vibe", dependencies=[Depends(authorize)])
def vibe(q: str, limit: int = 50):
    if not ADVANCED_ANALYSIS:
        raise HTTPException(status_code=503, detail="AI analysis is not enabled on this analyzer")
    if not q.strip():
        return []
    query = text_embedding(q)
    with INDEX.lock:
        if not INDEX.ids:
            return []
        scores = INDEX.embeddings @ query
        ids = INDEX.ids
    best = np.argsort(-scores)[: max(1, min(limit, 500))]
    return [{"id": ids[i], "score": round(float(scores[i]), 4)} for i in best]


class AnalysisRequest(BaseModel):
    ids: list[str]


@app.post("/loudness", dependencies=[Depends(authorize)])
def loudness(request: AnalysisRequest):
    result = LOUDNESS.lookup(request.ids)
    # Songs already measured as silent or undecodable are left to the next scheduled scan.
    unknown = [value for value in request.ids[:200] if value.replace('-', '') not in result]
    settled = LOUDNESS.settled(unknown)
    RUNTIME.request_analysis([value for value in unknown if value.replace('-', '') not in settled], 'loudness')
    return result


@app.post("/analysis", dependencies=[Depends(authorize)])
def analysis(request: AnalysisRequest):
    ids = [track_id.replace("-", "") for track_id in request.ids[:2000]]
    if not ids:
        return {}
    fields = ["bpm", "key", "camelot", "energy", "duration", "start", "end_time", "intro", "outro", "hidden",
              "first_beat", "last_beat", "beat_bpm"]
    names = ["bpm", "key", "camelot", "energy", "duration", "start", "end", "intro", "outro", "hidden",
             "firstBeat", "lastBeat", "beatBpm"]
    with _db_lock:
        rows = DB.execute(
            f"SELECT id, {', '.join(fields)} FROM tracks WHERE error IS NULL AND id IN ({','.join('?' * len(ids))})",
            ids,
        ).fetchall()
    with INDEX.lock:
        intensity = INDEX.intensity
    result = {
        row[0]: {name: value for name, value in zip(names, row[1:]) if value is not None}
        | ({"intensity": intensity[row[0]]} if row[0] in intensity else {})
        for row in rows
    }
    if ADVANCED_ANALYSIS:
        unknown = [value for value in ids[:200] if value not in result]
        if unknown:
            with _db_lock:
                failed = {row[0] for row in DB.execute(
                    f"SELECT id FROM tracks WHERE error IS NOT NULL AND id IN ({','.join('?' * len(unknown))})",
                    unknown,
                )}
            RUNTIME.request_analysis([value for value in unknown if value not in failed], 'analysis')
    return result


@app.get("/similar", dependencies=[Depends(authorize)])
def similar(id: str, limit: int = 50):
    """Tracks that sound like the track [id], most alike first; the track itself isn't among them."""
    if not ADVANCED_ANALYSIS:
        raise HTTPException(status_code=503, detail="AI analysis is not enabled on this analyzer")
    track_id = id.replace("-", "")
    with INDEX.lock:
        if track_id not in INDEX.ids:
            raise HTTPException(status_code=404, detail="That track hasn't been analyzed yet")
        ids = INDEX.ids
        scores = INDEX.embeddings @ INDEX.embeddings[ids.index(track_id)]
    best = [i for i in np.argsort(-scores) if ids[i] != track_id][: max(1, min(limit, 500))]
    return [{"id": ids[i], "score": round(float(scores[i]), 4)} for i in best]


@app.get("/health", dependencies=[Depends(authorize)])
def health():
    """A check-up of the library: files that can't be played, that end early or are cut off, the same recording on
    several albums, and missing tags. Only duplicate comparisons are cached."""
    return library_health()


def library_health() -> dict:
    broken = {}
    with LOUDNESS.lock:
        for track_id, error in LOUDNESS.connection.execute("SELECT id, error FROM tracks WHERE error IS NOT NULL"):
            broken[track_id] = f"Can't be decoded ({error})"
    with _db_lock:
        for track_id, error in DB.execute("SELECT id, error FROM tracks WHERE error IS NOT NULL"):
            broken.setdefault(track_id, f"Can't be analyzed: {error[:200]}")
        cut = [
            {"id": row[0], "duration": round(row[1], 1), "decoded": round(row[2], 1)}
            for row in DB.execute(
                "SELECT id, duration, decoded FROM tracks WHERE error IS NULL AND duration > 30 AND decoded IS NOT NULL"
                " AND decoded < duration - 5"
            )
        ]
        silent_tails = [
            {"id": row[0], "silence": round(row[1] - row[2], 1), "hidden": row[3] is not None}
            for row in DB.execute(
                "SELECT id, decoded, end_time, hidden FROM tracks WHERE error IS NULL AND end_time IS NOT NULL"
                " AND (decoded - end_time > 20 OR hidden IS NOT NULL)"
            )
        ]
    duplicates = INDEX.duplicates() if ADVANCED_ANALYSIS else []
    tags = []
    try:
        for item in library_items() if JELLYFIN_URL else []:
            missing = [
                name
                for name, present in (
                    ("artist", item.get("Artists") or item.get("AlbumArtist")),
                    ("album", item.get("Album")),
                    ("year", item.get("ProductionYear")),
                    ("genre", item.get("Genres")),
                    ("track number", item.get("IndexNumber")),
                )
                if not present
            ]
            if missing:
                tags.append({"id": item["Id"].replace("-", ""), "missing": missing})
    except Exception:  # noqa: BLE001 - the rest of the report is still useful
        log.exception("Couldn't read the library's tags")
    return {
        "broken": [{"id": track_id, "reason": reason} for track_id, reason in broken.items()],
        "cutOff": cut,
        "silentEndings": silent_tails,
        "duplicates": duplicates,
        "missingTags": tags,
        "advancedAnalysis": ADVANCED_ANALYSIS,
    }


@app.post("/identify", dependencies=[Depends(authorize)])
async def identify(request: Request):
    length = request.headers.get("content-length")
    if length and (not length.isdigit() or int(length) > MAX_RECORDING_BYTES):
        raise HTTPException(status_code=413, detail="The recording is too long")
    parts, size = [], 0
    async for part in request.stream():
        size += len(part)
        if size > MAX_RECORDING_BYTES:
            raise HTTPException(status_code=413, detail="The recording is too long")
        parts.append(part)
    body = b"".join(parts)
    if not body:
        raise HTTPException(status_code=400, detail="Send the recording as the request body")
    # Fingerprinting and searching the library take seconds; doing it here would hold up every other request,
    # including the radio stream and TV karaoke.
    return await run_in_threadpool(identify_recording, body)


# A few seconds of compressed audio from the phone is far smaller.
MAX_RECORDING_BYTES = 4 * 1024 * 1024


def identify_recording(body: bytes) -> dict:
    with tempfile.NamedTemporaryFile(suffix=".audio") as recording:
        recording.write(body)
        recording.flush()
        try:
            clip = fingerprint(recording.name, length=30)
        except subprocess.CalledProcessError as exception:
            raise HTTPException(status_code=400, detail="Couldn't read the recording") from exception
    if len(clip) < 20:
        raise HTTPException(status_code=400, detail="Recording too short")
    track_id, error, dip = match_fingerprint(clip)
    log.info("Best match %s: error %.3f, dip %.3f", track_id, error, dip)
    if track_id is None or error > MATCH_THRESHOLD or dip < MATCH_MIN_DIP:
        return {"id": None, "confidence": 0}
    return {"id": track_id, "confidence": round(1 - error / 0.5, 3)}
