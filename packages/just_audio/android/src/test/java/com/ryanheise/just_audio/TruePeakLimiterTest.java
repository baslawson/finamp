package com.ryanheise.just_audio;

import java.util.Locale;

/** Known inter-sample peaks, arbitrary end points, linked stereo and bypass. */
public final class TruePeakLimiterTest {
    public static void main(String[] args) {
        for (int rate : new int[] {44100, 48000, 96000}) {
            for (double frequency : new double[] {.1, .2, .25, .35, .45}) {
                for (int phase = 0; phase < 8; phase++) {
                    run(rate, frequency, phase * Math.PI / 8, true);
                }
            }
            run(rate, .25, Math.PI / 4, false);
        }
        peakCappedNormalization();
        realOvershoots();
        quietSkip();
        System.out.println("True-peak limiter: phase-shifted tones, stereo, tails, exact bypass, peak-capped normalization, real overshoots and the quiet-audio detector skip passed at three rates");
    }

    /** The detector may skip its filters only where it can't matter: when the true peak is within the ceiling anyway. */
    private static void quietSkip() {
        double ceiling = Math.pow(10, -1.0 / 20);
        // The worst case for each phase: samples whose signs follow its coefficients add up to amplitude * sum |c|.
        for (double[] phase : TruePeakDetector.FILTER) {
            double sum = 0;
            for (double coefficient : phase) sum += Math.abs(coefficient);
            float amplitude = (float) (ceiling / (sum * 0.995));
            TruePeakDetector fast = new TruePeakDetector(2), exact = new TruePeakDetector(2);
            double peak = 0;
            for (int age = TruePeakDetector.TAPS - 1; age >= 0; age--) {
                float sample = phase[age] < 0 ? -amplitude : amplitude;
                float[] frame = {sample, sample};
                peak = sameDecision(fast.push(frame, ceiling), exact.push(frame), ceiling);
            }
            assert peak > ceiling : "fixture must reach over the ceiling only between samples";
        }
        // Noise around the threshold, at several ceilings: quiet stretches must be skipped, the rest must not change.
        java.util.Random random = new java.util.Random(3);
        int skipped = 0;
        for (double limit : new double[] {ceiling, Math.pow(10, -7.0 / 20), 1}) {
            TruePeakDetector fast = new TruePeakDetector(2), exact = new TruePeakDetector(2);
            for (int i = 0; i < 200_000; i++) {
                double level = (i / 1000) % 4 == 0 ? 1.1 : (i / 1000) % 4 == 1 ? .45 : .2;
                float[] frame = i % 5000 == 4999 ? null
                        : new float[] {(float) (random.nextGaussian() * level / 3), (float) (random.nextGaussian() * level / 3)};
                double a = fast.push(frame, limit), b = frame == null ? exact.push(null) : exact.push(frame);
                sameDecision(a, b, limit);
                if (a != b) skipped++;
            }
        }
        assert skipped > 100_000 : "quiet audio should skip the filters, skipped " + skipped;
    }

    private static double sameDecision(double fast, double exact, double ceiling) {
        assert fast == exact || (fast <= ceiling && exact <= ceiling)
                : "skipped a true peak of " + exact + " over the ceiling " + ceiling + " (reported " + fast + ")";
        return exact;
    }

    private static void peakCappedNormalization() {
        boolean transparent = true;
        for (int rate : new int[] {44100, 48000, 96000}) {
            // Quiet and Normal both cap the upstream gain at -1 dBTP minus
            // the EQ reserve. Their post-gain native limiter settings are identical.
            for (String mode : new String[] {"Quiet", "Normal"}) {
                for (double reserve : new double[] {0, 6}) {
                    double ceiling = Math.pow(10, (-1 - reserve) / 20);
                    float[][] input = toneAtPeak(rate, ceiling);
                    double inputPeak = measure(input);
                    assert inputPeak <= ceiling : "fixture exceeds ceiling";
                    // Irrational dB ceilings cannot be represented exactly by
                    // float PCM. Stay on the safe side within float precision.
                    assert Math.abs(20 * Math.log10(inputPeak / ceiling)) < .000002;
                    Result result = limit(input, rate, ceiling);
                    System.out.printf(Locale.ROOT,
                        "%s, %d Hz, reserve %.0f dB: input %.6f dBTP, min gain %.9f (%.6f dB), output %.6f dBTP%n",
                        mode, rate, reserve, 20 * Math.log10(inputPeak), result.minimumGain,
                        20 * Math.log10(result.minimumGain), 20 * Math.log10(result.peak));
                    transparent &= result.unchanged && result.minimumGain == 1;
                    // Being just below the ceiling must also stay transparent,
                    // including peaks inside the old 0.6 dB margin.
                    Result below = limit(toneAtPeak(rate, ceiling * Math.pow(10, -.1 / 20)), rate, ceiling);
                    transparent &= below.unchanged && below.minimumGain == 1;
                    // Also exercise exact equality in double, independently
                    // of rounding the nominal dB ceiling into float PCM.
                    Result exact = limit(input, rate, inputPeak);
                    transparent &= exact.unchanged && exact.minimumGain == 1;
                }
            }
        }
        assert transparent : "peak-capped Quiet/Normal audio was limited at or below its ceiling";
    }

