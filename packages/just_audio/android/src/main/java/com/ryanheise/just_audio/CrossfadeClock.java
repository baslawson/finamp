package com.ryanheise.just_audio;

/** Maps the sink's media timestamps to the part of the incoming song already heard. */
final class CrossfadeClock {
    private long streamTimeUs;
    private long overlapUs;

    void onStream(long mediaTimeUs, long overlapUs) {
        // Media3 anchors its clock to each new stream's presentation timestamp.
        // That anchor already absorbs earlier dropped samples: adding their
        // corrections again advances the clock further with every crossfade.
        // Media3 also uses a queued anchor while draining the preceding output,
        // so retire the old correction as soon as that anchor is known.
        this.streamTimeUs = mediaTimeUs;
        this.overlapUs = overlapUs;
    }

    long positionUs(long sinkPositionUs) {
        return sinkPositionUs < streamTimeUs ? sinkPositionUs : sinkPositionUs + overlapUs;
    }

    void clear() {
        streamTimeUs = 0;
        overlapUs = 0;
    }
}
