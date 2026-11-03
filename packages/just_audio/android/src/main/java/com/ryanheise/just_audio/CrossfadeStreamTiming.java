package com.ryanheise.just_audio;

import androidx.media3.common.C;
import java.util.ArrayDeque;

/** Media-relative presentation time of PCM, independent of playback polling and sink buffering. */
final class CrossfadeStreamTiming {
    private long pendingUs = C.TIME_UNSET;
    private long anchorUs = C.TIME_UNSET;
    private long frames;
    boolean pumping;
    private static final class Segment {
        int frames;
        final boolean carrier;
        Segment(int frames, boolean carrier) { this.frames = frames; this.carrier = carrier; }
    }
    private final ArrayDeque<Segment> segments = new ArrayDeque<>();
    int queuedOwnFrames() {
        int frames = 0;
        for (Segment segment : segments) if (!segment.carrier) frames += segment.frames;
        return frames;
    }
    void tag(int count) { if (count > 0) segments.add(new Segment(count, pumping)); }
    boolean consumeTag(int count) {
        if (segments.isEmpty()) return pumping; // Direct PCM harnesses omit normalization.
        Segment segment = segments.peek();
        boolean carrier = segment.carrier;
        if (count > segment.frames) throw new IllegalStateException("PCM provenance crossed a buffer boundary");
        segment.frames -= count;
        if (segment.frames == 0) segments.remove();
        return carrier;
    }

    // The renderer subtracts its stream offset before forwarding the timestamp.
    // Retrying a blocked sink buffer only updates pendingUs; it never advances PCM time.
    void onBuffer(long mediaTimeUs) { pendingUs = mediaTimeUs; }

    long positionUs(int rate) {
        if (anchorUs == C.TIME_UNSET) anchorUs = pendingUs;
        return anchorUs == C.TIME_UNSET ? C.TIME_UNSET : anchorUs + frames * 1_000_000L / rate;
    }

    void advance(int count) { frames += count; }

    void flush() {
        anchorUs = C.TIME_UNSET;
        frames = 0;
        segments.clear();
    }
}
