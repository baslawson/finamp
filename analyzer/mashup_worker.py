"""One mashup in a bounded subprocess: separates what the karaoke cache doesn't already hold, fits the singer's vocals
to the other song's tempo and key with Rubber Band, lines them up on its beat and mixes them over its instrumental."""
import json
import math
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

import mashup
from karaoke_worker import encode, loudness, report, split

FRAME_SECONDS = 0.05
# How far the singer may sit above or below the instrumental, from how they sat in their own song.
VOCAL_BALANCE = (-8.0, 2.0)
DEFAULT_BALANCE = -2.0
FADE_SECONDS = 2.0
LIMITER = 'alimiter=limit=0.891251:level=false:latency=true'


def levels(path):
    """The level of [path] in dB per FRAME_SECONDS, read a block at a time."""
    import numpy as np
    import soundfile as sf

    with sf.SoundFile(str(path)) as audio:
        frame = int(audio.samplerate * FRAME_SECONDS)
        result = []
        for block in audio.blocks(blocksize=frame * 1200, dtype='float32', always_2d=True):
            # Each channel's power, not the power of their average: channels out of phase would cancel.
            energy = (block ** 2).mean(axis=1)
            count = len(energy) // frame
            if count:
                power = energy[:count * frame].reshape(count, frame).mean(axis=1)
                result.append(10 * np.log10(np.maximum(power, 1e-12)))
        return np.concatenate(result) if result else np.zeros(0)


def seconds(path):
    import soundfile as sf

    info = sf.info(str(path))
    return info.frames / info.samplerate


def vocal_filters(offset, length, end, gain_db):
    """The ffmpeg filters that put stretched vocals of [length] seconds at [offset] on the instrumental's timeline,
    ending with a fade by the instrumental's [end]."""
    if offset >= 0:
        filters = [f'adelay=delays={round(offset * 1000)}:all=1']
    else:
        filters = [f'atrim=start={-offset:.4f}', 'asetpts=PTS-STARTPTS', 'afade=t=in:d=0.05']
    if offset + length > end - FADE_SECONDS:
        start = max(0.0, end - FADE_SECONDS)
        filters += [f'afade=t=out:st={start:.4f}:d={FADE_SECONDS}', f'atrim=end={end:.4f}']
    return filters + [f'volume={gain_db:.2f}dB']


def balance(vocals, instrumental):
    """How loud the singer was against their own instrumental (LU), within VOCAL_BALANCE."""
    if instrumental is None:
        return DEFAULT_BALANCE
    difference = loudness(vocals)[0] - loudness(instrumental)[0]
    if not math.isfinite(difference):
        return DEFAULT_BALANCE
    return min(max(difference, VOCAL_BALANCE[0]), VOCAL_BALANCE[1])


def make(destination, models):
    """Makes destination/mashup.flac and result.json from destination/job.json."""
    started = time.monotonic()
    destination = Path(destination)
    job = json.loads((destination / 'job.json').read_text())
    plan, model = job['plan'], job['model']
    singer, backing = job['vocals'], job['backing']
    files = {'vocals': singer.get('stem'), 'vocalsBacking': singer.get('instrumental'),
             'backing': backing.get('instrumental'), 'backingVocals': backing.get('vocals')}
    files = {name: destination / value if value else None for name, value in files.items()}
    separations = [(name, song) for name, song in (('singer', singer), ('backing', backing))
                   if not files['vocals' if name == 'singer' else 'backing']]
    for step, (name, song) in enumerate(separations):
        folder = destination / name
        span = (.05 + .65 * step / len(separations), .65 / len(separations))
        label = " from the singer's song" if name == 'singer' else ' from the backing song'
        instrumental, vocals = split(song['source'], folder, models, model, 'vocals', span=span, label=label)
        if name == 'singer':
            files['vocals'], files['vocalsBacking'] = vocals, instrumental
        else:
            files['backing'], files['backingVocals'] = instrumental, vocals

    report(destination, {'progress': .75, 'message': 'Fitting the vocals to the beat and key'})
    singing = mashup.vocal_entry(levels(files['vocals']), FRAME_SECONDS)
    if singing is None:
        raise RuntimeError("The singer's song has no vocals to use")
    backing_singing = mashup.vocal_entry(levels(files['backingVocals']), FRAME_SECONDS) \
        if files['backingVocals'] else None
    stretched = files['vocals']
    if plan['tempo'] != 1 or plan['semitones']:
        stretched = destination / 'stretched.wav'
        # R3, the finer engine, with the singer's formants kept so a shifted voice doesn't sound like another person.
        subprocess.run(['rubberband', '-q', '-3', '-F', '-T', f"{plan['tempo']:.6f}", '-p', str(plan['semitones']),
                        str(files['vocals']), str(stretched)],
                       check=True, capture_output=True, timeout=max(600, 4 * plan['vocals']['duration']))
    offset = mashup.placement(plan, singing, backing_singing)
    end = min(plan['backing']['end'], seconds(files['backing']))
    if offset >= end - FADE_SECONDS:
        raise RuntimeError('The vocals would start after the backing song ends')
    gain = balance(files['vocals'], files['vocalsBacking']) + loudness(files['backing'])[0] - \
        loudness(files['vocals'])[0]
    gain = min(max(gain, -15.0), 15.0) if math.isfinite(gain) else 0.0

    report(destination, {'progress': .9, 'message': 'Mixing the mashup'})
    output = destination / 'mashup.flac'
    vocals = ','.join(vocal_filters(offset, seconds(stretched), end, gain))
    encode(['-i', str(files['backing']), '-i', str(stretched)], output,
           ['-filter_complex', f'[1:a]{vocals}[v];[0:a][v]amix=inputs=2:normalize=0:duration=first,{LIMITER}[a]',
            '-map', '[a]'])
    lufs, peak = loudness(output)
    if not (math.isfinite(lufs) and math.isfinite(peak)):
        raise RuntimeError('The mashup came out silent or invalid')
    for name in ('singer', 'backing'):
        shutil.rmtree(destination / name, ignore_errors=True)
    for file in destination.iterdir():
        if file.is_file() and file.suffix in ('.wav', '.flac') and file != output:
            file.unlink()
    manifest = {'mixes': {'mashup': {'version': 1, 'lufs': lufs, 'truePeak': peak, 'bytes': output.stat().st_size}},
                'seconds': round(time.monotonic() - started, 2), 'model': model, 'part': 'mashup',
                'placement': {'offset': offset, 'vocalEntry': singing, 'backingEntry': backing_singing,
                              'gainDb': round(gain, 2), 'separated': [name for name, _ in separations]}}
    (destination / 'result.json').write_text(json.dumps(manifest))


if __name__ == '__main__':
    os.nice(10)
    make(*sys.argv[1:3])
