package com.ryanheise.just_audio;

import androidx.media3.common.C;
import androidx.media3.common.audio.AudioProcessor.AudioFormat;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;

/** Checks audible sample continuity and frame ordering through the native decoder hand-over. */
public final class CrossfadeHandoverTest {
    private static final String MAIN = "handover-main";
    private static final String NEXT = "handover-next";

    public static void main(String[] args) throws Exception {
        for (int rate : new int[] {44100, 48000, 96000}) {
            for (int channels : new int[] {1, 2}) {
                for (int encoding : new int[] {C.ENCODING_PCM_16BIT, C.ENCODING_PCM_FLOAT}) {
                    AudioFormat format = new AudioFormat(rate, channels, encoding);
                    gainAtBoundary(format, 0.5);
                    gainAtBoundary(format, 1.5);
                    refillAtBoundary(format);
                    depletionAtBoundary(format);
                    decoderLevelChange(format);
                    shortDecoderBlend(format);
                    drainedBoundary(format);
                    tinyBuffers(format);
                    frameOrder(format);
                }
            }
        }
        CrossfadeBridge.disarm();
        System.out.println("Crossfade handover: gain continuity, starvation/refill, tiny buffers and exact frame order passed for PCM16/float at three rates");
    }

    private static void gainAtBoundary(AudioFormat format, double gain) throws Exception {
        Harness h = new Harness(format, gain, false);
        h.collect(format.sampleRate * 2);
        h.check(h.outgoing(format.sampleRate / 5));
        h.boundary();
        h.check(h.incoming(format.sampleRate / 20));
        assert CrossfadeBridge.status() == CrossfadeBridge.CATCHING_UP;
        CrossfadeBridge.setGains(1, 0); // A delayed Flutter tick mustn't restart the fade.
        h.check(h.incoming(format.sampleRate / 2));
        h.finish();
    }

    private static void refillAtBoundary(AudioFormat format) throws Exception {
        Harness h = new Harness(format, 1, false);
        h.collect(format.sampleRate / 5);
        h.check(h.outgoing(format.sampleRate / 3)); // Drains the ring and fades to silence.
        h.collect(format.sampleRate / 10);
        h.boundary();
        h.check(h.incoming(format.sampleRate / 2));
        h.finish();
    }

    private static void depletionAtBoundary(AudioFormat format) throws Exception {
        Harness h = new Harness(format, 1, false);
        h.collect(format.sampleRate / 5);
        h.check(h.outgoing(format.sampleRate / 10));
        h.boundary();
        h.check(h.incoming(format.sampleRate / 2));
        h.finish();
    }

    private static void tinyBuffers(AudioFormat format) throws Exception {
        Harness h = new Harness(format, 0.5, false);
        h.collect(format.sampleRate / 5);
        h.check(h.outgoing(format.sampleRate / 3));
        h.boundary();
        // Smoothing must survive buffer boundaries, including after the main decoder catches up.
        for (int i = 0; i < format.sampleRate / 2; i++) h.check(h.incoming(1));
        h.finish();
    }

    private static void decoderLevelChange(AudioFormat format) throws Exception {
        Harness h = new Harness(format, 1, false);
        h.collect(format.sampleRate * 2);
        h.check(h.outgoing(format.sampleRate / 5));
        h.mainLevel = 0.5f;
        h.boundary();
        h.check(h.incoming(format.sampleRate / 2));
        h.finish();
    }

    private static void shortDecoderBlend(AudioFormat format) throws Exception {
        Harness h = new Harness(format, 1, false);
        h.collect(format.sampleRate / 5);
        h.check(h.outgoing(format.sampleRate / 10));
        h.mainLevel = 0.5f;
        h.boundary();
        // Only about 2 ms remain in the ring when the main decoder catches up.
        h.check(h.incoming(format.sampleRate * 392 / 1000));
        h.finish();
    }

    private static void drainedBoundary(AudioFormat format) throws Exception {
        Harness h = new Harness(format, 0.5, false);
        h.collect(format.sampleRate * 2);
        h.check(h.outgoing(format.sampleRate / 5));
        assert CrossfadeBridge.markBoundary(MAIN);
        CrossfadeBridge.onQueueEndOfStream(MAIN);
        h.check(h.outgoing(format.sampleRate / 100)); // Held-back tail is still the old song.
        assert CrossfadeBridge.status() == CrossfadeBridge.MIXING;
        CrossfadeBridge.onFlush(MAIN);
        h.check(h.incoming(format.sampleRate / 2));
        h.finish();
    }

