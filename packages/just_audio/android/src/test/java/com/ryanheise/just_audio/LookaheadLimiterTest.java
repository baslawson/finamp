package com.ryanheise.just_audio;

/** Standalone regression harness: javac LookaheadLimiter.java LookaheadLimiterTest.java; java -ea ... */
public final class LookaheadLimiterTest {
    public static void main(String[] args) {
        for (int rate : new int[] {8000, 44100, 48000, 96000}) {
            smoothDisable(rate);
            int length = rate / 5;
            float[][] input = new float[length][2];
            for (int i = 0; i < length; i++) {
                input[i][0] = (float) (0.2 * Math.sin(i * 0.1));
                input[i][1] = input[i][0] * 0.5f;
            }
            input[length / 2][0] = 4;
            input[length / 2][1] = 2;
            input[length - 1][0] = 0.31f;
            input[length - 1][1] = 0.155f;
            float[][] output = run(rate, input, true);
            assert output.length == length : "tail lost at " + rate;
            double ceiling = Math.pow(10, -1.0 / 20);
            for (int i = 0; i < length; i++) {
                assert Math.abs(output[i][0]) <= ceiling + 0.000001 : "overshoot";
                assert Math.abs(output[i][0] * 0.5 - output[i][1]) < 0.000001 : "stereo image changed";
            }
            assert output[length - 1][0] != 0 : "last frame clipped off";
            float[][] bypass = run(rate, input, false);
            for (int i = 0; i < length; i++) assert bypass[i][0] == input[i][0] : "bypass altered audio";
            float[][] shortInput = {{0.12f, -0.12f}};
            assert run(rate, shortInput, true)[0][0] == 0.12f : "short stream lost";
        }
        System.out.println("Limiter: impulse ceiling, stereo linking, bypass, tail and short-stream checks passed at four rates");
    }
    private static void smoothDisable(int rate) {
        LookaheadLimiter limiter = new LookaheadLimiter(rate, 2);
        float[] frame = new float[2];
        double ceiling = Math.pow(10, -1.0 / 20);
        float previous = 0;
        boolean disabled = false;
        int emitted = 0;
        for (int i = 0; i < rate + rate / 20; i++) {
            float left = i == rate / 100 ? 2 : .4f;
            boolean enabled = i < rate / 50;
            if (!limiter.push(new float[] {left, left / 2}, frame, ceiling, enabled)) continue;
            emitted++;
            if (!enabled) {
                if (!disabled) assert previous < .3f : "test did not reduce gain before disabling";
                assert Math.abs(frame[0] - previous) < .01 : "limiter clicked when disabled at " + rate;
                assert Math.abs(frame[1] - frame[0] / 2) < .000001;
                disabled = true;
            }
            previous = frame[0];
        }
        while (limiter.pop(frame, ceiling, false)) emitted++;
        assert emitted == rate + rate / 20 : "disable lost samples";
        assert Math.abs(frame[0] - .4f) < .0001 : "gain did not recover";
    }
    private static float[][] run(int rate, float[][] input, boolean enabled) {
        LookaheadLimiter limiter = new LookaheadLimiter(rate, 2);
        float[][] output = new float[input.length][2];
        float[] frame = new float[2];
        double ceiling = Math.pow(10, -1.0 / 20);
        int index = 0;
        for (float[] sample : input) {
            if (limiter.push(sample, frame, ceiling, enabled)) output[index++] = frame.clone();
        }
        while (limiter.pop(frame, ceiling, enabled)) output[index++] = frame.clone();
        assert index == input.length;
        return output;
    }
}
