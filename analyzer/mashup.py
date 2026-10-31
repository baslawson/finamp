"""Mashups: one song's vocals over another's instrumental. Which songs go together, and how the vocals are fitted to
the instrumental (tempo, key and where they start). Pure functions, shared by the analyzer and the karaoke worker."""
import math
import re

import numpy as np

NOTES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
# Partners suggested for a song need at most this much change; a pair picked by hand may need up to the MAX values.
SUGGEST_SEMITONES = 2
SUGGEST_TEMPO = 0.08
MAX_SEMITONES = 4
MAX_TEMPO = 0.16
# How far a key may sit from the instrumental's after shifting, as a cost: the same key, its relative major or
# minor (same notes), or a neighbour on the Camelot wheel (one note differs).
KEY_COSTS = {'same': 0.0, 'relative': 0.3, 'neighbour': 1.2}
PLAN_VERSION = 1
SILENCE_DB = -50
# The longest song the karaoke server separates or mixes (karaoke.MAX_SECONDS).
MAX_SECONDS = 1200
# The beat lengths in seconds it accepts (karaoke.MashupGrid.period): 30 to 400 beats a minute.
MIN_PERIOD, MAX_PERIOD = 0.15, 2


def parse_key(text):
    """(tonic pitch class, major) from the analyzer's key, such as "C# minor"; None for anything else."""
    match = re.fullmatch(r'([A-G]#?) (major|minor)', text or '')
    if not match:
        return None
    return NOTES.index(match[1]), match[2] == 'major'


def camelot(tonic, major):
    """The Camelot wheel position, as (number 1-12, major)."""
    return ((7 * tonic + (8 if major else 5)) % 12) or 12, major


def key_relation(vocals, backing):
    """How the vocals' key sits with the instrumental's: 'same', 'relative', 'neighbour' or None."""
    (number, major), (other, other_major) = camelot(*vocals), camelot(*backing)
    if number == other:
        return 'same' if major == other_major else 'relative'
    if major == other_major and (number - other) % 12 in (1, 11):
        return 'neighbour'
    return None


def best_shift(vocals, backing, limit):
    """The pitch shift (semitones, smallest first) that best fits the vocals' key to the instrumental's, with its
    relation and cost; None when no shift within [limit] fits."""
    best = None
    for shift in sorted(range(-limit, limit + 1), key=abs):
        relation = key_relation(((vocals[0] + shift) % 12, vocals[1]), backing)
        if relation is None:
            continue
        cost = KEY_COSTS[relation] + 0.6 * abs(shift)
        if best is None or cost < best[2]:
            best = (shift, relation, cost)
    return best


def tempo_of(track):
    return track.get('beatBpm') or track.get('bpm')


def tempo_ratio(vocals_bpm, backing_bpm):
    """How much faster the vocals must play to follow the instrumental's beat. Beat trackers often hear half or
    double the tempo, so half and double time count as the same beat."""
    return min((backing_bpm * m / vocals_bpm for m in (0.5, 1, 2)), key=lambda r: abs(math.log(r)))


def beat_grid(track):
    """(first beat, seconds per beat), fitted to the song's first and last beat so the grid doesn't drift."""
    bpm, first, last = tempo_of(track), track.get('firstBeat'), track.get('lastBeat')
    if not bpm or first is None:
        return None
    period = 60 / bpm
    if last is not None and last - first > 8 * period:
        period = (last - first) / round((last - first) / period)
    return round(first, 4), round(period, 6)


def plan(vocals, backing, suggest=True):
    """How the vocals of [vocals] go over the instrumental of [backing] (both analysis results), with a score
    (1 is a perfect fit) and, for a pair outside the suggestion limits, warnings. Raises ValueError with the reason a
    pair can't be mashed up."""
    keys = parse_key(vocals.get('key')), parse_key(backing.get('key'))
    grids = beat_grid(vocals), beat_grid(backing)
    if None in keys or None in grids or not vocals.get('duration') or not backing.get('duration'):
        raise ValueError("One of the songs hasn't been fully analysed yet")
    if not all(MIN_PERIOD < grid[1] < MAX_PERIOD for grid in grids):
        raise ValueError("One of the songs' beat is too slow or too fast to fit")
    if max(vocals['duration'], backing['duration']) > MAX_SECONDS:
        raise ValueError(f"Songs longer than {MAX_SECONDS // 60} minutes can't be mashed up")
    # From the fitted grids, so the stretched vocals' beats stay on the instrumental's for the whole song.
    tempo = tempo_ratio(60 / grids[0][1], 60 / grids[1][1])
    change = abs(tempo - 1)
    if change > (SUGGEST_TEMPO if suggest else MAX_TEMPO):
        raise ValueError(f'The tempos are too far apart ({round(100 * change)}% faster or slower)')
    shift = best_shift(keys[0], keys[1], SUGGEST_SEMITONES if suggest else MAX_SEMITONES)
    if shift is None:
        raise ValueError('The keys are too far apart')
    semitones, relation, key_cost = shift
    warnings = []
    if abs(semitones) > SUGGEST_SEMITONES:
        warnings.append(f'The singer is moved {abs(semitones)} semitones, which can sound unnatural')
    if change > SUGGEST_TEMPO:
        warnings.append(f'The vocals play {round(100 * change)}% {"faster" if tempo > 1 else "slower"}')
    length = vocals['duration'] / tempo / backing['duration']
    cost = key_cost + change / 0.04 + max(0, length - 1.15) * 3 + max(0, 0.6 - length) * 2
    if vocals.get('energy') is not None and backing.get('energy') is not None:
        cost += min(abs(vocals['energy'] - backing['energy']) / 6, 1)
    return {
        'version': PLAN_VERSION,
        'tempo': round(tempo, 6),
        'semitones': semitones,
        'key': relation,
        'score': round(1 / (1 + cost), 3),
        'warnings': warnings,
        'vocals': {'firstBeat': grids[0][0], 'period': grids[0][1], 'duration': vocals['duration'],
                   'intro': vocals.get('intro') or 0},
        'backing': {'firstBeat': grids[1][0], 'period': grids[1][1], 'duration': backing['duration'],
                    'intro': backing.get('intro') or 0, 'end': backing.get('end') or backing['duration']},
    }


