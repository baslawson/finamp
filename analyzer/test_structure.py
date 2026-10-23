import tempfile
import unittest
from unittest.mock import Mock

import numpy as np

import structure

RATE = 11025


def tone(seconds, level=0.3, frequency=220.0):
    t = np.arange(int(seconds * RATE)) / RATE
    return (level * np.sin(2 * np.pi * frequency * t)).astype(np.float32)


def silence(seconds):
    return np.zeros(int(seconds * RATE), dtype=np.float32)


class CueTests(unittest.TestCase):
    def test_leading_and_trailing_silence(self):
        found = structure.cues(np.concatenate([silence(2), tone(30), silence(6)]), RATE)
        self.assertAlmostEqual(found["start"], 2, delta=0.1)
        self.assertAlmostEqual(found["end"], 32, delta=0.1)
        self.assertIsNone(found["hidden"])

    def test_fade_out_is_the_outro(self):
        fade = tone(10) * np.linspace(1, 0.01, int(10 * RATE), dtype=np.float32)
        found = structure.cues(np.concatenate([tone(40), fade]), RATE)
        # -6 dB is reached halfway down the linear fade.
        self.assertAlmostEqual(found["outro"], 45, delta=1.5)
        self.assertGreater(found["end"], 48)

    def test_quiet_intro(self):
        found = structure.cues(np.concatenate([tone(8, level=0.03), tone(40)]), RATE)
        self.assertAlmostEqual(found["intro"], 8, delta=1.5)
        self.assertAlmostEqual(found["start"], 0, delta=0.1)

    def test_hidden_track_after_long_silence(self):
        found = structure.cues(np.concatenate([tone(60), silence(30), tone(20)]), RATE)
        self.assertAlmostEqual(found["end"], 60, delta=0.1)
        self.assertAlmostEqual(found["hidden"], 90, delta=0.1)

    def test_a_pause_early_on_is_not_a_hidden_track(self):
        found = structure.cues(np.concatenate([tone(10), silence(12), tone(60)]), RATE)
        self.assertIsNone(found["hidden"])
        self.assertAlmostEqual(found["end"], 82, delta=0.1)

    def test_silence_has_no_cues(self):
        self.assertIsNone(structure.cues(silence(5), RATE))


class BeatTests(unittest.TestCase):
    def test_chunked_spectra_preserve_overlap_global_floor_and_beats(self):
        import librosa
        rng = np.random.default_rng(7)
        samples = (rng.normal(size=RATE * 7 + 137) * .003).astype(np.float32)
        samples[9000:18000] *= 100
        samples[25000:40000] = 0
        expected = librosa.onset.onset_strength(y=samples, sr=RATE, hop_length=structure.HOP)
        centroid = librosa.feature.spectral_centroid(y=samples, sr=RATE, hop_length=structure.HOP).mean()
        for block in (1, 17, 1024):
            onset, brightness = structure.spectral_stats(lambda first, last: samples[first:last], len(samples), RATE, block)
            np.testing.assert_allclose(onset, expected, atol=2e-5)
            self.assertAlmostEqual(brightness, centroid, places=7)
            np.testing.assert_array_equal(structure.beat_tempo(onset, RATE, block),
                librosa.feature.tempo(onset_envelope=expected, sr=RATE, hop_length=structure.HOP))

    def test_disk_analysis_matches_cues_and_beats_across_rms_chunks(self):
        samples = np.concatenate([silence(.7), tone(198), silence(11), tone(15), silence(.2)])
        expected = structure.cues(samples, RATE)
        expected.update(structure.beats(samples, RATE, expected['start'], expected['end']))
        expected['decoded'] = len(samples) / RATE
        with tempfile.TemporaryFile() as source:
            source.write(samples.tobytes())
            bounded = Mock(wraps=source)
            self.assertEqual(structure.analyze_file(bounded, RATE), expected)
            self.assertTrue(all(0 < call.args[0] <= 4096 * structure.HOP * 4 for call in bounded.read.call_args_list))
        # The trailing partial RMS frame is ignored exactly as before.
        frames = len(samples) // structure.HOP
        blocks = samples[:frames * structure.HOP].astype(np.float64).reshape(frames, structure.HOP)
        old = 20 * np.log10(np.maximum(np.sqrt((blocks**2).mean(axis=1)), 1e-7))
        np.testing.assert_array_equal(structure.frame_db(samples), old)

    def test_clicks_at_120_bpm(self):
        samples = silence(30)
        click = tone(0.03, level=0.9, frequency=1000)
        for beat in np.arange(1.0, 29.0, 0.5):
            start = int(beat * RATE)
            samples[start : start + len(click)] += click
        found = structure.beats(samples, RATE, 0, 30)
        self.assertAlmostEqual(found["beatBpm"], 120, delta=3)
        self.assertAlmostEqual(found["firstBeat"] % 0.5, 0, delta=0.06)
        self.assertGreater(found["lastBeat"], 27)


class IntensityTests(unittest.TestCase):
    def test_busier_brighter_louder_faster_is_more_intense(self):
        calm = {"onset": 0.5, "brightness": 900, "level": -30, "bpm": 70}
        middle = {"onset": 1.0, "brightness": 1800, "level": -20, "bpm": 110}
        wild = {"onset": 2.0, "brightness": 3500, "level": -10, "bpm": 170}
        result = structure.intensities([wild, calm, middle])
        self.assertEqual(result[1], 0.0)
        self.assertEqual(result[0], 1.0)
        self.assertTrue(0 < result[2] < 1)

    def test_unknown_onsets_have_no_intensity(self):
        self.assertEqual(structure.intensities([{"onset": None, "bpm": 100}]), [None])


class FingerprintTests(unittest.TestCase):
    def test_same_recording_with_an_offset(self):
        rng = np.random.default_rng(1)
        a = rng.integers(0, 2**32, 300, dtype=np.uint64).astype(np.uint32)
        self.assertTrue(structure.same_recording(a, a[5:]))
        b = rng.integers(0, 2**32, 300, dtype=np.uint64).astype(np.uint32)
        self.assertFalse(structure.same_recording(a, b))


if __name__ == "__main__":
    unittest.main()
