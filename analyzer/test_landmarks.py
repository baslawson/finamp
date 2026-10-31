import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
import wave
import unittest.mock
from unittest.mock import patch

import numpy as np

import landmarks
import structure
from landmarks import RATE, LandmarkIndex


# C major across three octaves, for music made of the same notes and beat.
SCALE = [440 * 2 ** ((key - 69) / 12) for key in range(48, 85) if key % 12 in (0, 2, 4, 5, 7, 9, 11)]


def song(seed: int, seconds: float = 60, in_key: bool = False) -> np.ndarray:
    """Made-up music: chords of a few notes with overtones, a new one every fraction of a second; [in_key], all in
    C major on a quarter-second beat."""
    rng = np.random.default_rng(seed)
    out = np.zeros(int(seconds * RATE))
    at = 0
    while at < len(out):
        length = int((0.25 if in_key else rng.uniform(0.15, 0.5)) * RATE)
        t = np.arange(length) / RATE
        note = np.zeros(length)
        for pitch in rng.choice(SCALE, size=3, replace=False) if in_key else rng.uniform(150, 1500, size=3):
            for overtone, level in ((1, 1.0), (2, 0.5), (3, 0.25)):
                note += level * np.sin(2 * np.pi * pitch * overtone * t + rng.uniform(0, 2 * np.pi))
        note *= np.exp(-t * rng.uniform(2, 6))
        end = min(len(out), at + length)
        out[at:end] += note[: end - at]
        at = end
    out += rng.normal(0, 0.01, len(out))
    return (out / np.abs(out).max() * 0.8).astype(np.float32)


def through_a_room(samples: np.ndarray, seed: int, noise: float = 0.5) -> np.ndarray:
    """[samples] as a phone hears them across a room: echo, no bass or treble, quieter, and noise."""
    rng = np.random.default_rng(seed)
    echo = rng.normal(size=int(0.25 * RATE)) * np.exp(-np.arange(int(0.25 * RATE)) / (0.06 * RATE)) * 0.3
    echo[0] = 1
    size = 1 << int(np.ceil(np.log2(len(samples) + len(echo))))
    spectrum = np.fft.rfft(samples, size) * np.fft.rfft(echo, size)
    frequencies = np.fft.rfftfreq(size, 1 / RATE)
    spectrum[(frequencies < 300) | (frequencies > 3500)] = 0
    heard = np.fft.irfft(spectrum, size)[: len(samples)]
    heard *= 0.2 / np.sqrt(np.mean(heard ** 2))
    heard += rng.normal(0, 0.2 * noise, len(heard))
    return heard.astype(np.float32)


def wav(samples: np.ndarray, rate: int) -> bytes:
    out = io.BytesIO()
    with wave.open(out, 'wb') as file:
        file.setnchannels(1)
        file.setsampwidth(2)
        file.setframerate(rate)
        file.writeframes((np.clip(samples, -1, 1) * 32767).astype('<i2').tobytes())
    return out.getvalue()


class LandmarkTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.index = LandmarkIndex(os.path.join(self.folder.name, 'landmarks.db'))
        self.addCleanup(self.index.connection.close)
        self.songs = {f't{seed}': song(seed) for seed in range(6)}
        for track_id, samples in self.songs.items():
            self.index.add(track_id, 1.0, landmarks.landmarks(samples))

    def rows(self) -> int:
        return self.index.connection.execute('SELECT count(*) FROM landmarks').fetchone()[0]

    def test_a_recording_across_a_room_finds_its_song(self):
        for k, (track_id, start) in enumerate([('t2', 20.37), ('t4', 3.1), ('t0', 41.9)]):
            clip = self.songs[track_id][int(start * RATE) : int((start + 12) * RATE)]
            found, score, noise = self.index.match(through_a_room(clip, k))
            self.assertEqual(found, track_id, f'{start}s of {track_id}: {score} against {noise}')

    def test_music_not_in_the_library_matches_nothing(self):
        for seed in (40, 41, 42):
            found, score, noise = self.index.match(through_a_room(song(seed, 15), seed))
            self.assertIsNone(found, f'{score} against {noise}')
        self.assertEqual(self.index.match(np.zeros(RATE * 12, dtype=np.float32))[0], None)
        self.assertEqual(self.index.match(np.zeros(10, dtype=np.float32))[0], None)

    def test_songs_of_the_same_notes_and_beat_are_told_apart(self):
        index = LandmarkIndex(os.path.join(self.folder.name, 'in-key.db'))
        self.addCleanup(index.connection.close)
        songs = {f'k{seed}': song(seed, 30, in_key=True) for seed in range(100, 130)}
        for track_id, samples in songs.items():
            index.add(track_id, 1.0, landmarks.landmarks(samples))
        for k, track_id in enumerate(['k103', 'k111', 'k127']):
            found, score, noise = index.match(through_a_room(songs[track_id][8 * RATE : 23 * RATE], k))
            self.assertEqual(found, track_id, f'{score} against {noise}')
        for seed in range(200, 215):
            found, score, noise = index.match(through_a_room(song(seed, 15, in_key=True), seed))
            self.assertIsNone(found, f'{seed} is not in the library: {score} against {noise}')

    def test_a_close_second_song_means_no_match(self):
        # Two songs line up by different hashes of the recording, 20 and 15: neither is clearly it.
        first, second = np.arange(2000, 2020, dtype=np.uint32), np.arange(3000, 3015, dtype=np.uint32)
        self.index.add('first', 1.0, (first, np.arange(500, 520, dtype=np.uint32)))
        self.index.add('second', 1.0, (second, np.arange(900, 915, dtype=np.uint32)))
        heard = (np.r_[first, second], np.r_[np.arange(20), np.arange(15)].astype(np.uint32))
        with patch('landmarks.landmarks', return_value=heard):
            self.assertEqual(self.index.match(np.zeros(RATE, dtype=np.float32))[:2], (None, 20))

    def test_repetitive_music_is_matched_within_bounds(self):
        tone = (0.5 * np.sin(2 * np.pi * 440 * np.arange(60 * RATE) / RATE)).astype(np.float32)
        tone += np.random.default_rng(3).normal(0, 0.01, len(tone)).astype(np.float32)
        for k in range(30):
            self.index.add(f'tone{k}', 1.0, landmarks.landmarks(tone))
        common = np.full(40, 4321, dtype=np.uint32)
        for k in range(30):
            self.index.add(f'common{k}', 1.0, (common, np.arange(40, dtype=np.uint32) + k))
        with patch('landmarks.MOST_VOTES', 2000), patch('landmarks.MOST_POSTINGS', 200):
            self.index.match(tone[: 15 * RATE])
            with patch('landmarks.landmarks', return_value=(common, np.arange(40, dtype=np.uint32))):
                self.assertEqual(self.index.match(np.zeros(RATE, dtype=np.float32)), (None, 0, 0),
                    'a hash in more places than that tells nothing')

    def test_a_held_note_does_not_use_up_the_votes(self):
        held = np.full(100, 5555, dtype=np.uint32)
        self.index.add('busy', 1.0, (held, np.arange(100, dtype=np.uint32)))
        real = np.arange(6000, 6020, dtype=np.uint32)
        self.index.add('real', 1.0, (real, np.arange(300, 500, 10, dtype=np.uint32)))
        # The held note's hash all through the recording, before the song's own.
        heard = (np.r_[np.full(40, 5555), real].astype(np.uint32), np.r_[np.arange(40), np.arange(0, 200, 10)].astype(np.uint32))
        with patch('landmarks.MOST_VOTES', 600), patch('landmarks.landmarks', return_value=heard):
            self.assertEqual(self.index.match(np.zeros(RATE, dtype=np.float32))[:2], ('real', 20))

    def test_a_count_cut_short_is_no_match(self):
        # The votes run out before all of the rival's hashes are counted.
        leader, rival = np.arange(7000, 7020, dtype=np.uint32), np.arange(8000, 8019, dtype=np.uint32)
        self.index.add('leader', 1.0, (leader, np.arange(400, 600, 10, dtype=np.uint32)))
        self.index.add('rival', 1.0, (rival, np.arange(700, 719, dtype=np.uint32)))
        heard = (np.r_[leader, rival], np.r_[np.arange(0, 200, 10), np.arange(19)].astype(np.uint32))
        with patch('landmarks.MOST_VOTES', 25), patch('landmarks.landmarks', return_value=heard):
            # Counted as if the rival it may have missed were as close: too alike to tell, so not by fingerprint either.
            self.assertEqual(self.index.match(np.zeros(RATE, dtype=np.float32)), (None, 20, 20))
        with patch('landmarks.landmarks', return_value=heard):
            self.assertEqual(self.index.match(np.zeros(RATE, dtype=np.float32)), (None, 20, 19), 'counted in full')

    def test_hashes_either_side_of_a_frame_count_together(self):
        # The rival's 30 hashes are a frame before and after one offset, none at it.
        leader, rival = np.arange(7000, 7040, dtype=np.uint32), np.arange(8000, 8030, dtype=np.uint32)
        self.index.add('leader', 1.0, (leader, np.arange(400, 440, dtype=np.uint32)))
        self.index.add('rival', 1.0, (rival, np.array([k + 99 + 2 * (k % 2) for k in range(30)], dtype=np.uint32)))
        heard = (np.r_[leader, rival], np.r_[np.arange(40), np.arange(30)].astype(np.uint32))
        with patch('landmarks.landmarks', return_value=heard):
            self.assertEqual(self.index.match(np.zeros(RATE, dtype=np.float32)), (None, 40, 30))

    def test_a_track_indexed_again_meanwhile_is_still_one_track(self):
        leader, rival = np.arange(7000, 7020, dtype=np.uint32), np.arange(8000, 8015, dtype=np.uint32)
        self.index.add('leader', 1.0, (leader, np.arange(400, 420, dtype=np.uint32)))
        marks = (rival, np.arange(700, 715, dtype=np.uint32))
        self.index.add('rival', 1.0, marks)
        heard = (np.r_[leader, rival], np.r_[np.arange(20), np.arange(15)].astype(np.uint32))
        connect, index = landmarks.sqlite3.connect, self.index

        class Reading:
            """A connection that, halfway through the rival's hashes, has the scan index the rival again."""

            def __init__(self, *args, **kwargs):
                self.connection, self.asked = connect(*args, **kwargs), 0

            def execute(self, sql, *args):
                if sql.startswith('SELECT ref'):
                    self.asked += 1
                    if self.asked == 28:
                        index.add('rival', 2.0, marks)
                return self.connection.execute(sql, *args)

            def close(self):
                self.connection.close()

        with patch('landmarks.landmarks', return_value=heard), patch('landmarks.sqlite3.connect', Reading):
            self.assertEqual(self.index.match(np.zeros(RATE, dtype=np.float32)), (None, 20, 15))
        self.assertFalse(self.index.current('rival', 1.0, 3), 'indexed again meanwhile')

    def test_a_track_is_scored_by_its_window_with_the_most_hashes_not_votes(self):
        leader = np.arange(7000, 7040, dtype=np.uint32)
        self.index.add('leader', 1.0, (leader, np.arange(400, 440, dtype=np.uint32)))
        # 30 hashes line up at one offset; at another, 16 hashes repeat three times over, 48 votes.
        lined_up, repeated = np.arange(9000, 9030, dtype=np.uint32), np.arange(9500, 9516, dtype=np.uint32)
        rival = (
            np.r_[lined_up, np.repeat(repeated, 3)].astype(np.uint32),
            np.r_[np.arange(900, 930), [200 + k + step for k in range(16) for step in (-1, 0, 1)]].astype(np.uint32),
        )
        self.index.add('rival', 1.0, rival)
        heard = (np.r_[leader, lined_up, repeated], np.r_[np.arange(40), np.arange(30), np.arange(16)].astype(np.uint32))
        with patch('landmarks.landmarks', return_value=heard):
            self.assertEqual(self.index.match(np.zeros(RATE, dtype=np.float32)), (None, 40, 30))

    def fingerprint(self, samples: np.ndarray) -> np.ndarray:
        with tempfile.NamedTemporaryFile(suffix='.wav', dir=self.folder.name, delete=False) as file:
            file.write(wav(samples, RATE))
        output = subprocess.run(['fpcalc', '-raw', '-json', '-length', '900', file.name], capture_output=True, check=True)
        return np.array(json.loads(output.stdout)['fingerprint'], dtype=np.int64).astype(np.uint32)

    def test_a_few_seconds_of_a_song_before_another_are_not_taken_for_it(self):
        clip = np.r_[self.songs['t3'][20 * RATE : 23 * RATE], song(99, 12)]
        found, score, noise = self.index.match(through_a_room(clip, 3))
        self.assertIsNone(found, f'{score} against {noise}')
        self.assertGreaterEqual(score, landmarks.LEAST_MATCHES, 'lined up, but over too little of the recording')
        # Nor by a stray hash or two from further on.
        found = np.arange(7000, 7032, dtype=np.uint32)
        frames = np.r_[np.arange(30), 300, 310].astype(np.uint32)
        self.index.add('sampled', 1.0, (found, frames + 500))
        with patch('landmarks.landmarks', return_value=(found, frames)):
            self.assertIsNone(self.index.match(np.zeros(RATE, dtype=np.float32))[0])

    def test_songs_that_only_share_an_intro_are_not_copies(self):
        intro = song(80, 25)
        first, second = np.r_[intro, song(81, 60)], np.r_[intro, song(82, 60)]
        self.index.add('first', 1.0, landmarks.landmarks(first))
        self.index.add('second', 1.0, landmarks.landmarks(second))
        prints = {'first': self.fingerprint(first), 'second': self.fingerprint(second)}
        # Their starts are the same recording; all through, they aren't.
        self.assertTrue(structure.same_recording(prints['first'], prints['second']))
        self.assertFalse(structure.same_throughout(prints['first'], prints['second']))
        alike = lambda a, b: structure.same_throughout(prints[a], prints[b])
        found, score, noise = self.index.match(through_a_room(intro[2 * RATE : 17 * RATE], 8), alike)
        self.assertIsNone(found, f'{score} against {noise}')
        # Past the intro, each is itself.
        self.assertEqual(self.index.match(through_a_room(second[40 * RATE : 55 * RATE], 9), alike)[0], 'second')

    def test_copies_are_told_by_the_fingerprints_the_scan_saved(self):
        import importlib
        self.addCleanup(sys.modules.pop, 'app', None)
        sys.modules.pop('app', None)
        with patch.dict(os.environ, {'DATA_DIR': self.folder.name, 'ADVANCED_ANALYSIS': 'false'}):
            application = importlib.import_module('app')
        database = application.db()
        self.addCleanup(database.close)
        recording = song(85, 90)
        for track_id, samples in (('album', recording), ('compilation', recording * 0.8), ('other', song(86, 90))):
            database.execute(
                'INSERT INTO tracks (id, path, mtime, fingerprint, duration, decoded) VALUES (?, ?, 1, ?, 90, 90)',
                (track_id, track_id, self.fingerprint(samples).tobytes()))
        # Longer than its fingerprint, which can't say what comes after, by the file or decoded; or of no known length.
        for track_id, duration, decoded in (('longer', 1000, 1000), ('longer-decoded', 795, 1015),
                                            ('unmeasured', None, None)):
            database.execute(
                'INSERT INTO tracks (id, path, mtime, fingerprint, duration, decoded) VALUES (?, ?, 1, ?, ?, ?)',
                (track_id, track_id, self.fingerprint(recording).tobytes(), duration, decoded))
        database.execute("INSERT INTO tracks (id, path, mtime) VALUES ('unanalyzed', 'x', 1)")
        for track_id in ('album', 'compilation', 'other', 'longer', 'longer-decoded', 'unmeasured', 'unanalyzed'):
            self.index.add(track_id, 1.0)
        # Its landmarks are of the file that replaced it, which isn't analyzed yet.
        database.execute(
            "INSERT INTO tracks (id, path, mtime, fingerprint, duration, decoded) VALUES ('replaced', 'r', 1, ?, 90, 90)",
            (self.fingerprint(recording).tobytes(),))
        self.index.add('replaced', 2.0)
        with patch.object(application, 'DB', database), patch.object(application, 'LANDMARKS', self.index):
            self.assertTrue(application.recorded_alike('album', 'compilation'))
            self.assertFalse(application.recorded_alike('album', 'other'))
            self.assertFalse(application.recorded_alike('album', 'longer'))
            self.assertFalse(application.recorded_alike('album', 'longer-decoded'))
            self.assertFalse(application.recorded_alike('album', 'replaced'))
            self.assertFalse(application.recorded_alike('album', 'unmeasured'))
            self.assertFalse(application.recorded_alike('album', 'unanalyzed'))

    def test_another_encoding_of_a_recording_is_the_same_all_through(self):
        recording = song(83, 90)
        again = np.roll(recording, 37) * 0.7 + np.random.default_rng(4).normal(0, 0.01, len(recording))
        self.assertTrue(structure.same_throughout(self.fingerprint(recording), self.fingerprint(again)))
        self.assertFalse(structure.same_throughout(self.fingerprint(recording), self.fingerprint(song(84, 90))))

    def test_a_version_with_a_different_ending_is_not_the_same_all_through(self):
        start = song(89, 50)
        first, second = np.r_[start, song(90, 10)], np.r_[start, song(91, 10)]
        self.assertFalse(structure.same_throughout(self.fingerprint(first), self.fingerprint(second)))
        # Nor one that ends on another go of the outro, where the other has a new ending: long enough that drift so late
        # could reach back past it.
        first = np.random.default_rng(5).integers(0, 2**32, 7000, dtype=np.uint64).astype(np.uint32)
        first[-64:] = first[-129:-65]
        second = first.copy()
        second[-64:] = np.random.default_rng(6).integers(0, 2**32, 64, dtype=np.uint64).astype(np.uint32)
        self.assertFalse(structure.same_throughout(first, second))
        self.assertTrue(structure.same_throughout(first, first.copy()))

    def test_passages_in_another_order_are_not_the_same_all_through(self):
        first = np.random.default_rng(10).integers(0, 2**32, 7000, dtype=np.uint64).astype(np.uint32)
        second = first.copy()
        second[6000:6060], second[6060:6120] = first[6060:6120], first[6000:6060]
        self.assertFalse(structure.same_throughout(first, second))
        # Drifting slowly, as from one transfer to another, they still are: here by two frames at a time, six in all.
        drifted = np.r_[first[:2000], first[1998:3000], first[2998:4000], first[3998:]]
        self.assertTrue(structure.same_throughout(first, drifted))

    def test_a_different_passage_inside_repeated_music_is_not_the_same_all_through(self):
        first = np.random.default_rng(7).integers(0, 2**32, 7000, dtype=np.uint64).astype(np.uint32)
        first[4500:5100] = np.tile(first[4480:4500], 30)
        second = first.copy()
        second[4800:4840] = np.random.default_rng(8).integers(0, 2**32, 40, dtype=np.uint64).astype(np.uint32)
        self.assertFalse(structure.same_throughout(first, second))
        self.assertFalse(structure.same_throughout(second, first))
        # Nor is one with more music after.
        recording = song(92, 180)
        self.assertFalse(structure.same_throughout(self.fingerprint(recording), self.fingerprint(np.r_[recording, song(93, 12)])))

    def test_a_version_with_a_different_section_is_not_the_same_all_through(self):
        recording = song(87, 180)
        version = recording.copy()
        version[30 * RATE : 55 * RATE] = song(88, 25)
        self.assertFalse(structure.same_throughout(self.fingerprint(recording), self.fingerprint(version)))

    def test_a_recording_on_many_compilations_still_matches(self):
        marks = landmarks.landmarks(self.songs['t1'])
        for k in range(8):
            self.index.add(f't1-copy{k}', 1.0, marks)
        alike = lambda a, b: a.split('-')[0] == b.split('-')[0]
        found = self.index.match(through_a_room(self.songs['t1'][20 * RATE : 35 * RATE], 4), alike)[0]
        self.assertTrue(found and found.startswith('t1'), found)
        # Without knowing they're copies, they're only rivals.
        self.assertIsNone(self.index.match(through_a_room(self.songs['t1'][20 * RATE : 35 * RATE], 4))[0])

    def test_another_copy_of_the_recording_still_matches(self):
        self.index.add('t2-again', 1.0, landmarks.landmarks(self.songs['t2']))
        clip = self.songs['t2'][10 * RATE : 22 * RATE]
        alike = lambda a, b: {a, b} == {'t2', 't2-again'}
        self.assertIn(self.index.match(through_a_room(clip, 9), alike)[0], {'t2', 't2-again'})

    def test_a_changed_track_is_indexed_again_and_a_removed_one_is_gone(self):
        before = self.rows()
        self.assertTrue(self.index.current('t1', 1.0, 3))
        self.assertFalse(self.index.current('t1', 2.0, 3))
        self.index.add('t1', 2.0, landmarks.landmarks(song(77)))
        clip = through_a_room(song(77)[5 * RATE : 17 * RATE], 1)
        self.assertEqual(self.index.match(clip)[0], 't1')
        old = through_a_room(self.songs['t1'][5 * RATE : 17 * RATE], 2)
        self.assertIsNone(self.index.match(old)[0], "the old recording's hashes are gone")
        self.index.remove(['t1', 'unknown'])
        self.assertIsNone(self.index.match(clip)[0])
        self.assertNotIn('t1', self.index.ids())
        self.assertLess(self.rows(), before)
        self.index.remove(list(self.index.ids()))
        self.assertEqual(self.rows(), 0)

    def test_hashes_a_frame_apart_count_together(self):
        # Half a recording's hashes line up a frame later than the rest, as when it starts mid-frame.
        found = np.arange(1000, 1024, dtype=np.uint32)
        track = (found, np.array([100 + 10 * k for k in range(24)], dtype=np.uint32))
        self.index.add('split', 1.0, track)
        heard = (found, np.array([10 * k + (k % 2) for k in range(24)], dtype=np.uint32))
        with patch('landmarks.landmarks', return_value=heard):
            self.assertEqual(self.index.match(np.zeros(RATE, dtype=np.float32))[0], 'split')

    def test_a_file_that_failed_is_tried_again_after_a_while(self):
        self.index.add('broken', 1.0, error='decode failed')
        self.assertTrue(self.index.current('broken', 1.0, 3))
        with patch('landmarks.time.time', return_value=10 ** 10):
            self.assertFalse(self.index.current('broken', 1.0, 3))
        self.assertEqual(self.index.indexed(), 6)

    def test_a_recording_file_is_decoded_and_found(self):
        recording = through_a_room(self.songs['t3'][30 * RATE : 45 * RATE], 5)
        with tempfile.NamedTemporaryFile(suffix='.wav', dir=self.folder.name, delete=False) as file:
            file.write(wav(np.repeat(recording, 2) * 2, RATE * 2))
        self.assertEqual(self.index.match(landmarks.decode(file.name, 60))[0], 't3')

    def test_the_scan_fills_the_index_without_analyzing_the_library_again(self):
        import importlib
        from contextlib import nullcontext
        self.addCleanup(sys.modules.pop, 'app', None)
        sys.modules.pop('app', None)
        with patch.dict(os.environ, {'DATA_DIR': self.folder.name, 'ADVANCED_ANALYSIS': 'false'}):
            application = importlib.import_module('app')
        tracks = {}
        for name, seed in (('a', 60), ('b', 61)):
            tracks[name] = os.path.join(self.folder.name, f'{name}.wav')
            with open(tracks[name], 'wb') as file:
                file.write(wav(song(seed, 20), RATE))
        database = application.db()
        self.addCleanup(database.close)
        database.execute(
            'INSERT INTO tracks (id, path, mtime, version) VALUES (?, ?, ?, ?)',
            ('a', tracks['a'], os.path.getmtime(tracks['a']), application.ANALYSIS_VERSION),
        )
        database.commit()
        index = LandmarkIndex(os.path.join(self.folder.name, 'scan.db'))
        self.addCleanup(index.connection.close)
        analyze = unittest.mock.Mock(return_value={'bpm': 120.0})
        indexed = unittest.mock.Mock(wraps=application.index_landmarks)
        with patch.object(application, 'DB', database), patch.object(application, 'LANDMARKS', index), \
                patch.object(application, 'library_tracks', lambda: dict(tracks)), \
                patch.object(application, 'analyze', analyze), patch.object(application, 'index_landmarks', indexed), \
                patch.object(application.RUNTIME, 'slot', lambda kind: nullcontext()), \
                patch.object(application.RUNTIME, 'prioritize', lambda items, key: list(items)):
            application.scan()
            # Only the new track is analyzed; both become recognizable.
            analyze.assert_called_once_with(tracks['b'])
            self.assertEqual(sorted(call.args[0] for call in indexed.call_args_list), ['a', 'b'])
            self.assertEqual(index.ids(), {'a', 'b'})
            clip = through_a_room(song(60, 20)[3 * RATE : 18 * RATE], 3)
            self.assertEqual(index.match(clip)[0], 'a')
            application.scan()
            self.assertEqual(analyze.call_count, 1)
            self.assertEqual(indexed.call_count, 2, 'nothing changed, so nothing is done again')
            del tracks['b']
            application.scan()
            self.assertEqual(index.ids(), {'a'})

    def test_identify_finds_the_song_by_its_landmarks(self):
        import importlib
        self.addCleanup(sys.modules.pop, 'app', None)
        sys.modules.pop('app', None)
        with patch.dict(os.environ, {'DATA_DIR': self.folder.name, 'ADVANCED_ANALYSIS': 'false'}):
            application = importlib.import_module('app')
        recording = wav(through_a_room(self.songs['t5'][12 * RATE : 27 * RATE], 6), RATE)
        # None of these are copies of each other.
        alike = patch.object(application, 'recorded_alike', lambda a, b: False)
        with alike, patch.object(application, 'LANDMARKS', self.index), patch.object(application, 'match_fingerprint') as old:
            self.assertEqual(application.identify_recording(recording)['id'], 't5')
            old.assert_not_called()
        # On an album and a compilation: either will do.
        self.index.add('t5-again', 1.0, landmarks.landmarks(self.songs['t5']))
        copies = patch.object(application, 'recorded_alike', lambda a, b: {a, b} == {'t5', 't5-again'})
        with copies, patch.object(application, 'LANDMARKS', self.index), patch.object(application, 'match_fingerprint'):
            self.assertIn(application.identify_recording(recording)['id'], {'t5', 't5-again'})
        # Not known to be copies, they're too alike to tell apart, and the fingerprint isn't asked.
        with alike, patch.object(application, 'LANDMARKS', self.index), \
                patch.object(application, 'match_fingerprint', return_value=('not-yet-indexed', 0.0, 1.0)):
            self.assertIsNone(application.identify_recording(recording)['id'])
        with alike, patch.object(application, 'LANDMARKS', self.index), \
                patch.object(application, 'match_fingerprint', return_value=(None, 1.0, 0.0)) as old:
            self.assertIsNone(application.identify_recording(wav(song(50, 15), RATE))['id'])
            # Not yet in the landmark index: the fingerprint is still tried.
            old.assert_called_once()
        # Lined up with an indexed song over too little of the recording: the rest could be one not indexed yet.
        with alike, patch.object(application, 'LANDMARKS', self.index), \
                patch.object(self.index, 'match', return_value=(None, 30, 0)), \
                patch.object(application, 'match_fingerprint', return_value=('not-yet-indexed', 0.0, 1.0)):
            self.assertEqual(application.identify_recording(recording)['id'], 'not-yet-indexed')
        # Little lined up, and no rival close: the fingerprint has its say, of an indexed track as of any.
        unclear = wav(through_a_room(song(50, 15), 7), RATE)
        for found in ('not-yet-indexed', 't5'):
            with alike, patch.object(application, 'LANDMARKS', self.index), \
                    patch.object(application, 'match_fingerprint', return_value=(found, 0.0, 1.0)):
                self.assertEqual(application.identify_recording(unclear)['id'], found)


if __name__ == '__main__':
    unittest.main()
