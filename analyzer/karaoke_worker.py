"""One bounded separation subprocess. Exits after a song, releasing all model memory."""
import json
import logging
import os
import subprocess
import sys
import time
from pathlib import Path


def prepare(source, destination, models, model, chunk_seconds=60, overlap_seconds=2):
    started = time.monotonic()
    import onnxruntime as ort
    import numpy as np
    import soundfile as sf
    import torch
    from audio_separator.separator import Separator

    torch.set_num_threads(1)
    # ORT otherwise creates a pool for every visible VM core, despite the container CPU quota.
    original_session = ort.InferenceSession

    def session(path, sess_options=None, **kwargs):
        options = sess_options or ort.SessionOptions()
        options.intra_op_num_threads = 1
        options.inter_op_num_threads = 1
        return original_session(path, sess_options=options, **kwargs)

    ort.InferenceSession = session
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    separator = Separator(
        log_level=logging.WARNING, model_file_dir=models, output_dir=str(destination),
        output_format="WAV", use_soundfile=True, normalization_threshold=1.0,
        mdx_params={"hop_length": 1024, "segment_size": 256, "overlap": 0.25,
                    "batch_size": 1, "enable_denoise": False},
    )
    separator.load_model(model_filename=model)
    # The pinned library's optional soundfile writer ignores output_dir and can cast stereo floats to int16
    # before scaling them. Supply an explicit float WAV writer so quiet stems and stereo channels survive.
    def write_stem(stem_path, samples):
        data = np.asarray(samples, dtype=np.float32)
        if data.ndim != 2 or data.shape[1] != 2:
            raise RuntimeError('The model returned invalid stereo audio')
        sf.write(str(destination / Path(stem_path).name), data, 44100, subtype='FLOAT')
    separator.model_instance.write_audio = write_stem
    instrumental, vocals = destination / "instrumental.wav", destination / "vocals.wav"
    decoded = destination / 'source.wav'
    subprocess.run(['ffmpeg', '-v', 'error', '-nostdin', '-y', '-i', source, '-ar', '44100', '-ac', '2',
                    '-c:a', 'pcm_f32le', str(decoded)], capture_output=True, check=True, timeout=300)
    # Keep full-song buffers out of RAM. Model windows overlap inside each 60-second chunk; the two-second
    # crossfade between chunks also preserves timing and avoids hard seams at the chunk boundaries.
    rate, chunk, overlap = 44100, int(chunk_seconds * 44100), int(overlap_seconds * 44100)
    tails = {}
    writers = {name: sf.SoundFile(str(destination / f'{name}.wav'), 'w', samplerate=rate,
               channels=2, format='WAV', subtype='FLOAT') for name in ['instrumental', 'vocals']}
    try:
        with sf.SoundFile(str(decoded)) as audio:
            start = 0
            while start < len(audio):
                audio.seek(start)
                samples = audio.read(min(chunk, len(audio) - start), dtype='float32', always_2d=True)
                part = destination / 'part.wav'
                sf.write(str(part), samples, rate, subtype='FLOAT')
                last = start + len(samples) == len(audio)
                separator.separate(str(part), custom_output_names={'Instrumental': 'part-instrumental', 'Vocals': 'part-vocals'})
                for name, writer in writers.items():
                    file = destination / f'part-{name}.wav'
                    data, _ = sf.read(str(file), dtype='float32', always_2d=True)
                    if len(data) != len(samples):
                        raise RuntimeError('The model changed the audio length')
                    if name in tails:
                        ramp = np.linspace(0, 1, overlap, dtype=np.float32)[:, None]
                        writer.write(tails.pop(name) * (1 - ramp) + data[:overlap] * ramp)
                        data = data[overlap:]
                    if last:
                        writer.write(data)
                    else:
                        writer.write(data[:-overlap])
                        tails[name] = data[-overlap:].copy()
                    file.unlink()
                part.unlink()
                progress = {'progress': .1 + .65 * (start + len(samples)) / len(audio),
                            'message': f'Separating vocals ({round(100 * (start + len(samples)) / len(audio))}%)'}
                temp = destination / 'progress.tmp'
                temp.write_text(json.dumps(progress))
                temp.replace(destination / 'progress.json')
                if last:
                    break
                start += chunk - overlap
    finally:
        for writer in writers.values():
            writer.close()
    decoded.unlink()
    mixes = {}
    for guide in (0, 25, 50, 75, 100):
        # Both model outputs share the original timeline. No silence trimming, tempo changes, or lossy encoder delay.
        command = ["ffmpeg", "-v", "error", "-nostdin", "-y", "-i", str(instrumental)]
        if guide:
            command += ["-i", str(vocals), "-filter_complex",
                        f"[1:a]volume={guide / 100}[v];[0:a][v]amix=inputs=2:normalize=0:duration=first,"
                        "alimiter=limit=0.891251:level=false:latency=true[a]", "-map", "[a]"]
        else:
            command += ["-af", "alimiter=limit=0.891251:level=false:latency=true"]
        output = destination / f"mix-{guide}.flac"
        command += ["-ar", "44100", "-ac", "2", "-c:a", "flac", "-sample_fmt", "s16", str(output)]
        subprocess.run(command, check=True, capture_output=True, timeout=300)
        meter = subprocess.run(
            ["ffmpeg", "-hide_banner", "-nostdin", "-i", str(output), "-af",
             "loudnorm=I=-14:TP=-1:LRA=11:print_format=json", "-f", "null", "-"],
            check=True, capture_output=True, text=True, timeout=300,
        ).stderr
        result = json.JSONDecoder().raw_decode(meter[meter.rfind("{"):])[0]
        mixes[str(guide)] = {"version": 1, "lufs": float(result["input_i"]),
                             "truePeak": float(result["input_tp"]), "bytes": output.stat().st_size}
        if not all(__import__('math').isfinite(mixes[str(guide)][key]) for key in ['lufs', 'truePeak']):
            raise RuntimeError("The separated song is silent or invalid")
    instrumental.unlink()
    vocals.unlink()
    manifest = {"mixes": mixes, "seconds": round(time.monotonic() - started, 2), "model": model}
    (destination / "result.json").write_text(json.dumps(manifest))


if __name__ == "__main__":
    os.nice(10)
    prepare(*sys.argv[1:])
