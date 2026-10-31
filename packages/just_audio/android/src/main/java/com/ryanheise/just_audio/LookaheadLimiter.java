package com.ryanheise.just_audio;

/** Channel-linked oversampled-peak limiter: 5 ms linear lookahead attack, 100 ms release.
 * Pure Java so impulses, tails and stereo linking can be tested without Android.
 * While disabled it only delays the audio: the costly true-peak detector waits, and catches up over the
 * lookahead (and the frames just before it) when protection is enabled, as if it had run all along.
 */
final class LookaheadLimiter {
    private final int channels, size;
    private final float[][] ring;
    private final double[] peaks;
    // The ceiling each waiting frame came with, and the drain's: the detector catches up with the ones it had then.
    private final double[] ceilings;
    private double drainCeiling;
    private final double release;
    private final TruePeakDetector truePeak;
    // The last frames to leave, oldest first from tailStart: the detector's history when it catches up.
    private final float[][] tail;
    private int tailStart, tailCount;
    // The detector has skipped frames since protection was last enabled; detectAlways never skips (for tests).
    private boolean detectorBehind;
    private final boolean detectAlways;
    // Extra allowance when reducing a real overshoot; never use this margin
    // to trigger limiting on audio whose measured true peak is already safe.
    private static final double PEAK_MARGIN = Math.pow(10, 0.6 / 20);
    private int latestSlot;
    private boolean drainedDetector;
    private int start, count;
    private double gain = 1;
    private double threshold = Double.NaN;
    private int over;
    double currentGain() { return gain; }

    LookaheadLimiter(int rate, int channels) { this(rate, channels, false); }

    LookaheadLimiter(int rate, int channels, boolean detectAlways) {
        this.channels = channels;
        this.detectAlways = detectAlways;
        tail = new float[TruePeakDetector.TAPS - 1][channels];
        size = Math.max(1, (int) Math.ceil(rate * 0.005)) + 1;
        ring = new float[size][channels];
        peaks = new double[size];
        ceilings = new double[size];
        release = Math.exp(-1.0 / (rate * 0.100));
        truePeak = new TruePeakDetector(channels);
    }
    boolean push(float[] frame, float[] output, double ceiling, boolean enabled) {
        updateThreshold(ceiling);
        int slot = (start + count) % size;
        System.arraycopy(frame, 0, ring[slot], 0, channels);
        double peak = 0;
        for (float sample : frame) peak = Math.max(peak, Math.abs(sample));
        peaks[slot] = peak;
        ceilings[slot] = ceiling;
        if (peak > ceiling) over++;
        count++;
        latestSlot = slot;
        if (enabled || detectAlways) {
            if (detectorBehind) catchUp(ceiling);
            else protectInterpolation(truePeak.push(frame), slot, 0, ceiling);
        } else {
            detectorBehind = true;
        }
        return count == size && pop(output, ceiling, enabled);
    }
    private void protectInterpolation(double peak, int slot, int padding, double ceiling) {
        if (peak <= ceiling) return;
        peak *= PEAK_MARGIN;
        // All contributing samples are still in the existing lookahead buffer.
        // Protect the full interpolation span, including its leading/trailing edges.
        for (int tap = padding; tap < TruePeakDetector.TAPS; tap++) {
            int distance = tap - padding;
            if (distance >= count) break;
            int index = (slot - distance + size) % size;
            if (peak > peaks[index]) {
                if (peaks[index] <= ceiling) over++;
                peaks[index] = peak;
            }
        }
    }
    boolean pop(float[] output, double ceiling, boolean enabled) {
        if (count == 0) return false;
        updateThreshold(ceiling);
        if ((enabled || detectAlways) && detectorBehind) catchUp(ceiling);
        if (count < size && !drainedDetector) {
            // Flush detector history without adding or losing any audio frames.
            // This is the final drain; the output processor creates a new
            // limiter on flush before the next stream can supply audio.
            // Disabled, the detector catches up on it too when enabled.
            drainCeiling = ceiling;
            if (enabled || detectAlways) drainDetector(ceiling);
            else detectorBehind = true;
            drainedDetector = true;
        }
        double goal = 1;
        if (enabled) {
            // Normal/Quiet with measured headroom usually need no limiting at
            // all. Skip the lookahead search unless the window has an overshoot.
            if (over > 0) {
                for (int offset = 0; offset < count; offset++) {
                    double peak = peaks[(start + offset) % size];
                    if (peak <= ceiling) continue;
                    double target = ceiling / peak;
                    goal = Math.min(goal, target + (1 - target) * offset / (size - 1.0));
                }
            }
        }
        // Disabling protection at hand-over must release the existing reduction,
        // rather than stepping straight to unity on an arbitrary waveform sample.
        gain = Math.min(goal, 1 - (1 - gain) * release);
        float[] frame = ring[start];
        for (int channel = 0; channel < channels; channel++) output[channel] = (float) (frame[channel] * gain);
        System.arraycopy(frame, 0, tail[(tailStart + tailCount) % tail.length], 0, channels);
        if (tailCount < tail.length) tailCount++;
        else tailStart = (tailStart + 1) % tail.length;
        if (peaks[start] > ceiling) over--;
        start = (start + 1) % size;
        count--;
        return true;
    }

    private void drainDetector(double ceiling) {
        for (int padding = 1; padding < TruePeakDetector.TAPS; padding++) {
            protectInterpolation(truePeak.push(null), latestSlot, padding, ceiling);
        }
    }

    /** Runs the detector afresh over the frames just gone and those waiting, as it would have run on each as it came. Only
     * frames still waiting can be protected, so that's all it needs: those before them only fill its history. */
    private void catchUp(double ceiling) {
        truePeak.reset();
        for (int i = 0; i < tailCount; i++) truePeak.push(tail[(tailStart + i) % tail.length]);
        int waiting = count;
        for (int i = 0; i < waiting; i++) {
            int slot = (start + i) % size;
            double peak = 0;
            for (float sample : ring[slot]) peak = Math.max(peak, Math.abs(sample));
            peaks[slot] = peak;
        }
        // Each frame protects only frames before it that were waiting with it, as when pushed.
        for (int i = 0; i < waiting; i++) {
            count = i + 1;
            int slot = (start + i) % size;
            protectInterpolation(truePeak.push(ring[slot]), slot, 0, ceilings[slot]);
        }
        count = waiting;
        if (drainedDetector) drainDetector(drainCeiling);
        threshold = Double.NaN;
        updateThreshold(ceiling);
        detectorBehind = false;
    }

    private void updateThreshold(double ceiling) {
        if (threshold == ceiling) return;
        threshold = ceiling;
        over = 0;
        for (int i = 0; i < count; i++) if (peaks[(start + i) % size] > ceiling) over++;
    }
}
