"""A real mashup render (ffmpeg and Rubber Band) of made-up songs, without downloading a neural model."""
import json
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

import numpy as np
import soundfile as sf

import mashup
import mashup_worker
from test_karaoke_worker import FakeSeparator

RATE = 44100


def tone(seconds, frequency, level, start=0.0, end=None):
    """A stereo sine of [frequency] Hz, sounding from [start] to [end] seconds."""
    t = np.arange(int(seconds * RATE)) / RATE
    wave = level * np.sin(2 * np.pi * frequency * t)
    wave[(t < start) | (t >= (end if end is not None else seconds))] = 0
    return np.stack([wave, wave], axis=1).astype(np.float32)


def band_level(audio, frequency, frame=0.05):
    """The level of a narrow band around [frequency] per [frame] seconds, in dB."""
    mono = audio.mean(axis=1) if audio.ndim == 2 else audio
    size = int(frame * RATE)
    frames = mono[:len(mono) // size * size].reshape(-1, size) * np.hanning(size)
    spectrum = np.abs(np.fft.rfft(frames, axis=1))
    bins = np.fft.rfftfreq(size, 1 / RATE)
    near = (bins > frequency * 0.94) & (bins < frequency * 1.06)
    return 20 * np.log10(spectrum[:, near].max(axis=1) + 1e-9)


class RenderTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.folder = Path(temp.name)
        # The singer's song: 125 bpm, singing (a 1 kHz tone) from 6 s; the backing song: 120 bpm, a 110 Hz
        # instrumental whose own singer started at 10 s.
        self.vocals = tone(30, 1000, .2, start=6, end=26)
        self.backing = tone(36, 110, .3)
        self.plan = mashup.plan(
            {'key': 'D major', 'beatBpm': 125, 'firstBeat': 0.24, 'lastBeat': 0.24 + 56 * 0.48, 'duration': 30,
             'intro': 4},
            {'key': 'C major', 'beatBpm': 120, 'firstBeat': 0.5, 'lastBeat': 0.5 + 66 * 0.5, 'duration': 36,
             'intro': 4, 'end': 35})

    def write(self, name, audio):
        # Cached parts are 16-bit FLAC, as the karaoke worker makes them.
        sf.write(str(self.folder / name), audio, RATE, subtype='PCM_16')
        return name

    def job(self, vocals, backing):
        (self.folder / 'job.json').write_text(json.dumps({'plan': self.plan, 'model': 'fake.onnx',
                                                          'vocals': vocals, 'backing': backing}))

    def test_cached_parts_are_fitted_lined_up_and_balanced(self):
        self.job({'source': 'unused', 'stem': self.write('vocals-in.flac', self.vocals),
                  'instrumental': self.write('vocals-backing-in.flac', tone(30, 110, .2))},
                 {'source': 'unused', 'instrumental': self.write('backing-in.flac', self.backing),
                  'vocals': self.write('backing-vocals-in.flac', tone(36, 1000, .2, start=10, end=30))})
        mashup_worker.make(str(self.folder), str(self.folder / 'models'))
        manifest = json.loads((self.folder / 'result.json').read_text())
        placed = manifest['placement']
        self.assertEqual((placed['vocalEntry'], placed['backingEntry'], placed['separated']), (6.0, 10.0, []))
        self.assertAlmostEqual(placed['offset'], mashup.placement(self.plan, 6.0, 10.0))
        output, rate = sf.read(str(self.folder / 'mashup.flac'), always_2d=True)
        self.assertEqual((rate, len(output)), (RATE, len(self.backing)))
        self.assertEqual(manifest['mixes']['mashup']['bytes'], (self.folder / 'mashup.flac').stat().st_size)
        # Shifted down two semitones (1 kHz to about 891 Hz), sung from the backing singer's beat at 10 s.
        shifted = band_level(output, 1000 * 2 ** (-2 / 12))
        sung = np.flatnonzero(shifted > shifted.max() - 12)
        self.assertAlmostEqual(sung[0] * 0.05, 10.0, delta=0.1)
        self.assertLess(band_level(output, 1000)[sung].max(), shifted.max() - 12)
        # Stretched to the slower beat: 20 s of singing at 125 bpm lasts 20.8 s at 120.
        self.assertAlmostEqual((sung[-1] - sung[0] + 1) * 0.05, 20 * 125 / 120, delta=0.15)
        # As loud against the new instrumental as against its own: that's 0.3 against 0.2, so 3.5 dB louder.
        self.assertAlmostEqual(placed['gainDb'], 20 * np.log10(.3 / .2), delta=0.5)
        self.assertEqual(sorted(file.name for file in self.folder.iterdir()),
                         ['job.json', 'mashup.flac', 'progress.json', 'result.json'])

    def test_vocals_running_past_the_backing_fade_out_by_its_end(self):
        self.backing = tone(18, 110, .3)
        self.plan['backing'].update(duration=18, end=18)
        self.job({'source': 'unused', 'stem': self.write('vocals-in.flac', self.vocals)},
                 {'source': 'unused', 'instrumental': self.write('backing-in.flac', self.backing)})
        mashup_worker.make(str(self.folder), str(self.folder / 'models'))
        output, _ = sf.read(str(self.folder / 'mashup.flac'), always_2d=True)
        self.assertEqual(len(output), len(self.backing))
        shifted = band_level(output, 1000 * 2 ** (-2 / 12))
        # No sung entry known for the backing song: its intro's beat stands in.
        self.assertIsNone(json.loads((self.folder / 'result.json').read_text())['placement']['backingEntry'])
        self.assertLess(shifted[-2], shifted.max() - 20)
        self.assertGreater(shifted[-60], shifted.max() - 6)

    def test_songs_without_karaoke_are_separated_first(self):
        whole = self.vocals + tone(30, 110, .2)
        sf.write(str(self.folder / 'singer.wav'), whole, RATE, subtype='FLOAT')
        sf.write(str(self.folder / 'band.wav'), self.backing, RATE, subtype='FLOAT')
        self.job({'source': str(self.folder / 'singer.wav')}, {'source': str(self.folder / 'band.wav')})
        fakes = {'audio_separator.separator': types.ModuleType('audio_separator.separator'),
                 'torch': types.ModuleType('torch'), 'onnxruntime': types.ModuleType('onnxruntime')}
        fakes['audio_separator.separator'].Separator = FakeSeparator
        fakes['torch'].set_num_threads = Mock()
        fakes['onnxruntime'].InferenceSession = fakes['onnxruntime'].SessionOptions = Mock()
        # The fake model hears everything as instrumental, except the singer's song, which it splits evenly.
        with patch.dict(sys.modules, fakes), patch.object(FakeSeparator, 'stems', [('Instrumental', .5),
                                                                                  ('Vocals', .5)]):
            mashup_worker.make(str(self.folder), str(self.folder / 'models'))
        manifest = json.loads((self.folder / 'result.json').read_text())
        self.assertEqual(manifest['placement']['separated'], ['singer', 'backing'])
        self.assertFalse((self.folder / 'singer').exists() or (self.folder / 'backing').exists())
        progress = json.loads((self.folder / 'progress.json').read_text())
        self.assertEqual(progress['message'], 'Mixing the mashup')

    def test_a_song_without_singing_is_refused(self):
        self.job({'source': 'unused', 'stem': self.write('vocals-in.flac', tone(30, 1000, 0))},
                 {'source': 'unused', 'instrumental': self.write('backing-in.flac', self.backing)})
        with self.assertRaisesRegex(RuntimeError, 'no vocals'):
            mashup_worker.make(str(self.folder), str(self.folder / 'models'))

    def test_channels_out_of_phase_still_count_as_singing(self):
        sung = tone(10, 1000, .2, start=4)
        sung[:, 1] = -sung[:, 1]
        levels = mashup_worker.levels(self.folder / self.write('opposite.flac', sung))
        frames = int(4 / mashup_worker.FRAME_SECONDS)
        self.assertLess(levels[:frames].max(), -100)
        self.assertGreater(levels[frames + 1:].min(), -20)

    def test_vocal_filters_place_trim_and_fade(self):
        self.assertEqual(mashup_worker.vocal_filters(1.5, 10, 30, -2),
                         ['adelay=delays=1500:all=1', 'volume=-2.00dB'])
        self.assertEqual(mashup_worker.vocal_filters(-2.25, 40, 30, 1),
                         ['atrim=start=2.2500', 'asetpts=PTS-STARTPTS', 'afade=t=in:d=0.05',
                          'afade=t=out:st=28.0000:d=2.0', 'atrim=end=30.0000', 'volume=1.00dB'])


if __name__ == '__main__': unittest.main()