    private static void frameOrder(AudioFormat format) throws Exception {
        Harness h = new Harness(format, 1, true);
        h.collect(format.sampleRate * 2);
        int overlap = format.sampleRate / 5;
        h.outgoing(overlap);
        h.boundary();
        long expectedFrame = overlap;
        int[] chunks = {1, 17, 512, 2048, 137};
        for (int i = 0; i < 200; i++) {
            ByteBuffer output = h.incoming(chunks[i % chunks.length]);
            while (output.hasRemaining()) {
                for (int channel = 0; channel < format.channelCount; channel++) {
                    float expected = quantize(h.sample(expectedFrame, channel), format);
                    float actual = read(output, format);
                    assert Math.abs(actual - expected) < 0.00004f : "repeated, skipped or changed frame "
                            + expectedFrame + " at " + format + ": " + actual + " vs " + expected;
                }
                expectedFrame++;
            }
        }
        assert CrossfadeBridge.status() == CrossfadeBridge.DONE : "hand-over stalled at " + format;
        assert expectedFrame == h.ownFrame : "decoder positions differ after hand-over";
    }

    private static final class Harness {
        final AudioFormat format;
        final CrossfadeAudioProcessor processor = new CrossfadeAudioProcessor(MAIN);
        final boolean patterned;
        long written;
        long ownFrame;
        float previous;
        float mainLevel = 1f;

        Harness(AudioFormat format, double gain, boolean patterned) throws Exception {
            this.format = format;
            this.patterned = patterned;
            CrossfadeBridge.arm(MAIN, NEXT);
            processor.configure(format);
            processor.flush();
            CrossfadeBridge.onConfigure(NEXT, format);
            assert CrossfadeBridge.startMix() == 1;
            CrossfadeBridge.setGains(0, gain);
        }

        float sample(long frame, int channel) {
            // Distinct adjacent frames expose dropped/repeated PCM, even across tiny buffers.
            float left = patterned ? (((frame * 1103515245L + 12345) & 65535) - 32768) / 131072f : 0.4f;
            return channel == 0 ? left : -left * 0.5f;
        }

        void collect(int frames) {
            ByteBuffer input = buffer(frames);
            for (int frame = 0; frame < frames; frame++) {
                for (int channel = 0; channel < format.channelCount; channel++) {
                    put(input, sample(written + frame, channel));
                }
            }
            input.flip();
            CrossfadeBridge.collect(input, format);
            written += frames;
        }

        ByteBuffer outgoing(int frames) {
            processor.queueInput(buffer(frames)); // Silent tail of the old song.
            return processor.getOutput().order(ByteOrder.nativeOrder());
        }

        void boundary() {
            assert CrossfadeBridge.markBoundary(MAIN);
            CrossfadeBridge.onQueueEndOfStream(MAIN);
            CrossfadeBridge.onFlush(MAIN);
        }

        ByteBuffer incoming(int frames) {
            ByteBuffer input = buffer(frames);
            for (int frame = 0; frame < frames; frame++) {
                for (int channel = 0; channel < format.channelCount; channel++) {
                    put(input, sample(ownFrame + frame, channel) * mainLevel);
                }
            }
            ownFrame += frames;
            input.flip();
            processor.queueInput(input);
            assert !input.hasRemaining() : "input not consumed";
            return processor.getOutput().order(ByteOrder.nativeOrder());
        }

        void check(ByteBuffer output) {
            while (output.hasRemaining()) {
                float left = read(output, format);
                assert Float.isFinite(left);
                assert Math.abs(left - previous) < 0.01f : "hand-over click of " + Math.abs(left - previous)
                        + " at " + format + ", status " + CrossfadeBridge.status();
                previous = left;
                if (format.channelCount == 2) {
                    assert Math.abs(read(output, format) + left * 0.5f) < 0.0001f : "stereo image changed";
                }
            }
        }

        void finish() {
            check(incoming(format.sampleRate / 5));
            assert CrossfadeBridge.status() == CrossfadeBridge.DONE : "hand-over stalled at " + format;
            assert Math.abs(previous - 0.4f * mainLevel) < 0.0001f : "main audio didn't return to its original level";
        }

        ByteBuffer buffer(int frames) {
            return ByteBuffer.allocateDirect(frames * format.bytesPerFrame).order(ByteOrder.nativeOrder());
        }

        void put(ByteBuffer buffer, float sample) {
            if (format.encoding == C.ENCODING_PCM_FLOAT) buffer.putFloat(sample);
            else buffer.putShort((short) Math.round(sample * 32768));
        }
    }

    private static float quantize(float sample, AudioFormat format) {
        return format.encoding == C.ENCODING_PCM_FLOAT ? sample : Math.round(sample * 32768) / 32768f;
    }

    private static float read(ByteBuffer input, AudioFormat format) {
        return format.encoding == C.ENCODING_PCM_FLOAT ? input.getFloat() : input.getShort() / 32768f;
    }
}
