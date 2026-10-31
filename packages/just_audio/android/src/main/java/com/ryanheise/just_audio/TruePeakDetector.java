package com.ryanheise.just_audio;

/** Four-phase interpolation from ITU-R BS.1770-5 Annex 2. Detector only: audio
 * samples, their rate, and their order never pass through the interpolation.
 * https://www.itu.int/rec/R-REC-BS.1770
 */
final class TruePeakDetector {
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

    TruePeakDetector(int channels) { history = new double[channels][TAPS * 2]; }

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
