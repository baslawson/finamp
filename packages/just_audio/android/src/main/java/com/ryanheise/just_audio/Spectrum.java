package com.ryanheise.just_audio;

import java.util.ArrayDeque;
import java.util.Collections;
import java.util.Set;
import java.util.WeakHashMap;

/**
 * Finamp+ visualizer: the loudness of {@link #BANDS} frequency bands of what's playing, measured in the audio
 * chain (no microphone needed). Each player analyses its own audio; reading combines them.
 */
public final class Spectrum {
    public static final int BANDS = 32;

    /** Audio is analysed before it reaches the speaker buffer, so frames are held back about this long. */
    private static final long LATENCY_NANOS = 300_000_000L;

    private static volatile boolean enabled;
    private static final Set<Analyzer> analyzers = Collections.newSetFromMap(new WeakHashMap<>());

    private Spectrum() {}

    public static void setEnabled(boolean value) {
        enabled = value;
    }

    public static boolean isEnabled() {
        return enabled;
    }

    static void register(Analyzer analyzer) {
        synchronized (analyzers) {
            analyzers.add(analyzer);
        }
    }

    /** The current band levels from 0 to 1, low to high frequencies. */
    public static double[] read() {
        double[] result = new double[BANDS];
        long now = System.nanoTime();
        synchronized (analyzers) {
            for (Analyzer analyzer : analyzers) {
                float[] frame = analyzer.due(now);
                if (frame == null) continue;
                for (int i = 0; i < BANDS; i++) result[i] = Math.max(result[i], frame[i]);
            }
        }
        return result;
    }

    /** Collects one player's samples and turns every 512 of them into band levels. */
    static final class Analyzer {
        private static final int SIZE = 1024;
        private static final int HOP = 512;

        private final float[] ring = new float[SIZE];
        private final float[] window = new float[SIZE];
        private final double[] re = new double[SIZE];
        private final double[] im = new double[SIZE];
        private int filled;
        private int sinceLast;
        private int sampleRate = 44100;
        private final ArrayDeque<Long> times = new ArrayDeque<>();
        private final ArrayDeque<float[]> frames = new ArrayDeque<>();
        private float[] shown;
        private long shownAt;

        Analyzer() {
            for (int i = 0; i < SIZE; i++) window[i] = (float) (0.5 - 0.5 * Math.cos(2 * Math.PI * i / (SIZE - 1)));
            register(this);
        }

        void configure(int sampleRate) {
            this.sampleRate = sampleRate;
            reset();
        }

        void reset() {
            filled = 0;
            sinceLast = 0;
            synchronized (this) {
                times.clear();
                frames.clear();
            }
        }

        void add(float sample) {
            ring[filled % SIZE] = sample;
            filled++;
            if (filled >= 1 << 30) filled = SIZE + filled % SIZE; // keep the index from overflowing
            if (++sinceLast >= HOP && filled >= SIZE) {
                sinceLast = 0;
                float[] bands = analyse();
                synchronized (this) {
                    // Frames are made ahead of playback: keep each one until it's heard.
                    times.addLast(System.nanoTime() + LATENCY_NANOS);
                    frames.addLast(bands);
                    while (frames.size() > 200) {
                        times.removeFirst();
                        frames.removeFirst();
                    }
                }
            }
        }

        /** The newest frame that should be heard by now, or null when this player is quiet or stopped. */
        synchronized float[] due(long now) {
            while (!times.isEmpty() && times.peekFirst() <= now) {
                times.removeFirst();
                shown = frames.removeFirst();
                shownAt = now;
            }
            if (shown == null || now - shownAt > 250_000_000L) return null;
            return shown;
        }

        private float[] analyse() {
            int start = filled - SIZE;
            for (int i = 0; i < SIZE; i++) {
                re[i] = ring[(start + i) % SIZE] * window[i];
                im[i] = 0;
            }
            fft(re, im);
            float[] bands = new float[BANDS];
            double low = 40;
            double high = Math.min(16000, sampleRate / 2.0);
            double ratio = Math.pow(high / low, 1.0 / BANDS);
            double binWidth = (double) sampleRate / SIZE;
            for (int band = 0; band < BANDS; band++) {
                double from = low * Math.pow(ratio, band);
                double to = from * ratio;
                int first = Math.max(1, (int) Math.floor(from / binWidth));
                int last = Math.max(first, Math.min(SIZE / 2 - 1, (int) Math.ceil(to / binWidth)));
                double energy = 0;
                for (int bin = first; bin <= last; bin++) {
                    energy = Math.max(energy, re[bin] * re[bin] + im[bin] * im[bin]);
                }
                // A Hann-windowed full-scale sine peaks at SIZE / 4.
                double magnitude = Math.sqrt(energy) / (SIZE / 4.0);
                double decibels = 20 * Math.log10(magnitude + 1e-9);
                // Treble is naturally quieter: tilt it up so the bars look even.
                decibels += 9.0 * band / BANDS;
                bands[band] = (float) Math.max(0, Math.min(1, (decibels + 60) / 54));
            }
            return bands;
        }

        private static void fft(double[] re, double[] im) {
            int n = re.length;
            for (int i = 1, j = 0; i < n; i++) {
                int bit = n >> 1;
                for (; (j & bit) != 0; bit >>= 1) j ^= bit;
                j ^= bit;
                if (i < j) {
                    double t = re[i];
                    re[i] = re[j];
                    re[j] = t;
                    t = im[i];
                    im[i] = im[j];
                    im[j] = t;
                }
            }
            for (int length = 2; length <= n; length <<= 1) {
                double angle = -2 * Math.PI / length;
                double wRe = Math.cos(angle);
                double wIm = Math.sin(angle);
                for (int i = 0; i < n; i += length) {
                    double curRe = 1;
                    double curIm = 0;
                    for (int k = 0; k < length / 2; k++) {
                        int a = i + k;
                        int b = a + length / 2;
                        double tRe = re[b] * curRe - im[b] * curIm;
                        double tIm = re[b] * curIm + im[b] * curRe;
                        re[b] = re[a] - tRe;
                        im[b] = im[a] - tIm;
                        re[a] += tRe;
                        im[a] += tIm;
                        double nextRe = curRe * wRe - curIm * wIm;
                        curIm = curRe * wIm + curIm * wRe;
                        curRe = nextRe;
                    }
                }
            }
        }
    }
}
