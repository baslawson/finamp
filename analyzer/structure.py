"""Where a song's sound really starts and ends, and how intense it is.

Pure functions over decoded mono samples, so they can be tested with synthetic audio.
"""

import tempfile

import numpy as np

HOP = 512
# Quieter than this below the song's loudest moment counts as silence (and never above -60 dBFS).
SILENCE_BELOW_PEAK = 45
# A silence this long in the second half of a song separates a hidden track from the song.
HIDDEN_GAP_SECONDS = 10
# The song's "body" is where it plays within this much of its typical level; quieter edges are intro and outro.
BODY_BELOW_MEDIAN = 6


def frame_db(samples: np.ndarray, hop: int = HOP) -> np.ndarray:
    """Loudness of each frame of [hop] samples, in dBFS."""
    frames = len(samples) // hop
    if frames == 0:
        return np.zeros(0)
    result = np.empty(frames)
    for first in range(0, frames, 4096):
        last = min(frames, first + 4096)
        blocks = samples[first * hop:last * hop].astype(np.float64).reshape(-1, hop)
        result[first:last] = 20 * np.log10(np.maximum(np.sqrt((blocks**2).mean(axis=1)), 1e-7))
    return result


def cues(samples: np.ndarray, sample_rate: int, hop: int = HOP) -> dict | None:
    """Seconds where the sound starts, where the song ends (before a hidden track's silence, if any), where its intro
    reaches full level and where its outro starts to fade; None for silence."""
    db = frame_db(samples, hop)
    return cues_from_db(db, sample_rate, hop)


