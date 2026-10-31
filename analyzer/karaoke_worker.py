"""One bounded separation subprocess. Exits after a song, releasing all model memory."""
import json
import logging
import os
import subprocess
import sys
import time
from pathlib import Path


# The stems each preparation takes out of the song, one model pass each. Everything else the last pass returns is
# the backing track; the last stem taken out is the guide that the mixes bring back.
REMOVED = {'vocals': ['Vocals'], 'drums': ['Drums'], 'both': ['Vocals', 'Drums']}
STEMS = ('Instrumental', 'Vocals', 'Drums', 'No Drums', 'Bass', 'Other', 'Guitar', 'Piano')


def stem_file(stem):
    return 'part-' + stem.lower().replace(' ', '-')


def report(folder, progress):
    """Writes progress.json for the server to show, whole or not at all."""
    temp = Path(folder) / 'progress.tmp'
    temp.write_text(json.dumps(progress))
    temp.replace(Path(folder) / 'progress.json')


_single_threaded = False


def single_threaded():
    """Keeps the models to one thread. ORT otherwise creates a pool for every visible VM core, despite the container
    CPU quota."""
    global _single_threaded
    if _single_threaded:
        return
    import onnxruntime as ort
    import torch

    torch.set_num_threads(1)
    original_session = ort.InferenceSession

    def session(path, sess_options=None, **kwargs):
        options = sess_options or ort.SessionOptions()
        options.intra_op_num_threads = 1
        options.inter_op_num_threads = 1
        return original_session(path, sess_options=options, **kwargs)

    ort.InferenceSession = session
    _single_threaded = True


def split(source, destination, models, model, part='vocals', chunk_seconds=60, overlap_seconds=2, span=(.1, .65),
          label=''):
    """Separates [source] into destination/backing.wav and destination/guide.wav (the last part removed), reporting
    progress from span[0] to span[0] + span[1] in the folder above when [label] (which ends the message) is given,
    else in [destination]. `model` names one model per pass, comma-separated. A song whose vocals are already out
    needs only the last."""
    passes = model.split(',')
    removed_stems = REMOVED[part][-len(passes):]
    if len(passes) != len(removed_stems):
        raise RuntimeError('Too many separation models for this part')
    import numpy as np
    import soundfile as sf
    from audio_separator.separator import Separator

    single_threaded()
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    backing, guide_part = destination / "backing.wav", destination / "guide.wav"
    decoded = destination / 'source.wav'
    subprocess.run(['ffmpeg', '-v', 'error', '-nostdin', '-y', '-i', source, '-ar', '44100', '-ac', '2',
                    '-c:a', 'pcm_f32le', str(decoded)], capture_output=True, check=True, timeout=300)
    rate, chunk, overlap = 44100, int(chunk_seconds * 44100), int(overlap_seconds * 44100)

    def separate(step, model_name, stem):
        """Takes `stem` out of source.wav, leaving backing.wav and guide.wav."""
        removed = stem_file(stem)
        separator = Separator(
            log_level=logging.WARNING, model_file_dir=models, output_dir=str(destination),
            output_format="WAV", use_soundfile=True, normalization_threshold=1.0,
            mdx_params={"hop_length": 1024, "segment_size": 256, "overlap": 0.25,
                        "batch_size": 1, "enable_denoise": False},
        )
        separator.load_model(model_filename=model_name)
        # The pinned library's optional soundfile writer ignores output_dir and can cast stereo floats to int16
        # before scaling them. Supply an explicit float WAV writer so quiet stems and stereo channels survive.
        def write_stem(stem_path, samples):
            data = np.asarray(samples, dtype=np.float32)
            if data.ndim != 2 or data.shape[1] != 2:
                raise RuntimeError('The model returned invalid stereo audio')
            sf.write(str(destination / Path(stem_path).name), data, 44100, subtype='FLOAT')
        separator.model_instance.write_audio = write_stem
        # Keep full-song buffers out of RAM. Model windows overlap inside each 60-second chunk; the two-second
        # crossfade between chunks also preserves timing and avoids hard seams at the chunk boundaries.
        tails = {}
        writers = {name: sf.SoundFile(str(destination / f'{name}.wav'), 'w', samplerate=rate,
                   channels=2, format='WAV', subtype='FLOAT') for name in ['backing', 'guide']}
        try:
            with sf.SoundFile(str(decoded)) as audio:
                start = 0
                while start < len(audio):
                    audio.seek(start)
                    samples = audio.read(min(chunk, len(audio) - start), dtype='float32', always_2d=True)
                    piece = destination / 'part.wav'
                    sf.write(str(piece), samples, rate, subtype='FLOAT')
                    last = start + len(samples) == len(audio)
                    separator.separate(str(piece), custom_output_names={stem: stem_file(stem) for stem in STEMS})
                    stems = {}
                    for file in destination.glob('part-*.wav'):
                        stems[file.stem], _ = sf.read(str(file), dtype='float32', always_2d=True)
                        file.unlink()
                        if len(stems[file.stem]) != len(samples):
                            raise RuntimeError('The model changed the audio length')
                    # The library names a part it wasn't given a name for after the input, so none goes missing unseen.
                    if removed not in stems or len(stems) < 2 or any(destination.glob('part_*.wav')):
                        raise RuntimeError('The model did not return the expected parts of the song')
                    # A two-part model returns the backing track itself; a four-part model returns its pieces.
                    parts = {'guide': stems.pop(removed), 'backing': sum(stems.values())}
                    for name, writer in writers.items():
                        data = parts[name]
                        if name in tails:
                            ramp = np.linspace(0, 1, overlap, dtype=np.float32)[:, None]
                            writer.write(tails.pop(name) * (1 - ramp) + data[:overlap] * ramp)
                            data = data[overlap:]
                        if last:
                            writer.write(data)
                        else:
                            writer.write(data[:-overlap])
                            tails[name] = data[-overlap:].copy()
                    piece.unlink()
                    done = (start + len(samples)) / len(audio)
                    progress = {'progress': span[0] + span[1] * (step + done) / len(passes),
                                'message': f'Separating {stem.lower()}{label} ({round(100 * done)}%)'}
                    report(destination.parent if label else destination, progress)
                    if last:
                        break
                    start += chunk - overlap
        finally:
            for writer in writers.values():
                writer.close()

    for step, (model_name, stem) in enumerate(zip(passes, removed_stems)):
        separate(step, model_name, stem)
        # The next pass works on what this one left; only the last pass's stem comes back as the guide.
        backing.replace(decoded)
    decoded.replace(backing)
    return backing, guide_part


