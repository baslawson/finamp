package com.ryanheise.just_audio;

import androidx.media3.common.C;
import androidx.media3.common.audio.AudioProcessor.AudioFormat;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;

/** The main player must take on the incoming song's normalization at the hand-over, not when Flutter catches up. */
public final class CrossfadeNormalizationTest {
    private static final String MAIN = "normalization-main";
    private static final String NEXT = "normalization-next";
    private static final float LEVEL = 0.4f;

    public static void main(String[] args) throws Exception {
        for (int rate : new int[] {44100, 48000}) {
            for (int channels : new int[] {1, 2}) {
                for (double nextGainDb : new double[] {-6, 6}) {
                    for (boolean drained : new boolean[] {true, false}) {
                        handOver(new AudioFormat(rate, channels, C.ENCODING_PCM_16BIT), nextGainDb, drained);
                    }
                }
            }
        }
        CrossfadeBridge.disarm();
        NormalizationSettings.remove(MAIN);
        NormalizationSettings.remove(NEXT);
        System.out.println("Crossfade normalization: the incoming song's gain carries through the hand-over, with or without a drain, 6 dB apart either way");
    }

    private static void handOver(AudioFormat decoded, double nextGainDb, boolean drained) throws Exception {
        NormalizationSettings.set(MAIN, true, 0, 0);
        NormalizationSettings.set(NEXT, true, nextGainDb, 0);
        float nextGain = (float) Math.pow(10, nextGainDb / 20);

        NormalizationAudioProcessor normalization = new NormalizationAudioProcessor(MAIN);
        CrossfadeAudioProcessor crossfade = new CrossfadeAudioProcessor(MAIN);
        AudioFormat pcm = normalization.configure(decoded);
        normalization.flush();
        CrossfadeBridge.arm(MAIN, NEXT);
        crossfade.configure(pcm);
        crossfade.flush();
        CrossfadeBridge.onConfigure(NEXT, pcm);
        assert CrossfadeBridge.startMix() == 1;
        CrossfadeBridge.setGains(0, 1);

        // What the second player collected: the new song after its own normalization.
        int collected = pcm.sampleRate * 2;
        ByteBuffer ring = ByteBuffer.allocateDirect(collected * pcm.bytesPerFrame).order(ByteOrder.nativeOrder());
        for (int frame = 0; frame < collected; frame++) {
            for (int channel = 0; channel < pcm.channelCount; channel++) ring.putFloat(LEVEL * nextGain);
        }
        ring.flip();
        CrossfadeBridge.collect(ring, pcm);

        Level level = new Level();
        level.check(run(normalization, crossfade, decoded, pcm.sampleRate / 2, 0f)); // Silent end of the old song.

        assert CrossfadeBridge.markBoundary(MAIN);
        if (drained) {
            // A new stream format: the sink drains and flushes its processors before the new song's first sample.
            CrossfadeBridge.onQueueEndOfStream(MAIN);
            normalization.flush();
            crossfade.flush();
        }
        for (int i = 0; i < 40; i++) level.check(run(normalization, crossfade, decoded, pcm.sampleRate / 20, LEVEL));
        assert CrossfadeBridge.status() == CrossfadeBridge.DONE : "hand-over stalled";
        assert Math.abs(level.previous - LEVEL * nextGain) < 0.002f
                : "main player plays the new song at " + level.previous + ", collected at " + LEVEL * nextGain
                        + " (" + nextGainDb + " dB, drained " + drained + ")";
    }

    /** [frames] of decoded PCM16 at [value] through the main player's normalization and crossfade processors. */
    private static ByteBuffer run(NormalizationAudioProcessor normalization, CrossfadeAudioProcessor crossfade,
            AudioFormat decoded, int frames, float value) {
        ByteBuffer input = ByteBuffer.allocateDirect(frames * decoded.bytesPerFrame).order(ByteOrder.nativeOrder());
        for (int i = 0; i < frames * decoded.channelCount; i++) input.putShort((short) Math.round(value * 32768));
        input.flip();
        normalization.queueInput(input);
        crossfade.queueInput(normalization.getOutput());
        return crossfade.getOutput().order(ByteOrder.nativeOrder());
    }

    private static final class Level {
        float previous;

        void check(ByteBuffer output) {
            while (output.hasRemaining()) {
                float sample = output.getFloat();
                assert Math.abs(sample - previous) < 0.01f
                        : "level jumped from " + previous + " to " + sample + " at the hand-over (status "
                                + CrossfadeBridge.status() + ")";
                previous = sample;
            }
        }
    }
}