    private static void realOvershoots() {
        for (int rate : new int[] {44100, 48000, 96000}) {
            for (double reserve : new double[] {0, 6}) {
                double ceiling = Math.pow(10, (-1 - reserve) / 20);
                for (double excessDb : new double[] {.001, .1, 6}) {
                    float[][] input = toneAtPeak(rate, ceiling * Math.pow(10, excessDb / 20));
                    assert measure(input) > ceiling : "fixture has no overshoot";
                    if (excessDb < 1) {
                        // These cannot be caught by a sample-peak-only limiter.
                        for (float[] frame : input) for (float sample : frame) assert Math.abs(sample) < ceiling;
                    }
                    Result result = limit(input, rate, ceiling);
                    assert result.minimumGain < 1 : "real inter-sample overshoot was ignored";
                    assert result.peak <= ceiling * 1.00001 : "overshoot escaped: " + 20 * Math.log10(result.peak / ceiling) + " dB";
                }
            }
        }
    }

    private static float[][] toneAtPeak(int rate, double wantedPeak) {
        float[][] input = new float[rate / 10 + 7][2];
        for (int i = 0; i < input.length; i++) {
            double envelope = Math.min(1, Math.min(i, input.length - i - 1) / (rate * .005));
            float value = (float) (envelope * Math.sin(2 * Math.PI * .25 * i + Math.PI / 4));
            input[i][0] = value;
            input[i][1] = -value / 2;
        }
        double scale = wantedPeak / measure(input);
        for (float[] frame : input) for (int ch = 0; ch < 2; ch++) frame[ch] = (float) (frame[ch] * scale);
        // Rounding to float can put the result a fraction of an ulp above the
        // ceiling. Move at most a few float steps toward zero, then remeasure.
        for (int attempt = 0; measure(input) > wantedPeak; attempt++) {
            assert attempt < 4 : "could not normalize fixture";
            for (float[] frame : input) for (int ch = 0; ch < 2; ch++) frame[ch] = Math.nextAfter(frame[ch], 0);
        }
        return input;
    }

    private static double measure(float[][] input) {
        TruePeakDetector meter = new TruePeakDetector(2);
        double peak = 0;
        for (float[] frame : input) peak = Math.max(peak, meter.push(frame));
        for (int i = 0; i < TruePeakDetector.TAPS; i++) peak = Math.max(peak, meter.push(null));
        return peak;
    }

    private static Result limit(float[][] input, int rate, double ceiling) {
        LookaheadLimiter limiter = new LookaheadLimiter(rate, 2);
        float[][] output = new float[input.length][2];
        float[] frame = new float[2];
        int emitted = 0;
        for (float[] value : input) {
            if (limiter.push(value, frame, ceiling, true)) output[emitted++] = frame.clone();
        }
        while (limiter.pop(frame, ceiling, true)) output[emitted++] = frame.clone();
        assert emitted == input.length : "frame count changed";
        Result result = new Result();
        result.peak = measure(output);
        for (int i = 0; i < input.length; i++) {
            if (input[i][0] != 0) result.minimumGain = Math.min(result.minimumGain, (double) output[i][0] / input[i][0]);
            for (int ch = 0; ch < 2; ch++) result.unchanged &= output[i][ch] == input[i][ch];
            assert Math.abs(output[i][1] + output[i][0] / 2) < .000001 : "stereo image changed";
        }
        return result;
    }

    private static final class Result {
        double minimumGain = 1, peak;
        boolean unchanged = true;
    }

    private static void run(int rate, double frequency, double phase, boolean enabled) {
        double ceiling = Math.pow(10, -1.0 / 20);
        LookaheadLimiter limiter = new LookaheadLimiter(rate, 2);
        TruePeakDetector meter = new TruePeakDetector(2);
        float[] output = new float[2];
        int length = rate / 20 + 7, emitted = 0;
        double peak = 0;
        for (int frame = 0; frame < length; frame++) {
            // Smooth ends avoid testing a discontinuity introduced by the fixture.
            double envelope = Math.min(1, Math.min(frame, length - frame - 1) / (rate * .005));
            float value = (float) (1.3 * envelope * Math.sin(2 * Math.PI * frequency * frame + phase));
            if (limiter.push(new float[] {value, -value / 2}, output, ceiling, enabled)) {
                peak = Math.max(peak, meter.push(output));
                assert Math.abs(output[1] + output[0] / 2) < .000001 : "stereo image changed";
                if (!enabled) {
                    double originalEnvelope = Math.min(1, Math.min(emitted, length - emitted - 1) / (rate * .005));
                    float original = (float) (1.3 * originalEnvelope * Math.sin(2 * Math.PI * frequency * emitted + phase));
                    assert original == output[0] : "bypass changed frame " + emitted;
                }
                emitted++;
            }
        }
        while (limiter.pop(output, ceiling, enabled)) {
            peak = Math.max(peak, meter.push(output));
            emitted++;
        }
        for (int i = 0; i < TruePeakDetector.TAPS; i++) peak = Math.max(peak, meter.push(null));
        assert emitted == length : "frame count changed";
        if (enabled) assert peak <= ceiling * 1.01 : "true peak exceeded ceiling: " + peak + " at " + rate;
        else assert peak > 1 : "fixture did not contain inter-sample peaks";
    }
}
