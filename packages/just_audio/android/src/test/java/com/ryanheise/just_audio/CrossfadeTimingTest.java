package com.ryanheise.just_audio;

import androidx.media3.common.C;
import androidx.media3.common.audio.AudioProcessor.AudioFormat;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.Random;

/** Actual PCM scheduling, including arbitrary buffers, sink render-ahead and blocked-buffer retries. */
public final class CrossfadeTimingTest {
    public static void main(String[] args) throws Exception {
        for (int rate : new int[] {44100, 48000, 96000}) {
            for (int encoding : new int[] {C.ENCODING_PCM_16BIT, C.ENCODING_PCM_FLOAT}) {
                for (int leadMs : new int[] {250, 400}) scheduled(rate, encoding, leadMs);
                starvation(rate, encoding);
            }
        }
        timingResets();
        CrossfadeBridge.disarm();
        System.out.println("Crossfade timing: sample-aligned starts/curves, silent pre-roll, stale tick isolation, late rejection and clock resets passed");
    }

    private static void scheduled(int rate, int encoding, int leadMs) throws Exception {
        AudioFormat format = new AudioFormat(rate, 2, encoding);
        CrossfadeStreamTiming timing = new CrossfadeStreamTiming();
        CrossfadeAudioProcessor processor = new CrossfadeAudioProcessor("timed-main", timing);
        processor.configure(format);
        processor.flush();
        timing.onBuffer(8_000_000);
        // This represents the PCM already rendered into the sink, ahead of what is audible.
        processor.queueInput(buffer(format, rate * leadMs / 1000));
        processor.getOutput();
        CrossfadeBridge.arm("timed-main", "timed-next");
        CrossfadeBridge.onConfigure("timed-next", format);
        ByteBuffer ring = buffer(format, rate * 4);
        for (int i = 0; i < rate * 4; i++) {
            float sample = i == rate / 4 ? .5f : .25f;
            put(ring, sample, encoding);
            put(ring, -sample / 2, encoding);
        }
        ring.flip();
        CrossfadeBridge.collect(ring, format);
        long startUs = 10_012_345, endUs = 11_312_345;
        assert CrossfadeBridge.scheduleMix(startUs, endUs, .8) == 1;
        Random random = new Random(93);
        long total = (long) rate * leadMs / 1000;
        long first = -1;
        int incomingIndex = 0;
        int marker = 0;
        while (total < rate * 3.5) {
            int frames = 21 + random.nextInt(581);
            long bufferUs = 8_000_000 + total * 1_000_000L / rate;
            // A retry must not reset the running sample clock to this new callback's timestamp.
            timing.onBuffer(bufferUs);
            timing.onBuffer(bufferUs);
            CrossfadeBridge.setGains(1, 0); // Simulated late/stale Flutter ticks must have no effect.
            ByteBuffer own = buffer(format, frames);
            for (int i = 0; i < frames; i++) {
                put(own, .125f, encoding);
                put(own, -.0625f, encoding);
            }
            own.flip();
            processor.queueInput(own);
            ByteBuffer out = processor.getOutput().order(ByteOrder.nativeOrder());
            for (int i = 0; i < frames; i++) {
                long us = bufferUs + i * 1_000_000L / rate;
                double expected = .125;
                if (us >= startUs) {
                    if (first < 0) first = total + i;
                    double t = Math.min(1, (double) (us - startUs) / (endUs - startUs));
                    double envelope = Math.min(1, (incomingIndex + 1.0) / Math.max(1, rate * 5 / 1000));
                    expected = .125 * Math.cos(t * Math.PI / 2) +
                            (incomingIndex == rate / 4 ? .5 : .25) * Math.sin(t * Math.PI / 2) * .8 * envelope;
                    if (incomingIndex == rate / 4) marker++;
                    incomingIndex++;
                }
                float left = read(out, encoding), right = read(out, encoding);
                assert Math.abs(left - expected) < .00004 : "sample/curve shifted at " + rate + ", " + (total + i);
                assert Math.abs(right + left / 2) < .00005 : "stereo changed";
            }
            total += frames;
        }
        long wanted = (long) Math.ceil((startUs - 8_000_000) * (double) rate / 1_000_000);
        assert Math.abs(first - wanted) <= 1 : "incoming ring started late";
        assert marker == 1 : "first-beat marker repeated or skipped";
        CrossfadeBridge.disarm();
        CrossfadeBridge.arm("timed-main", "timed-next");
        CrossfadeBridge.onConfigure("timed-next", format);
        assert CrossfadeBridge.scheduleMix(startUs, endUs, 1) == -1 : "accepted a deadline already in the sink";
        CrossfadeBridge.onSinkFlush("timed-main");
        assert CrossfadeBridge.scheduleMix(startUs, endUs, 1) == 0 : "seek retained the previous render head";
        processor.reset();
    }