def partners(song, tracks, role='vocals', limit=20):
    """The songs that mash up best with [song] ({id: analysis}), best first. With role 'vocals' the song sings over
    their instrumentals; with 'backing' they sing over its instrumental."""
    found = []
    mine = tracks.get(song)
    if mine is None:
        return found
    for other, analysis in tracks.items():
        if other == song:
            continue
        pair = (mine, analysis) if role == 'vocals' else (analysis, mine)
        try:
            result = plan(*pair)
        except ValueError:
            continue
        found.append({'id': other, 'score': result['score'], 'semitones': result['semitones'],
                      'tempo': result['tempo'], 'key': result['key']})
    found.sort(key=lambda item: (-item['score'], item['id']))
    return found[:limit]


def ideas(seeds, tracks, limit=20, per_song=2):
    """Pairs worth trying, best first: each has one of [seeds] (such as the songs played lately) singing or backing,
    and no song is in more than [per_song] of them, so one song doesn't fill the list."""
    candidates = {}
    for seed in dict.fromkeys(seeds):
        for role in ('vocals', 'backing'):
            # More than it keeps, so songs that reach their limit elsewhere leave room for the next best.
            for found in partners(seed, tracks, role, per_song * 3):
                vocals, backing = (seed, found['id']) if role == 'vocals' else (found['id'], seed)
                candidates.setdefault((vocals, backing), {
                    'vocals': vocals, 'backing': backing,
                    **{name: found[name] for name in ('score', 'semitones', 'tempo', 'key')}})
    chosen, used = [], {}
    for idea in sorted(candidates.values(), key=lambda idea: (-idea['score'], idea['vocals'], idea['backing'])):
        songs = idea['vocals'], idea['backing']
        if any(used.get(song, 0) >= per_song for song in songs):
            continue
        chosen.append(idea)
        for song in songs:
            used[song] = used.get(song, 0) + 1
        if len(chosen) == limit:
            break
    return chosen


def vocal_entry(levels, frame_seconds, window_seconds=2.0):
    """When the singing starts, from a vocal track's level per frame (dB): the first moment that most of the next
    couple of seconds is clearly sung, rather than the odd breath or bleed. None for a track without singing."""
    levels = np.asarray(levels, dtype=np.float64)
    if not len(levels) or not np.isfinite(levels).any():
        return None
    reference = np.percentile(levels[np.isfinite(levels)], 99)
    # Near the loudest singing, and above what a separation leaves in a part without any.
    active = np.where(np.isfinite(levels), (levels > reference - 18) & (levels > SILENCE_DB), False).astype(np.float64)
    window = max(1, int(round(window_seconds / frame_seconds)))
    if len(active) < window:
        return None
    share = np.convolve(active, np.ones(window) / window, mode='valid')
    starts = np.flatnonzero((share >= 0.5) & (active[:len(share)] > 0))
    return round(float(starts[0] * frame_seconds), 3) if len(starts) else None


def snap(time, first_beat, period):
    """The beat of a grid nearest to [time]."""
    return first_beat + round((time - first_beat) / period) * period


def placement(plan, vocal_entry_seconds, backing_entry_seconds):
    """Where the fitted vocals go: seconds to add to the stretched vocals' timeline to put it on the instrumental's
    (negative cuts their start). The singer's first beat lands on the beat where the instrumental's own singer
    started, so phrases start on the same beat of the bar. Without a known entry, the intro's end stands in."""
    vocals, backing = plan['vocals'], plan['backing']
    sung = vocals['intro'] if vocal_entry_seconds is None else vocal_entry_seconds
    target = backing['intro'] if backing_entry_seconds is None else backing_entry_seconds
    sung = snap(sung, vocals['firstBeat'], vocals['period'])
    target = snap(target, backing['firstBeat'], backing['period'])
    return round(target - sung / plan['tempo'], 4)
