package com.ryanheise.just_audio;

import androidx.media3.common.C;
import androidx.media3.common.audio.AudioProcessor.AudioFormat;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;

/** Checks the actual mixed samples when incoming decoding starts late or arrives in bursts. */
public final class CrossfadeMixTest {
    public static void main(String[] args) {
        for (int rate : new int[] {44100, 48000, 96000}) {
            for (int channels : new int[] {1, 2}) {
                for (int encoding : new int[] {C.ENCODING_PCM_16BIT, C.ENCODING_PCM_FLOAT}) {
                    AudioFormat format = new AudioFormat(rate, channels, encoding);
                    lateStart(format);
                    interruptedInput(format);
                }
            }
        }
        CrossfadeBridge.disarm();
        System.out.println("Crossfade mix: late startup, depleted buffers, recovery and stereo continuity passed for PCM16/float at three rates");
    }

    private static void start(AudioFormat format) {
        CrossfadeBridge.arm("mix-main", "mix-next");
        CrossfadeBridge.onConfigure("mix-main", format);
        CrossfadeBridge.onConfigure("mix-next", format);
        assert CrossfadeBridge.startMix() == 1;
        CrossfadeBridge.setGains(0, 0.5);
    }

    private static void lateStart(AudioFormat format) {
        start(format);
        collect(format, format.sampleRate / 20); // 50 ms: not enough to prime the decoder.
        ByteBuffer silence = mix(format, format.sampleRate / 5);
        while (silence.hasRemaining()) assert read(silence, format) == 0;
        collect(format, format.sampleRate / 5);
        checkContinuity(mix(format, format.sampleRate / 10), format, 0, "late incoming start");
    }

    private static void interruptedInput(AudioFormat format) {
        start(format);
        collect(format, format.sampleRate / 5);
        checkContinuity(mix(format, format.sampleRate / 3), format, 0, "incoming buffer depletion");
        collect(format, format.sampleRate / 5);
        checkContinuity(mix(format, format.sampleRate / 10), format, 0, "incoming buffer recovery");
    }

    private static void collect(AudioFormat format, int frames) {
        ByteBuffer input = buffer(format, frames);
        for (int frame = 0; frame < frames; frame++) {
            for (int channel = 0; channel < format.channelCount; channel++) {
                float sample = channel == 0 ? 0.8f : -0.4f;
                if (format.encoding == C.ENCODING_PCM_FLOAT) input.putFloat(sample);
                else input.putShort((short) Math.round(sample * 32768));
            }
        }
        input.flip();
        CrossfadeBridge.collect(input, format);
    }

    private static ByteBuffer mix(AudioFormat format, int frames) {
        ByteBuffer output = buffer(format, frames);
        assert CrossfadeBridge.mix(buffer(format, frames), output, format);
        output.flip();
        return output;
    }

    private static ByteBuffer buffer(AudioFormat format, int frames) {
        return ByteBuffer.allocateDirect(frames * format.bytesPerFrame).order(ByteOrder.nativeOrder());
    }

    private static float read(ByteBuffer input, AudioFormat format) {
        return format.encoding == C.ENCODING_PCM_FLOAT ? input.getFloat() : input.getShort() / 32768f;
    }

    private static void checkContinuity(ByteBuffer output, AudioFormat format, float previous, String phase) {
        float peak = 0;
        while (output.hasRemaining()) {
            float left = read(output, format);
            assert Float.isFinite(left);
            assert Math.abs(left - previous) < 0.01f : phase + ": click of " + Math.abs(left - previous)
                    + " at " + format;
            previous = left;
            peak = Math.max(peak, Math.abs(left));
            if (format.channelCount == 2) {
                float right = read(output, format);
                assert Math.abs(right + left * 0.5f) < 0.0001 : "stereo image changed";
            }
        }
        assert Math.abs(peak - 0.4f) < 0.001 : phase + ": incoming audio missing or changed";
    }
}