def encode(source, output, filters=None):
    """[source] as 16-bit stereo FLAC, through ffmpeg [filters] (-af or -filter_complex arguments) if given."""
    command = ["ffmpeg", "-v", "error", "-nostdin", "-y", *source, *(filters or [])]
    command += ["-ar", "44100", "-ac", "2", "-c:a", "flac", "-sample_fmt", "s16", str(output)]
    subprocess.run(command, check=True, capture_output=True, timeout=300)


def loudness(path):
    """Integrated loudness and true peak, as the app's loudness matching reads them."""
    meter = subprocess.run(
        ["ffmpeg", "-hide_banner", "-nostdin", "-i", str(path), "-af",
         "loudnorm=I=-14:TP=-1:LRA=11:print_format=json", "-f", "null", "-"],
        check=True, capture_output=True, text=True, timeout=300,
    ).stderr
    result = json.JSONDecoder().raw_decode(meter[meter.rfind("{"):])[0]
    return float(result["input_i"]), float(result["input_tp"])


def prepare(source, destination, models, model, chunk_seconds=60, overlap_seconds=2, part='vocals'):
    started = time.monotonic()
    destination = Path(destination)
    backing, guide_part = split(source, destination, models, model, part, chunk_seconds, overlap_seconds)
    mixes = {}
    for guide in (0, 25, 50, 75, 100):
        # Both model outputs share the original timeline. No silence trimming, tempo changes, or lossy encoder delay.
        inputs = ["-i", str(backing)]
        if guide:
            inputs += ["-i", str(guide_part)]
            filters = ["-filter_complex",
                       f"[1:a]volume={guide / 100}[v];[0:a][v]amix=inputs=2:normalize=0:duration=first,"
                       "alimiter=limit=0.891251:level=false:latency=true[a]", "-map", "[a]"]
        else:
            filters = ["-af", "alimiter=limit=0.891251:level=false:latency=true"]
        output = destination / f"mix-{guide}.flac"
        encode(inputs, output, filters)
        lufs, peak = loudness(output)
        mixes[str(guide)] = {"version": 1, "lufs": lufs, "truePeak": peak, "bytes": output.stat().st_size}
        if not all(__import__('math').isfinite(mixes[str(guide)][key]) for key in ['lufs', 'truePeak']):
            raise RuntimeError("The separated song is silent or invalid")
    manifest = {"mixes": mixes, "seconds": round(time.monotonic() - started, 2), "model": model, "part": part}
    if part == 'vocals':
        # The singing on its own, for mashups that put it over another song's instrumental.
        encode(["-i", str(guide_part)], destination / "vocals.flac")
        manifest["vocals"] = {"bytes": (destination / "vocals.flac").stat().st_size}
    backing.unlink()
    guide_part.unlink()
    (destination / "result.json").write_text(json.dumps(manifest))


if __name__ == "__main__":
    os.nice(10)
    source, destination, models, model, *rest = sys.argv[1:]
    prepare(source, destination, models, model, part=rest[0] if rest else 'vocals')