    private static void starvation(int rate, int encoding) throws Exception {
        AudioFormat format = new AudioFormat(rate, 2, encoding);
        CrossfadeStreamTiming timing = new CrossfadeStreamTiming();
        CrossfadeAudioProcessor processor = new CrossfadeAudioProcessor("starve-main", timing);
        processor.configure(format);
        processor.flush();
        timing.onBuffer(0);
        processor.queueInput(buffer(format, rate / 10));
        processor.getOutput();
        CrossfadeBridge.arm("starve-main", "starve-next");
        CrossfadeBridge.onConfigure("starve-next", format);
        CrossfadeBridge.collect(buffer(format, rate / 5), format);
        assert CrossfadeBridge.scheduleMix(1_000_000, 2_000_000, 1) == 1;
        // Render to 1.6s: incoming frames 0..0.2 exist, 0.2..0.6 are missing.
        processor.queueInput(buffer(format, rate * 3 / 2));
        processor.getOutput();
        ByteBuffer refill = buffer(format, rate * 4 / 5);
        int markerFrame = rate * 3 / 4;
        for (int i = rate / 5; i < rate; i++) {
            put(refill, i == markerFrame ? .5f : 0, encoding);
            put(refill, i == markerFrame ? -.25f : 0, encoding);
        }
        refill.flip();
        CrossfadeBridge.collect(refill, format);
        processor.queueInput(buffer(format, rate / 5));
        ByteBuffer out = processor.getOutput().order(ByteOrder.nativeOrder());
        int markerCount = 0;
        for (int i = 0; i < rate / 5; i++) {
            float left = read(out, encoding), right = read(out, encoding);
            if (left != 0) {
                assert Math.abs(i - (markerFrame - rate * 3 / 5)) <= 1 : "refill shifted the beat after starvation";
                assert left > .4f;
                markerCount++;
            }
            assert Math.abs(right + left / 2) < .00005;
        }
        assert markerCount == 1 : "refill repeated/skipped the incoming beat";
        CrossfadeBridge.disarm();
        processor.reset();
    }

    private static void timingResets() {
        CrossfadeStreamTiming timing = new CrossfadeStreamTiming();
        timing.onBuffer(8_000_000);
        assert timing.positionUs(48000) == 8_000_000;
        timing.advance(480);
        timing.onBuffer(8_000_000); // Sink retry.
        assert timing.positionUs(48000) == 8_010_000;
        timing.onBuffer(0); // Next playlist stream, stamped before processor flush.
        timing.flush();
        assert timing.positionUs(48000) == 0;
        timing.advance(960);
        assert timing.positionUs(48000) == 20_000;
        timing.onBuffer(12_000_000); // Seek.
        timing.flush();
        assert timing.positionUs(48000) == 12_000_000;
    }

    private static ByteBuffer buffer(AudioFormat f, int frames) {
        return ByteBuffer.allocateDirect(frames * f.bytesPerFrame).order(ByteOrder.nativeOrder());
    }
    private static void put(ByteBuffer b, float sample, int encoding) {
        if (encoding == C.ENCODING_PCM_FLOAT) b.putFloat(sample);
        else b.putShort((short) Math.round(sample * 32768));
    }
    private static float read(ByteBuffer b, int encoding) {
        return encoding == C.ENCODING_PCM_FLOAT ? b.getFloat() : b.getShort() / 32768f;
    }
}
