package com.ryanheise.just_audio;

import java.util.Random;

/**
 * The limiter's output must stay bit-identical to its straightforward form (kept below as it was before it was made
 * faster): any speed-up of the detector or of the lookahead search that changes a single sample fails here.
 */
public final class LimiterEquivalenceTest {
    private static double lowestGain = 1;

    public static void main(String[] args) {
        Random random = new Random(11);
        int compared = 0;
        for (int rate : new int[] {8000, 44100, 48000, 96000}) {
            for (int channels : new int[] {1, 2}) {
                for (boolean detectAlways : new boolean[] {false, true}) {
                    compared += compare(random, rate, channels, detectAlways);
                }
            }
        }
        assert lowestGain < .5 : "fixture must make the limiter work hard, lowest gain " + lowestGain;
        System.out.println("Limiter equivalence: " + compared + " frames bit-identical to the reference (ceiling changes, toggles, drains) passed at four rates");
    }

    private static int compare(Random random, int rate, int channels, boolean detectAlways) {
        LookaheadLimiter limiter = new LookaheadLimiter(rate, channels, detectAlways);
        ReferenceLimiter reference = new ReferenceLimiter(rate, channels, detectAlways);
        float[] frame = new float[channels], a = new float[channels], b = new float[channels];
        double[] ceilings = {Math.pow(10, -1.0 / 20), Math.pow(10, -4.0 / 20), Math.pow(10, -7.0 / 20)};
        double ceiling = ceilings[0];
        boolean enabled = true;
        int frames = 0;
        for (int i = 0; i < rate * 3; i++) {
            if (i % (rate / 3) == 0) ceiling = ceilings[random.nextInt(ceilings.length)];
            if (i % (rate / 2) == rate / 4) enabled = random.nextInt(4) != 0;
            // Quiet, loud and in-between stretches, with tones whose true peaks fall between samples.
            double level = (i / (rate / 10)) % 3 == 0 ? 1.3 : (i / (rate / 10)) % 3 == 1 ? .2 : .7;
            for (int channel = 0; channel < channels; channel++) {
                double tone = Math.sin(i * Math.PI / 2 + Math.PI / 4 + channel) * level;
                frame[channel] = (float) (i % 7 == 0 ? random.nextGaussian() * level : tone);
            }
            boolean x = limiter.push(frame, a, ceiling, enabled), y = reference.push(frame, b, ceiling, enabled);
            assert x == y : "output timing changed";
            if (x) frames += same(a, b, i);
            assert limiter.currentGain() == reference.currentGain() : "gain changed at frame " + i;
            lowestGain = Math.min(lowestGain, limiter.currentGain());
        }
        while (true) {
            boolean x = limiter.pop(a, ceiling, enabled), y = reference.pop(b, ceiling, enabled);
            assert x == y : "drain length changed";
            if (!x) break;
            frames += same(a, b, -1);
        }
        return frames;
    }

    private static int same(float[] a, float[] b, int at) {
        for (int channel = 0; channel < a.length; channel++) {
            assert Float.floatToRawIntBits(a[channel]) == Float.floatToRawIntBits(b[channel])
                    : "sample changed at frame " + at + ": " + a[channel] + " vs " + b[channel];
        }
        return 1;
    }

    // ---- The reference: the limiter and detector as they were before being optimized. ----

    /** Channel-linked oversampled-peak limiter: 5 ms linear lookahead attack, 100 ms release.
     * Pure Java so impulses, tails and stereo linking can be tested without Android.
     * While disabled it only delays the audio: the costly true-peak detector waits, and catches up over the
     * lookahead (and the frames just before it) when protection is enabled, as if it had run all along.
     */
    static final class ReferenceLimiter {
        private final int channels, size;
        private final float[][] ring;
        private final double[] peaks;
        // The ceiling each waiting frame came with, and the drain's: the detector catches up with the ones it had then.
        private final double[] ceilings;
        private double drainCeiling;
        private final double release;
        private final ReferenceDetector truePeak;
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

        ReferenceLimiter(int rate, int channels) { this(rate, channels, false); }

        ReferenceLimiter(int rate, int channels, boolean detectAlways) {
            this.channels = channels;
            this.detectAlways = detectAlways;
            tail = new float[ReferenceDetector.TAPS - 1][channels];
            size = Math.max(1, (int) Math.ceil(rate * 0.005)) + 1;
            ring = new float[size][channels];
            peaks = new double[size];
            ceilings = new double[size];
            release = Math.exp(-1.0 / (rate * 0.100));
            truePeak = new ReferenceDetector(channels);
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
            for (int tap = padding; tap < ReferenceDetector.TAPS; tap++) {
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
            for (int padding = 1; padding < ReferenceDetector.TAPS; padding++) {
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

    /** Four-phase interpolation from ITU-R BS.1770-5 Annex 2. Detector only: audio
     * samples, their rate, and their order never pass through the interpolation.
     * https://www.itu.int/rec/R-REC-BS.1770
     */
    static final class ReferenceDetector {
        static final int TAPS = 12;
        private static final double[][] FILTER = {
            { .0017089843750, .0109863281250, -.0196533203125, .0332031250000, -.0594482421875,
              .1373291015625, .9721679687500, -.1022949218750, .0476074218750, -.0266113281250,
              .0148925781250, -.0083007812500 },
            { -.0291748046875, .0292968750000, -.0517578125000, .0891113281250, -.1665039062500,
              .4650878906250, .7797851562500, -.2003173828125, .1015625000000, -.0582275390625,
              .0330810546875, -.0189208984375 },
            { -.0189208984375, .0330810546875, -.0582275390625, .1015625000000, -.2003173828125,
              .7797851562500, .4650878906250, -.1665039062500, .0891113281250, -.0517578125000,
              .0292968750000, -.0291748046875 },
            { -.0083007812500, .0148925781250, -.0266113281250, .0476074218750, -.1022949218750,
              .9721679687500, .1373291015625, -.0594482421875, .0332031250000, -.0196533203125,
              .0109863281250, .0017089843750 },
        };
        private final double[][] history;
        private int head;

        ReferenceDetector(int channels) { history = new double[channels][TAPS * 2]; }

        /** Back to silence, as new. */
        void reset() {
            for (double[] samples : history) java.util.Arrays.fill(samples, 0);
            head = 0;
        }

        /** Null advances the interpolation through end-of-stream zero padding. */
        double push(float[] frame) {
            head = (head + TAPS - 1) % TAPS;
            double peak = 0;
            for (int channel = 0; channel < history.length; channel++) {
                double[] samples = history[channel];
                double value = frame == null ? 0 : frame[channel];
                samples[head] = samples[head + TAPS] = value;
                peak = Math.max(peak, Math.abs(value));
                for (double[] phase : FILTER) {
                    double sum = 0;
                    for (int tap = 0; tap < TAPS; tap++) sum += phase[tap] * samples[head + tap];
                    peak = Math.max(peak, Math.abs(sum));
                }
            }
            return peak;
        }
    }
}
