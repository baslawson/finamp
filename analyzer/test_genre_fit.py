import unittest

import numpy as np

import genre_fit


def unit(*values):
    vector = np.array(values, dtype=np.float32)
    return vector / np.linalg.norm(vector)


# Axes: loud guitars, soft piano ballad, acoustic folk.
LOUD, BALLAD, FOLK = unit(1, 0, 0), unit(0, 1, 0), unit(0, 0, 1)


def near(direction, wobble, seed):
    noise = np.random.default_rng(seed).normal(0, wobble, 3).astype(np.float32)
    vector = direction + noise
    return vector / np.linalg.norm(vector)


class ContrastTests(unittest.TestCase):
    def test_a_genre_is_not_its_own_contrast(self):
        rock = genre_fit.contrasts_for("Rock")
        self.assertIn("a soft ballad with piano and gentle vocals", rock)
        self.assertNotIn("loud rock music with distorted electric guitars and drums", rock)

    def test_soft_styles_keep_their_ballads(self):
        soft_rock = genre_fit.contrasts_for("Soft Rock")
        self.assertNotIn("a soft ballad with piano and gentle vocals", soft_rock)
        self.assertNotIn("loud rock music with distorted electric guitars and drums", soft_rock)
        self.assertNotIn("a gentle acoustic guitar folk song", genre_fit.contrasts_for("Folk Rock"))

    def test_the_prompt_names_the_genre(self):
        self.assertEqual(genre_fit.genre_prompt(" Progressive Rock "), "Progressive Rock music")


class ScoreTests(unittest.TestCase):
    def pool(self):
        rockers = [near(LOUD, 0.15, seed) for seed in range(10)]
        ballads = [near(BALLAD, 0.15, 100 + seed) for seed in range(3)]
        return np.stack(rockers + ballads), len(rockers)

    def test_ballads_in_a_rock_pool_score_lowest(self):
        embeddings, rockers = self.pool()
        main = np.array([True] * rockers + [False] * 3)
        scores = genre_fit.scores(embeddings, main, LOUD, np.stack([BALLAD, FOLK]))
        self.assertEqual(len(scores), len(embeddings))
        self.assertLess(scores[rockers:].max(), scores[:rockers].min())
        # Relative to the pool: the typical song is around 0.
        self.assertAlmostEqual(float(scores.mean()), 0.0, places=5)

    def test_the_genre_sound_comes_from_main_tag_songs(self):
        embeddings, rockers = self.pool()
        # No description to go by, so only the genre's own sound counts.
        silent = np.zeros(3, dtype=np.float32)
        none = np.zeros((0, 3), dtype=np.float32)
        # The ballads and two rockers have the main tag: the centre leans to the ballads, which now beat the rest.
        main = np.array([False] * rockers + [True] * 3)
        main[:2] = True
        scores = genre_fit.scores(embeddings, main, silent, none)
        self.assertGreater(scores[rockers:].min(), scores[2:rockers].max())
        # Fewer than the minimum main-tag songs: the whole pool is the centre, and the rockers win.
        main = np.array([False] * rockers + [True] * 3)
        scores = genre_fit.scores(embeddings, main, silent, none)
        self.assertLess(scores[rockers:].max(), scores[:rockers].min())

    def test_too_small_a_pool_gets_no_scores(self):
        embeddings = np.stack([near(LOUD, 0.1, seed) for seed in range(genre_fit.MINIMUM_POOL - 1)])
        main = np.ones(len(embeddings), dtype=bool)
        self.assertIsNone(genre_fit.scores(embeddings, main, LOUD, np.stack([BALLAD])))

    def test_identical_songs_score_evenly(self):
        embeddings = np.stack([LOUD] * 10)
        scores = genre_fit.scores(embeddings, np.ones(10, dtype=bool), LOUD, np.stack([BALLAD]))
        np.testing.assert_allclose(scores, np.zeros(10))


class LearningTests(unittest.TestCase):
    def test_the_learner_tells_the_answers_apart(self):
        fits = np.stack([near(LOUD, 0.2, seed) for seed in range(4)])
        misfits = np.stack([near(BALLAD, 0.2, 50 + seed) for seed in range(6)])
        weights, bias = genre_fit.learn(fits, misfits)
        self.assertTrue(((fits @ weights + bias) > 0).all())
        self.assertTrue(((misfits @ weights + bias) < 0).all())
        # New songs that sound like the answers are judged the same way.
        self.assertGreater(float(near(LOUD, 0.2, 99) @ weights + bias), float(near(BALLAD, 0.2, 98) @ weights + bias))

    def test_answers_move_the_scores(self):
        embeddings = np.stack([near(LOUD, 0.15, seed) for seed in range(6)] + [near(FOLK, 0.15, 30 + seed) for seed in range(4)])
        main = np.ones(len(embeddings), dtype=bool)
        silent, none = np.zeros(3, dtype=np.float32), np.zeros((0, 3), dtype=np.float32)
        plain = genre_fit.scores(embeddings, main, silent, none)
        # The listener says folk songs elsewhere in the library are the genre and loud ones aren't.
        fits = np.stack([near(FOLK, 0.1, 70 + seed) for seed in range(3)])
        misfits = np.stack([near(LOUD, 0.1, 80 + seed) for seed in range(3)])
        taught = genre_fit.scores(embeddings, main, silent, none, fits, misfits)
        self.assertLess(plain[6:].mean(), plain[:6].mean())
        self.assertGreater(taught[6:].min(), taught[:6].max())


if __name__ == "__main__":
    unittest.main()
