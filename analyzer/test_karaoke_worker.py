"""Exercise real decoding, chunk joins, mixing and encoding without downloading a neural model."""
import json
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

import numpy as np
import soundfile as sf
from karaoke_worker import prepare


class FakeSeparator:
    # The parts the fake model returns, and how much of the song each one holds.
    stems = [('Instrumental', .6), ('Vocals', .4)]

    def __init__(self, **kwargs):
        self.output = Path(kwargs['output_dir'])
        self.model_instance = self

    def load_model(self, model_filename):
        # A dictionary gives each model its own parts, for preparations that run more than one.
        self.model = model_filename

    def separate(self, source, custom_output_names):
        audio, rate = sf.read(source, dtype='float32', always_2d=True)
        stems = self.stems[self.model] if isinstance(self.stems, dict) else self.stems
        for name, fraction in stems:
            # As the library does, a part without a custom name is named after the input file.
            file = custom_output_names.get(name, f'{Path(source).stem}_({name})_fake')
            self.write_audio(file + '.wav', audio * fraction)


class WorkerTests(unittest.TestCase):
    def run_worker(self, stems, part='vocals', model='fake.onnx'):
        fake_separator = types.ModuleType('audio_separator.separator')
        fake_separator.Separator = FakeSeparator
        fake_torch = types.ModuleType('torch')
        fake_torch.set_num_threads = Mock()
        fake_ort = types.ModuleType('onnxruntime')
        fake_ort.InferenceSession = Mock()
        fake_ort.SessionOptions = Mock()
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        folder = Path(temp.name)
        # Noninteger chunk count, stereo and a waveform that crosses every boundary.
        t = np.arange(int(6.37 * 44100)) / 44100
        audio = np.stack([.1 * np.sin(t * 2 * np.pi * 440), .08 * np.cos(t * 2 * np.pi * 661)], axis=1)
        source = folder / 'original.wav'
        sf.write(str(source), audio, 44100, subtype='FLOAT')
        with patch.dict(sys.modules, {'audio_separator.separator': fake_separator, 'torch': fake_torch,
                                      'onnxruntime': fake_ort}), patch.object(FakeSeparator, 'stems', stems):
            prepare(str(source), str(folder / 'out'), str(folder / 'models'), model, 2, .25, part=part)
        return audio, folder / 'out'

    def assert_mixes(self, audio, out, backing, guide_share):
        manifest = json.loads((out / 'result.json').read_text())
        for guide in [0, 25, 50, 75, 100]:
            mixed, rate = sf.read(str(out / f'mix-{guide}.flac'))
            self.assertEqual(rate, 44100)
            self.assertEqual(mixed.shape, audio.shape)
            np.testing.assert_allclose(mixed, audio * (backing + guide_share * guide / 100), atol=4e-5)
            self.assertTrue(np.isfinite(manifest['mixes'][str(guide)]['lufs']))
        self.assertEqual(sorted(file.name for file in out.iterdir()),
                         ['mix-0.flac', 'mix-100.flac', 'mix-25.flac', 'mix-50.flac', 'mix-75.flac', 'progress.json',
                          'result.json'])
        return manifest

    def test_chunk_joins_preserve_samples_timing_and_guide_levels(self):
        audio, out = self.run_worker([('Instrumental', .6), ('Vocals', .4)])
        self.assertEqual(self.assert_mixes(audio, out, .6, .4)['part'], 'vocals')

    def test_drumless_mixes_take_out_the_drums_and_bring_them_back_as_the_guide(self):
        audio, out = self.run_worker([('Drums', .3), ('No Drums', .7)], 'drums')
        self.assertEqual(self.assert_mixes(audio, out, .7, .3)['part'], 'drums')
        self.assertIn('drums', json.loads((out / 'progress.json').read_text())['message'])

    def test_a_four_part_model_keeps_everything_but_the_drums(self):
        audio, out = self.run_worker([('Drums', .25), ('Bass', .2), ('Other', .35), ('Vocals', .2)], 'drums')
        self.assert_mixes(audio, out, .75, .25)

    def test_a_model_without_the_part_to_remove_fails_instead_of_keeping_it(self):
        with self.assertRaises(RuntimeError):
            self.run_worker([('Instrumental', .6), ('Vocals', .4)], 'drums')
        with self.assertRaises(RuntimeError):
            self.run_worker([('Drums', 1)], 'drums')

    def test_a_part_the_worker_has_no_name_for_fails_instead_of_going_missing(self):
        with self.assertRaises(RuntimeError):
            self.run_worker([('Drums', .3), ('No Drums', .5), ('Synth', .2)], 'drums')

    def test_both_takes_the_vocals_out_then_the_drums_and_brings_back_only_the_drums(self):
        # The drum model sees only the instrumental: 60% of the song, 25% of which is drums.
        stems = {'vocal.onnx': [('Instrumental', .6), ('Vocals', .4)], 'drum.onnx': [('Drums', .25), ('No Drums', .75)]}
        audio, out = self.run_worker(stems, 'both', 'vocal.onnx,drum.onnx')
        self.assertEqual(self.assert_mixes(audio, out, .45, .15)['part'], 'both')
        progress = json.loads((out / 'progress.json').read_text())
        self.assertEqual((progress['progress'], progress['message']), (.75, 'Separating drums (100%)'))

    def test_both_from_a_song_without_vocals_runs_only_the_drum_model(self):
        audio, out = self.run_worker({'drum.onnx': [('Drums', .25), ('No Drums', .75)]}, 'both', 'drum.onnx')
        self.assert_mixes(audio, out, .75, .25)

    def test_more_models_than_parts_to_remove_fail(self):
        with self.assertRaises(RuntimeError):
            self.run_worker([('Drums', .3), ('No Drums', .7)], 'drums', 'a.onnx,b.onnx')


if __name__ == '__main__': unittest.main()