def cues_from_db(db, sample_rate, hop=HOP):
    if len(db) == 0:
        return None
    frame = hop / sample_rate
    threshold = max(-60.0, float(db.max()) - SILENCE_BELOW_PEAK)
    sounding = np.nonzero(db > threshold)[0]
    if len(sounding) == 0:
        return None
    first, last = int(sounding[0]), int(sounding[-1])

    hidden = None
    gaps = np.diff(sounding)
    for i in np.nonzero(gaps * frame >= HIDDEN_GAP_SECONDS)[0]:
        if sounding[i] + 1 > len(db) / 2:
            hidden = int(sounding[i + 1])
            last = int(sounding[i])
            break

    window = max(1, int(round(2 / frame)))
    # Padded with the edge levels: padding with zeros would count as 0 dBFS, as loud as it gets.
    padded = np.pad(db, (window // 2, window - 1 - window // 2), mode="edge")
    smooth = np.convolve(padded, np.ones(window) / window, mode="valid")
    body = smooth[first : last + 1]
    level = float(np.median(body))
    loud = np.nonzero(body >= level - BODY_BELOW_MEDIAN)[0]
    intro = first + (int(loud[0]) if len(loud) else 0)
    outro = first + (int(loud[-1]) + 1 if len(loud) else last - first + 1)
    return {
        "start": round(first * frame, 3),
        "end": round((last + 1) * frame, 3),
        "intro": round(intro * frame, 3),
        "outro": round(min(outro, last + 1) * frame, 3),
        "hidden": round(hidden * frame, 3) if hidden is not None else None,
        "level": round(level, 2),
    }


def beats(samples: np.ndarray, sample_rate: int, start: float, end: float) -> dict:
    """The first and last beat of the song's sound, for lining crossfades up on the beat, plus its density of onsets
    and brightness, two parts of how intense it feels."""
    section = samples[int(start * sample_rate) : int(end * sample_rate)]
    return beat_stats(lambda first, last: section[first:last], len(section), sample_rate, start)


def spectral_stats(read, length, sample_rate, block_frames=1024, scratch=None):
    import librosa

    frames = 1 + length // HOP
    onset = None
    brightness, peak = 0.0, -np.inf
    # Log-mel frames live on disk until the program's global dB floor is known.
    with tempfile.TemporaryFile(dir=scratch) as spectra:
        for first in range(0, frames, block_frames):
            last = min(frames, first + block_frames)
            begin, end = first * HOP - 1024, (last - 1) * HOP + 1024
            samples = read(max(0, begin), min(length, end))
            samples = np.pad(samples, (max(0, -begin), max(0, end - length)))
            magnitude = np.abs(librosa.stft(samples, n_fft=2048, hop_length=HOP, center=False))
            mel = librosa.feature.melspectrogram(S=magnitude**2, sr=sample_rate)
            db = librosa.power_to_db(mel, top_db=None)
            if onset is None:
                dtype = db.dtype
                onset = np.zeros(frames, dtype=dtype)
            peak = max(peak, float(db.max()))
            spectra.write(db.T.tobytes())
            brightness += librosa.feature.spectral_centroid(S=magnitude, sr=sample_rate).sum()
        spectra.seek(0)
        previous = None
        for first in range(0, frames, block_frames):
            count = min(block_frames, frames - first)
            db = np.frombuffer(spectra.read(count * 128 * dtype.itemsize), dtype=dtype).reshape(count, 128).T
            db = np.maximum(db, peak - 80)
            joined = np.concatenate([previous, db], axis=1) if previous is not None else db
            flux = np.maximum(0, np.diff(joined, axis=1)).mean(axis=0)
            offset = first if previous is not None else 1
            onset[offset:first + count] = flux
            previous = db[:, -1:]
    # Match onset_strength's centered FFT and one-frame lag.
    return np.pad(onset, (2, 0))[:frames], brightness / frames


def beat_tempo(onset, sample_rate, block_frames=1024):
    import librosa

    window = int(librosa.time_to_frames(8, sr=sample_rate, hop_length=HOP))
    padded = np.pad(onset, (window // 2, window // 2), mode='linear_ramp')
    total = np.zeros(window)
    for first in range(0, len(onset), block_frames):
        count = min(block_frames, len(onset) - first)
        local = librosa.feature.tempogram(onset_envelope=padded[first:first + count + window - 1],
            sr=sample_rate, hop_length=HOP, win_length=window, center=False)
        total += local.sum(axis=-1)
    return librosa.feature.tempo(tg=(total / len(onset))[:, None], sr=sample_rate, hop_length=HOP)


def beat_stats(read, length, sample_rate, start, scratch=None):
    import librosa

    if length < sample_rate * 3:
        return {}
    onset, brightness = spectral_stats(read, length, sample_rate, scratch=scratch)
    tempo, times = librosa.beat.beat_track(onset_envelope=onset, sr=sample_rate, hop_length=HOP,
        bpm=beat_tempo(onset, sample_rate), units="time")
    result = {
        "onset": round(float(onset.mean()), 4),
        "brightness": round(float(brightness), 1),
        "beatBpm": round(float(np.atleast_1d(tempo)[0]), 2),
    }
    if len(times) >= 8:
        result["firstBeat"] = round(start + float(times[0]), 3)
        result["lastBeat"] = round(start + float(times[-1]), 3)
    return result


def analyze_file(source, sample_rate, scratch=None):
    """Read decoded mono float32 audio in bounded windows."""
    length = source.seek(0, 2) // 4
    source.seek(0)
    levels = []
    while data := source.read(4096 * HOP * 4):
        levels.append(frame_db(np.frombuffer(data, dtype=np.float32)))
    result = {'decoded': length / sample_rate}
    found = cues_from_db(np.concatenate(levels) if levels else np.zeros(0), sample_rate)
    if found:
        result.update(found)
        begin, end = int(found['start'] * sample_rate), min(length, int(found['end'] * sample_rate))
        def read(first, last):
            source.seek((begin + first) * 4)
            return np.frombuffer(source.read((last - first) * 4), dtype=np.float32)
        result.update(beat_stats(read, end - begin, sample_rate, found['start'], scratch=scratch))
    return result


def percentiles(values: list[float | None]) -> list[float | None]:
    """Each value's rank among the others, from 0 to 1; None stays None."""
    known = sorted(v for v in values if v is not None)
    if not known:
        return [None] * len(values)
    array = np.array(known)
    denominator = max(1, len(known) - 1)
    return [
        None if v is None else round(float(np.searchsorted(array, v, side="left") / denominator), 4) for v in values
    ]


# How much each part counts towards intensity: busy, bright, loud and fast songs feel intense.
INTENSITY_WEIGHTS = {"onset": 0.4, "brightness": 0.25, "level": 0.2, "bpm": 0.15}


def intensities(rows: list[dict]) -> list[float | None]:
    """Intensity from 0 (calm) to 1 (intense) for each row, relative to the rest of the library."""
    ranks = {name: percentiles([row.get(name) for row in rows]) for name in INTENSITY_WEIGHTS}
    result = []
    for i in range(len(rows)):
        parts = [(ranks[name][i], weight) for name, weight in INTENSITY_WEIGHTS.items() if ranks[name][i] is not None]
        if not parts or ranks["onset"][i] is None:
            result.append(None)
            continue
        total = sum(weight for _, weight in parts)
        result.append(round(sum(rank * weight for rank, weight in parts) / total, 4))
    return result


def same_throughout(a: np.ndarray, b: np.ndarray, max_shift: int = 12) -> bool:
    """Whether two Chromaprint fingerprints are the same recording from start to end, where [same_recording] looks at
    their starts only: nearly the same length, lined up at the start, and still lined up all the way through. Songs
    that only share an intro, a sample or a section aren't."""
    # Within about six seconds: what's left over isn't compared, and might be another ending.
    if min(len(a), len(b)) < 150 or abs(len(a) - len(b)) > 48:
        return False

    def error(x: np.ndarray, y: np.ndarray) -> float:
        n = min(len(x), len(y))
        return float(np.bitwise_count(x[:n] ^ y[:n]).sum() / (32 * n)) if n >= 30 else 1.0

    def from_shift(shift: int) -> tuple[np.ndarray, np.ndarray]:
        return (a[shift:], b) if shift >= 0 else (a, b[-shift:])

    shift = min(range(-max_shift, max_shift + 1), key=lambda shift: error(*(part[:120] for part in from_shift(shift))))
    x, y = from_shift(shift)
    if error(x[:120], y[:120]) >= 0.2:
        return False
    # Every stretch after the start, to the end. (Set from 2019 real duplicates, of which 1883 pass, and 20000
    # unrelated pairs, of which 1 does.)
    shorter = min(len(x), len(y))

    def covers(x: np.ndarray, y: np.ndarray) -> bool:
        """Whether every stretch of [x], to the end of the shorter, is in [y], about where it is in [x]. (Not to [x]'s own
        end: the last frames of a fingerprint differ even between copies, so the few seconds the longer may run on
        aren't compared, and edits that differ only there count as one recording - which either names rightly.)"""
        lined_up = 0
        for at in sorted({*range(120, shorter - 59, 60), shorter - 60}):
            # Give or take a little drift, as between two encodings or transfers: up to 1% of the way in, and little
            # more from one stretch to the next, or passages could be found in another order. Their ends lie as far
            # apart as their lengths do, and no further, or a repeated outro could stand in for another ending.
            reach = max(3, at // 100) if at < shorter - 60 else max(3, abs(len(x) - len(y)))
            drifts = range(max(-reach, lined_up - 3), min(reach, lined_up + 3) + 1)
            if not drifts:
                return False
            best, lined_up = min((error(x[at : at + 60], y[max(0, at + drift) : at + drift + 60]), drift) for drift in drifts)
            if best >= 0.3:
                return False
        return True

    # Both ways: repeated music in one could stand in for a different passage in the other.
    return covers(x, y) and covers(y, x)


def same_recording(a: np.ndarray, b: np.ndarray, max_shift: int = 12, length: int = 120) -> bool:
    """Whether two Chromaprint fingerprints are the same recording: their starts line up with few differing bits."""
    if len(a) < 30 or len(b) < 30:
        return False
    best = 1.0
    for shift in range(-max_shift, max_shift + 1):
        x, y = (a[shift:], b) if shift >= 0 else (a, b[-shift:])
        n = min(len(x), len(y), length)
        if n < 30:
            continue
        error = np.bitwise_count(x[:n] ^ y[:n]).sum() / (32 * n)
        best = min(best, float(error))
    return best < 0.2
