import unittest

import numpy as np

import mashup as m


def track(key='C major', bpm=120.0, first=0.5, duration=200.0, **extra):
    """An analysed song with a steady beat from [first] to near its end."""
    period = 60 / bpm
    last = first + int((duration - 10 - first) / period) * period
    return {'key': key, 'beatBpm': bpm, 'bpm': bpm, 'firstBeat': first, 'lastBeat': last, 'duration': duration,
            'intro': 8.0, 'end': duration - 1, 'energy': -14.0, **extra}


class KeyTests(unittest.TestCase):
    def test_camelot_positions_match_the_analyzers_wheel(self):
        major = [8, 3, 10, 5, 12, 7, 2, 9, 4, 11, 6, 1]
        minor = [5, 12, 7, 2, 9, 4, 11, 6, 1, 8, 3, 10]
        self.assertEqual([m.camelot(t, True)[0] for t in range(12)], major)
        self.assertEqual([m.camelot(t, False)[0] for t in range(12)], minor)

    def test_keys_are_parsed_strictly(self):
        self.assertEqual(m.parse_key('C# minor'), (1, False))
        self.assertEqual(m.parse_key('A major'), (9, True))
        for text in [None, '', 'H major', 'C dorian', 'c major', 'C major ']:
            self.assertIsNone(m.parse_key(text))

    def test_relations(self):
        self.assertEqual(m.key_relation((0, True), (0, True)), 'same')
        self.assertEqual(m.key_relation((9, False), (0, True)), 'relative')  # A minor and C major
        self.assertEqual(m.key_relation((7, True), (0, True)), 'neighbour')  # G and C major
        self.assertIsNone(m.key_relation((7, False), (0, True)))  # G minor over C major
        self.assertIsNone(m.key_relation((6, True), (0, True)))

    def test_the_smallest_fitting_shift_wins_and_an_exact_key_beats_a_neighbour(self):
        self.assertEqual(m.best_shift((0, True), (0, True), 2)[:2], (0, 'same'))
        # D major over C major: down two semitones lands exactly; nothing nearer fits as well.
        self.assertEqual(m.best_shift((2, True), (0, True), 2)[:2], (-2, 'same'))
        # C# major over C major: down one is exact.
        self.assertEqual(m.best_shift((1, True), (0, True), 2)[:2], (-1, 'same'))
        # F# minor over C major only fits as A minor, three semitones up.
        self.assertIsNone(m.best_shift((6, False), (0, True), 2))
        self.assertEqual(m.best_shift((6, False), (0, True), 4)[:2], (3, 'relative'))


class TempoTests(unittest.TestCase):
    def test_half_and_double_time_count_as_the_same_beat(self):
        self.assertAlmostEqual(m.tempo_ratio(120, 126), 1.05)
        self.assertAlmostEqual(m.tempo_ratio(120, 61), 61 * 2 / 120)
        self.assertAlmostEqual(m.tempo_ratio(170, 88), 88 * 2 / 170)
        self.assertAlmostEqual(m.tempo_ratio(80, 158), 158 / 2 / 80)

    def test_the_grid_is_fitted_to_the_first_and_last_beat(self):
        # A tracker's 120.1 over a song that really runs at exactly 120 between its beats.
        first, period = m.beat_grid({'beatBpm': 120.1, 'firstBeat': 1.0, 'lastBeat': 1.0 + 300 * 0.5})
        self.assertEqual((first, period), (1.0, 0.5))
        self.assertEqual(m.beat_grid({'bpm': 100, 'firstBeat': 2.0}), (2.0, 0.6))
        self.assertIsNone(m.beat_grid({'bpm': 100}))
        self.assertIsNone(m.beat_grid({'firstBeat': 1}))


