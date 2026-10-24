"""How much songs sound like a genre, from their CLAP embeddings.

Genre tags describe an artist or an album, not each song: a band's ballad carries the same "Rock" tag as its
loudest single. Two checks find the songs that don't sound like the genre:

* the genre's own sound: the average embedding of the songs whose main tag is the genre (or of all of them when
  too few are), so songs far from it stand out;
* a description check, as in vibe search: "<genre> music" against contrasting styles (a soft ballad, acoustic
  folk, ...), leaving out the contrasts the genre itself names (Soft Rock keeps its ballads).

Both are scaled within the pool and averaged, so a score is relative: above 0 fits better than most of the pool.
"""

import numpy as np

# Contrasting styles, with the words in a genre name that make each one part of the genre rather than a contrast.
CONTRASTS = {
    "a soft ballad with piano and gentle vocals": ("soft", "ballad", "piano", "easy", "lounge", "adult"),
    "a gentle acoustic guitar folk song": ("acoustic", "folk", "singer", "songwriter", "unplugged", "americana"),
    "loud rock music with distorted electric guitars and drums": (
        "rock", "punk", "grunge", "metal", "alternative", "indie", "garage", "hardcore",
    ),
    "heavy metal with screamed vocals": ("metal", "hardcore", "thrash", "doom", "core"),
    "upbeat pop music": ("pop", "disco", "schlager"),
    "hip hop with rap vocals and beats": ("hip", "hop", "rap", "trap", "grime", "r&b", "rnb"),
    "electronic dance music with synthesizers": (
        "electr", "dance", "house", "techno", "trance", "edm", "synth", "disco", "drum", "dubstep", "club",
    ),
    "jazz with saxophone and swing": ("jazz", "swing", "bebop", "big band", "lounge"),
    "classical orchestral music": ("classical", "orchestra", "symphon", "opera", "baroque", "soundtrack", "score"),
    "country music with twang and steel guitar": ("country", "americana", "bluegrass", "western"),
    "reggae with offbeat rhythm": ("reggae", "ska", "dub", "dancehall"),
    "soul and funk with groove": ("soul", "funk", "r&b", "rnb", "motown", "disco"),
    "ambient atmospheric music": ("ambient", "chill", "new age", "atmospheric", "downtempo"),
}

# The fewest analysed songs that give a meaningful scale; smaller pools get no scores.
MINIMUM_POOL = 8
# The fewest main-tag songs for the genre's sound to come from them alone.
MINIMUM_CORE = 5


def contrasts_for(genre: str) -> list[str]:
    """The contrasting styles for [genre]: all but those its name belongs to."""
    name = genre.lower()
    return [text for text, words in CONTRASTS.items() if not any(word in name for word in words)]


def genre_prompt(genre: str) -> str:
    return f"{genre.strip()} music"


def _standardise(values: np.ndarray) -> np.ndarray:
    spread = values.std()
    return (values - values.mean()) / spread if spread > 1e-6 else np.zeros_like(values)


def scores(
    embeddings: np.ndarray,
    main: np.ndarray,
    genre_embedding: np.ndarray,
    contrast_embeddings: np.ndarray,
    fits: np.ndarray | None = None,
    misfits: np.ndarray | None = None,
) -> np.ndarray | None:
    """A fit score per row of [embeddings] (unit vectors), or None when the pool is too small to judge.

    [main] marks the rows whose main tag is the genre; [contrast_embeddings] may be empty. [fits] and [misfits] are
    the embeddings of songs the listener said are and aren't the genre, anywhere in the library: the genre's sound
    leans towards the first and away from the second, and with enough of both a learner trained on them joins in.
    """
    if len(embeddings) < MINIMUM_POOL:
        return None
    fits = _rows(fits, embeddings)
    misfits = _rows(misfits, embeddings)
    core = embeddings[main] if main.sum() >= MINIMUM_CORE else embeddings
    # A song the listener vouched for counts as much as several tagged ones.
    centre = _unit(core.sum(axis=0) + LABEL_WEIGHT * fits.sum(axis=0))
    sound = embeddings @ centre
    if len(misfits):
        sound = sound - MISFIT_PULL * (embeddings @ _unit(misfits.mean(axis=0)))
    described = embeddings @ genre_embedding
    if len(contrast_embeddings):
        described = described - (embeddings @ contrast_embeddings.T).max(axis=1)
    parts = [_standardise(sound), _standardise(described)]
    if len(fits) >= MINIMUM_LABELS and len(misfits) >= MINIMUM_LABELS:
        weights, bias = learn(fits, misfits)
        parts.append(_standardise(embeddings @ weights + bias))
    return sum(parts) / len(parts)


# How much a song the listener said fits counts towards the genre's sound, against one tagged song.
LABEL_WEIGHT = 3.0
# How much sounding like the songs the listener turned down counts against a song.
MISFIT_PULL = 0.5
# The fewest answers each way before a learner is trained on them.
MINIMUM_LABELS = 3


def learn(fits: np.ndarray, misfits: np.ndarray, steps: int = 300, rate: float = 0.5, ridge: float = 0.01):
    """A small logistic regression that tells [fits] from [misfits]; returns (weights, bias). Each side counts the
    same however many answers it has, and the ridge keeps a handful of answers from being learned by heart."""
    features = np.concatenate([fits, misfits]).astype(np.float64)
    target = np.concatenate([np.ones(len(fits)), np.zeros(len(misfits))])
    balance = np.concatenate([np.full(len(fits), 0.5 / len(fits)), np.full(len(misfits), 0.5 / len(misfits))])
    weights, bias = np.zeros(features.shape[1]), 0.0
    for _ in range(steps):
        predicted = 1 / (1 + np.exp(-(features @ weights + bias)))
        error = (predicted - target) * balance
        weights -= rate * (features.T @ error + ridge * weights)
        bias -= rate * error.sum()
    return weights.astype(np.float32), float(bias)


def _rows(values: np.ndarray | None, like: np.ndarray) -> np.ndarray:
    return values if values is not None and len(values) else np.zeros((0, like.shape[1]), dtype=like.dtype)


def _unit(vector: np.ndarray) -> np.ndarray:
    return vector / max(float(np.linalg.norm(vector)), 1e-9)
