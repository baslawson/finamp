import os
import subprocess
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

from loudness import LoudnessIndex, measure, parse_summary


class MeterTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)

    def tone(self, name, volume, seconds=3):
        path = self.folder / name
        subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i",
            f"sine=frequency=1000:sample_rate=48000:duration={seconds}",
            "-af", f"volume={volume}", "-ac", "2", "-c:a", "pcm_f32le", str(path)], check=True)
        return str(path)

    def test_gain_difference_and_true_peak(self):
        loud = measure([self.tone("loud.wav", 1)])
        quiet = measure([self.tone("quiet.wav", 0.1)])
        self.assertAlmostEqual(loud[0] - quiet[0], 20, delta=0.2)
        self.assertAlmostEqual(loud[1] - quiet[1], 20, delta=0.2)

    def test_album_gate_is_not_an_average_of_track_lufs(self):
        loud, quiet = self.tone("loud.wav", 1, 6), self.tone("quiet.wav", 0.01, 6)
        first, second = measure([loud]), measure([quiet])
        album = measure([loud, quiet])
        self.assertGreater(album[0], (first[0] + second[0]) / 2 + 10)
        self.assertAlmostEqual(album[1], first[1], delta=0.2)

    def test_end_of_program_is_included_and_silence_is_unmeasured(self):
        quiet, loud = self.tone("quiet.wav", 0.01, 8), self.tone("loud.wav", 2, 1)
        self.assertGreater(measure([quiet, loud])[1], measure([quiet])[1] + 40)
        self.assertEqual(measure([self.tone("silent.wav", 0)]), (None, None))

    def test_incomplete_output_is_not_published(self):
        with self.assertRaises(ValueError):
            parse_summary("I: -14 LUFS")
        self.assertEqual(parse_summary("I: -14 LUFS\nPeak: -1.2 dBFS"), (-14, -1.2))


class CacheTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)
        self.files = [self.folder / "one.wav", self.folder / "two.wav"]
        for file in self.files:
            file.write_bytes(b"test")
        self.items = [{"Id": str(i), "Path": str(file), "AlbumId": "album", "IndexNumber": i}
                      for i, file in enumerate(self.files)]
        self.index = LoudnessIndex(self.temp.name, "", "", self.temp.name, lambda p: p)
        self.addCleanup(self.index.connection.close)
        self.index.library = lambda: list(self.items)

    @patch("loudness.measure", return_value=(-18.0, -4.0))
    def test_incremental_scan_reuses_and_invalidates_track_and_album(self, meter):
        self.index.scan()
        self.assertEqual(meter.call_count, 3)
        self.assertEqual(self.index.lookup(["0"])["0"]["albumLufs"], -18)
        self.index.scan()
        self.assertEqual(meter.call_count, 3)
        self.files[0].write_bytes(b"changed bytes")
        self.index.scan()
        self.assertEqual(meter.call_count, 5)
        self.files[1].unlink()
        self.index.scan()
        self.assertIsNone(self.index.lookup(["0"])["0"]["albumLufs"])
        self.assertNotIn("1", self.index.lookup(["1"]))
        self.items.clear()
        self.index.scan()
        self.assertEqual(self.index.lookup(["0"]), {})

    @patch("loudness.measure", side_effect=ValueError("bad audio"))
    def test_bad_file_does_not_stop_scan_or_publish_a_gain(self, meter):
        self.index.scan()
        self.assertEqual(self.index.status()["failed"], 2)
        self.assertEqual(self.index.lookup(["0", "1"]), {})

    @patch("loudness.measure", side_effect=ValueError("bad audio"))
    def test_failed_files_are_not_decoded_on_every_scan_but_are_retried_later(self, meter):
        self.index.scan()
        self.assertEqual(meter.call_count, 3)
        self.index.scan()
        self.assertEqual(meter.call_count, 3, "nothing changed, so nothing is decoded again")
        self.assertEqual(self.index.settled(["0", "1", "unknown"]), {"0", "1"})
        with self.index.lock:
            self.index.connection.execute("UPDATE tracks SET failed_at=? WHERE id='0'", (time.time() - 4 * 86400,))
            self.index.connection.commit()
        self.index.scan()
        self.assertEqual(meter.call_args_list[3].args[0], [str(self.files[0])])
        self.assertEqual(meter.call_count, 4)

    def test_failures_recorded_before_the_retry_time_existed_are_retried_once(self):
        with patch("loudness.measure", side_effect=ValueError("bad audio")):
            self.index.scan()
        with self.index.lock:
            self.index.connection.execute("UPDATE tracks SET failed_at=NULL")
            self.index.connection.execute("UPDATE albums SET failed_at=NULL")
            self.index.connection.commit()
        with patch("loudness.measure", return_value=(-18.0, -4.0)) as meter:
            self.index.scan()
        self.assertEqual(meter.call_count, 3)
        self.assertEqual(self.index.lookup(["0"])["0"]["albumLufs"], -18)

    def test_changed_album_is_invalidated_before_track_decoding_starts(self):
        with patch("loudness.measure", return_value=(-18.0, -4.0)):
            self.index.scan()
        self.files[0].write_bytes(b"a new master")
        def inspect_during_decode(paths):
            self.assertIsNone(self.index.lookup(["1"])["1"]["albumLufs"])
            if paths == [str(self.files[0])]:
                self.assertNotIn("0", self.index.lookup(["0"]))
            return -15.0, -1.0
        with patch("loudness.measure", side_effect=inspect_during_decode):
            self.index.scan()
        self.assertEqual(self.index.lookup(["1"])["1"]["albumLufs"], -15)

    @patch("loudness.measure", return_value=(None, None))
    def test_silence_does_not_turn_into_a_boost(self, meter):
        self.index.scan()
        self.assertEqual(self.index.lookup(["0", "1"]), {})

    def test_runtime_priorities_change_work_order_without_changing_album_program_or_cached_gains(self):
        from server_runtime import RuntimeGovernor
        sample = {'cpus': 4, 'load': [0, 0, 0], 'memoryAvailable': 2 * 1024**3,
            'diskFree': 20 * 1024**3, 'pressure': {}}
        runtime = RuntimeGovernor(self.temp.name, playback=lambda: 0, probe=lambda _: sample)
        runtime.priority_loader = lambda: ['1']
        runtime.refresh()
        self.index.runtime = runtime
        with patch('loudness.measure', return_value=(-18.0, -4.0)) as meter:
            self.index.scan()
            programs = [call.args[0] for call in meter.call_args_list]
            self.assertEqual(programs, [[str(self.files[1])], [str(self.files[0])], [str(file) for file in self.files]])
            cached = self.index.lookup(['0', '1'])
            self.index.scan()
            self.assertEqual(meter.call_count, 3)
            self.assertEqual(self.index.lookup(['0', '1']), cached)


if __name__ == "__main__":
    unittest.main()