class PlanTests(unittest.TestCase):
    def test_a_close_pair_is_planned_with_its_grids(self):
        plan = m.plan(track('D major', 123), track('C major', 120, first=0.25))
        self.assertEqual((plan['semitones'], plan['key'], plan['warnings']), (-2, 'same', []))
        self.assertAlmostEqual(plan['tempo'], 120 / 123, places=4)
        self.assertEqual(plan['backing']['firstBeat'], 0.25)
        self.assertAlmostEqual(plan['backing']['period'], 0.5)
        self.assertEqual(plan['backing']['end'], 199)
        self.assertTrue(0 < plan['score'] < 1)

    def test_suggestions_have_tighter_limits_than_picks_which_warn(self):
        vocals, backing = track('F# minor', 132), track('C major', 120)
        with self.assertRaises(ValueError) as caught:
            m.plan(vocals, backing)
        self.assertIn('tempos', str(caught.exception))
        picked = m.plan(vocals, backing, suggest=False)
        self.assertEqual(picked['semitones'], 3)
        self.assertEqual(len(picked['warnings']), 2)
        with self.assertRaisesRegex(ValueError, 'tempos'):
            m.plan(track(bpm=145), backing, suggest=False)
        with self.assertRaisesRegex(ValueError, 'keys'):
            m.plan(track('D# minor'), backing, suggest=False)

    def test_songs_without_full_analysis_are_refused(self):
        for missing in ['key', 'firstBeat', 'duration']:
            with self.subTest(missing=missing), self.assertRaisesRegex(ValueError, 'analysed'):
                m.plan({**track(), missing: None}, track())

    def test_songs_too_long_for_the_karaoke_server_are_refused(self):
        import karaoke
        self.assertEqual(m.MAX_SECONDS, karaoke.MAX_SECONDS)
        long = track(duration=m.MAX_SECONDS + 100)
        for pair in [(long, track()), (track(), long)]:
            with self.subTest(pair=pair[0] is long), self.assertRaisesRegex(ValueError, '20 minutes'):
                m.plan(*pair, suggest=False)
        self.assertEqual(m.partners('a', {'a': track(), 'b': long}), [])
        m.plan(track(duration=m.MAX_SECONDS), track())

    def test_beats_the_karaoke_server_refuses_are_refused(self):
        import karaoke
        bounds = karaoke.MashupGrid.model_fields['period'].metadata
        self.assertEqual([m.MIN_PERIOD, m.MAX_PERIOD], [bounds[0].gt, bounds[1].lt])
        for bpm in [24, 30, 400, 500]:
            with self.subTest(bpm=bpm), self.assertRaisesRegex(ValueError, 'too slow or too fast'):
                m.plan(track(bpm=bpm), track(bpm=bpm))
        m.plan(track(bpm=31), track(bpm=31), suggest=False)

    def test_closer_pairs_score_higher(self):
        backing = track()
        same = m.plan(track(), backing)['score']
        shifted = m.plan(track('D major'), backing)['score']
        faster = m.plan(track(bpm=126), backing)['score']
        self.assertEqual(same, 1.0)
        self.assertGreater(same, shifted)
        self.assertGreater(same, faster)

    def test_partners_are_ranked_and_the_role_decides_who_sings(self):
        tracks = {'a': track('C major', 120), 'b': track('C major', 121), 'c': track('D major', 120),
                  'd': track('D# minor', 120), 'e': track(None)}
        found = m.partners('a', tracks)
        self.assertEqual([item['id'] for item in found], ['b', 'c'])
        self.assertEqual(found[1]['semitones'], 2)
        # The other way round, c's vocals come down two semitones to fit a's instrumental.
        self.assertEqual(m.partners('a', tracks, 'backing')[1]['semitones'], -2)
        self.assertEqual(m.partners('missing', tracks), [])
        self.assertEqual(len(m.partners('a', tracks, limit=1)), 1)


class IdeaTests(unittest.TestCase):
    def test_ideas_pair_each_seed_with_its_best_fits_either_way_round(self):
        tracks = {'a': track('C major', 120), 'b': track('C major', 121), 'c': track('A minor', 120),
                  'd': track('G major', 124), 'e': track('D# minor', 120), 'x': track('F# major', 90)}
        found = m.ideas(['a', 'a', 'missing', 'x'], tracks)
        # a's two best fits only (either way round); x fits nothing; a repeated seed counts once.
        self.assertEqual(len(found), 2)
        self.assertTrue(all('a' in (idea['vocals'], idea['backing']) for idea in found))
        self.assertEqual(found, sorted(found, key=lambda idea: -idea['score']))
        self.assertEqual(set(found[0]), {'vocals', 'backing', 'score', 'semitones', 'tempo', 'key'})
        self.assertEqual(len(m.ideas(['a', 'b', 'c'], tracks, limit=3)), 3)
        self.assertLessEqual(len(m.ideas(['a', 'b'], tracks, per_song=1)), 2)
        self.assertEqual(m.ideas([], tracks), [])

    def test_no_song_fills_the_ideas_even_when_the_seeds_fit_each_other(self):
        same = {song: track('C major', 120) for song in 'abcdef'}
        found = m.ideas(['a', 'b', 'c'], same)
        counts = {}
        for idea in found:
            for song in (idea['vocals'], idea['backing']):
                counts[song] = counts.get(song, 0) + 1
        self.assertTrue(found)
        self.assertLessEqual(max(counts.values()), 2)
        # Room left by a, b and c reaching their limit goes to the next best fits.
        self.assertEqual(len(found), 3)


class PlacementTests(unittest.TestCase):
    def test_singing_starts_where_most_of_the_next_seconds_are_sung(self):
        levels = np.full(400, -80.0)
        levels[50] = -10  # a breath
        levels[100:300] = -12
        levels[110:115] = -40  # a short gap inside the singing
        self.assertEqual(m.vocal_entry(levels, 0.05), 5.0)
        self.assertIsNone(m.vocal_entry(np.full(400, -80.0) + np.where(np.arange(400) % 50 == 0, 70, 0), 0.05))
        self.assertIsNone(m.vocal_entry([], 0.05))

    def test_the_first_sung_beat_lands_on_the_backing_singers_first_beat(self):
        plan = m.plan(track(bpm=126, first=0.3), track(bpm=120, first=0.25))
        tempo = plan['tempo']
        offset = m.placement(plan, 15.1, 16.4)
        sung = m.snap(15.1, plan['vocals']['firstBeat'], plan['vocals']['period'])
        target = m.snap(16.4, plan['backing']['firstBeat'], plan['backing']['period'])
        self.assertAlmostEqual(sung / tempo + offset, target, places=3)
        # Every later beat of the stretched vocals stays on one of the backing's beats.
        for beat in range(1, 200, 37):
            moved = (sung + beat * plan['vocals']['period']) / tempo + offset
            phase = (moved - plan['backing']['firstBeat']) / plan['backing']['period']
            self.assertAlmostEqual(phase, round(phase), places=2)

    def test_without_known_entries_the_intros_stand_in(self):
        plan = m.plan(track(), track())
        self.assertAlmostEqual(m.placement(plan, None, None), 0)
        self.assertLess(m.placement(plan, 20.0, None), 0)


if __name__ == '__main__': unittest.main()
