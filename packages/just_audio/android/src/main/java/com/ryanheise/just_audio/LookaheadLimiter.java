package com.ryanheise.just_audio;

/** Channel-linked oversampled-peak limiter: 5 ms linear lookahead attack, 100 ms release.
 * Pure Java so impulses, tails and stereo linking can be tested without Android.
 */
final class LookaheadLimiter {
    private final int channels, size;
    private final float[][] ring;
    private final double[] peaks;
    private final double release;
    private final TruePeakDetector truePeak;
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

    LookaheadLimiter(int rate, int channels) {
        this.channels = channels;
        size = Math.max(1, (int) Math.ceil(rate * 0.005)) + 1;
        ring = new float[size][channels];
        peaks = new double[size];
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
        if (peak > ceiling) over++;
        count++;
        latestSlot = slot;
        protectInterpolation(truePeak.push(frame), slot, 0, ceiling);
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
        if (count < size && !drainedDetector) {
            // Flush detector history without adding or losing any audio frames.
            // This is the final drain; the output processor creates a new
            // limiter on flush before the next stream can supply audio.
            for (int padding = 1; padding < TruePeakDetector.TAPS; padding++) {
                protectInterpolation(truePeak.push(null), latestSlot, padding, ceiling);
            }
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
        if (peaks[start] > ceiling) over--;
        start = (start + 1) % size;
        count--;
        return true;
    }

    private void updateThreshold(double ceiling) {
        if (threshold == ceiling) return;
        threshold = ceiling;
        over = 0;
        for (int i = 0; i < count; i++) if (peaks[(start + i) % size] > ceiling) over++;
    }
}
