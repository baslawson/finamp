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
    def __init__(self, **kwargs):
        self.output = Path(kwargs['output_dir'])
        self.model_instance = self

    def load_model(self, **_):
        pass

    def separate(self, source, custom_output_names):
        audio, rate = sf.read(source, dtype='float32', always_2d=True)
        for name, fraction in [('Instrumental', .6), ('Vocals', .4)]:
            self.write_audio(custom_output_names[name] + '.wav', audio * fraction)


class WorkerTests(unittest.TestCase):
    def test_chunk_joins_preserve_samples_timing_and_guide_levels(self):
        fake_separator = types.ModuleType('audio_separator.separator')
        fake_separator.Separator = FakeSeparator
        fake_torch = types.ModuleType('torch')
        fake_torch.set_num_threads = Mock()
        fake_ort = types.ModuleType('onnxruntime')
        fake_ort.InferenceSession = Mock()
        fake_ort.SessionOptions = Mock()
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            # Noninteger chunk count, stereo and a waveform that crosses every boundary.
            t = np.arange(int(6.37 * 44100)) / 44100
            audio = np.stack([.1 * np.sin(t * 2 * np.pi * 440), .08 * np.cos(t * 2 * np.pi * 661)], axis=1)
            source = folder / 'original.wav'
            sf.write(str(source), audio, 44100, subtype='FLOAT')
            with patch.dict(sys.modules, {'audio_separator.separator': fake_separator, 'torch': fake_torch,
                                          'onnxruntime': fake_ort}):
                prepare(str(source), str(folder / 'out'), str(folder / 'models'), 'fake.onnx', 2, .25)
            manifest = json.loads((folder / 'out/result.json').read_text())
            for guide in [0, 25, 50, 75, 100]:
                mixed, rate = sf.read(str(folder / f'out/mix-{guide}.flac'))
                self.assertEqual(rate, 44100)
                self.assertEqual(mixed.shape, audio.shape)
                np.testing.assert_allclose(mixed, audio * (.6 + .4 * guide / 100), atol=4e-5)
                self.assertTrue(np.isfinite(manifest['mixes'][str(guide)]['lufs']))


if __name__ == '__main__': unittest.main()
