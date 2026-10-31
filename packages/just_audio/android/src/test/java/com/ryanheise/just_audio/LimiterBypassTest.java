package com.ryanheise.just_audio;

import java.util.Random;

/** Disabled, the limiter skips its true-peak detector; enabled again, it must limit exactly as one that never skipped. */
public final class LimiterBypassTest {
    public static void main(String[] args) {
        int cases = 0;
        for (int rate : new int[] {44100, 48000}) {
            for (int channels : new int[] {1, 2}) {
                int lookahead = (int) Math.ceil(rate * 0.005) + 1;
                // Frame indices where protection turns on and off: at the start, inside the detector's 12 taps, at
                // the lookahead's edges, and late; for one frame, for less than the taps, and for longer.
                int[][] switches = {
                    {}, {0}, {1}, {5}, {11}, {12}, {13}, {lookahead - 1}, {lookahead}, {lookahead + 1}, {3000},
                    {0, 1}, {0, 5}, {0, 11}, {0, 12}, {100, 101}, {100, 111}, {100, 400}, {400, 401, 402, 403},
                    {10, 20, 30, 40, 50, 60}, {2000, 2000 + lookahead, 2001 + lookahead},
                };
                for (int[] at : switches) {
                    for (boolean onFirst : new boolean[] {false, true}) {
                        // The drain is reached with protection on, off, turned on part-way through it, or switched to and fro.
                        for (int drain : new int[] {0, 1, 2, 3}) {
                            for (long seed = 1; seed <= 3; seed++) {
                                // The ceiling held, or moved (as EQ headroom does) between -1 and -7 dB.
                                for (boolean moving : new boolean[] {false, true}) {
                                    compare(rate, channels, at, onFirst, drain, seed, moving);
                                    cases++;
                                }
                            }
                        }
                    }
                }
            }
        }
        System.out.println("Limiter bypass: " + cases + " on/off patterns limit exactly as an always-detecting limiter");
    }

    private static void compare(int rate, int channels, int[] at, boolean onFirst, int drain, long seed, boolean moving) {
        float[][] input = signal(rate, channels, seed);
        double high = Math.pow(10, -1 / 20.0), low = Math.pow(10, -7 / 20.0);
        double ceiling = high;
        LookaheadLimiter lazy = new LookaheadLimiter(rate, channels);
        LookaheadLimiter always = new LookaheadLimiter(rate, channels, true);
        float[] lazyOut = new float[channels], alwaysOut = new float[channels];
        int next = 0;
        boolean enabled = onFirst;
        for (int frame = 0; frame < input.length; frame++) {
            if (moving && frame % 333 == 0) ceiling = ceiling == high ? low : high;
            while (next < at.length && at[next] == frame) {
                enabled = !enabled;
                next++;
            }
            boolean a = lazy.push(input[frame], lazyOut, ceiling, enabled);
            boolean b = always.push(input[frame], alwaysOut, ceiling, enabled);
            assert a == b : "frame produced by one limiter only";
            if (a) same(lazyOut, alwaysOut, lazy, always, "frame " + frame + describe(at, onFirst, drain, rate, channels));
        }
        int popped = 0;
        while (true) {
            boolean on = drain == 0 ? true : drain == 1 ? false : drain == 2 ? popped >= 7 : popped % 3 == 0;
            if (moving && popped % 50 == 25) ceiling = ceiling == high ? low : high;
            boolean a = lazy.pop(lazyOut, ceiling, on);
            boolean b = always.pop(alwaysOut, ceiling, on);
            assert a == b : "drained differently";
            if (!a) break;
            same(lazyOut, alwaysOut, lazy, always, "drain " + popped + describe(at, onFirst, drain, rate, channels));
            popped++;
        }
    }

    private static void same(float[] a, float[] b, LookaheadLimiter lazy, LookaheadLimiter always, String where) {
        for (int channel = 0; channel < a.length; channel++) {
            assert Float.floatToIntBits(a[channel]) == Float.floatToIntBits(b[channel])
                : where + ": " + a[channel] + " instead of " + b[channel];
        }
        assert lazy.currentGain() == always.currentGain() : where + ": gain " + lazy.currentGain() + " instead of " + always.currentGain();
    }

    private static String describe(int[] at, boolean onFirst, int drain, int rate, int channels) {
        return " (switches " + java.util.Arrays.toString(at) + ", on first " + onFirst + ", drain " + drain + ", " + rate
            + " Hz, " + channels + " channels)";
    }

    /** Tones whose inter-sample peaks exceed the ceiling, bursts over it, stretches between the ceilings and quiet ones,
     * with a little noise. */
    private static float[][] signal(int rate, int channels, long seed) {
        Random random = new Random(seed);
        float[][] frames = new float[rate / 10][channels];
        for (int i = 0; i < frames.length; i++) {
            // Each seed ends at another level: quiet, between the two ceilings, near the higher one, or over it.
            int stretch = (int) ((i / 700 + seed) % 4);
            double level = stretch == 0 ? .2 : stretch == 1 ? .8 : stretch == 2 ? .95 : 1.3;
            for (int channel = 0; channel < channels; channel++) {
                double tone = Math.sin(2 * Math.PI * .25 * i + Math.PI / 4 + channel);
                frames[i][channel] = (float) (level * tone + .02 * random.nextGaussian());
            }
        }
        return frames;
    }
}
