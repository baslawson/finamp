package com.ryanheise.just_audio;

import androidx.media3.common.C;
import androidx.media3.common.audio.AudioProcessor.AudioFormat;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;

public final class VoiceEnvelopeTest {
    private static long now;
    public static void main(String[] args) throws Exception {
        try {
            VoiceEnvelopeProcessor.nanoTime = () -> now;
            for (int rate : new int[] {24000, 44100, 48000, 96000}) {
                String id = "voice-envelope-" + rate;
                VoiceEnvelopeProcessor processor = new VoiceEnvelopeProcessor(id);
                AudioFormat format = new AudioFormat(rate, 2, C.ENCODING_PCM_FLOAT);
                processor.configure(format);
                processor.flush();
                processor.queueInput(androidx.media3.common.audio.AudioProcessor.EMPTY_BUFFER);
                assert !processor.getOutput().hasRemaining() : "empty startup produced output";
                VoiceEnvelopeProcessor.set(id, .2, 700);
                float previous = 1;
                for (int frame = 0; frame < rate * .7; frame++) {
                    float gain = frame(processor);
                    assert gain <= previous + 1e-6 && previous - gain < .001 : "stepped envelope";
                    previous = gain;
                    if (frame == rate / 3) processor.flush(); // A song boundary must not restart the ramp.
                }
                assert Math.abs(previous - .2) < 1e-6 : "wrong duck endpoint";
                VoiceEnvelopeProcessor.set(id, 1, 1200);
                for (int frame = 0; frame < rate * 1.2; frame++) {
                    float gain = frame(processor);
                    assert gain >= previous - 1e-6 && gain - previous < .001 : "stepped restore";
                    previous = gain;
                }
                assert Math.abs(previous - 1) < 1e-6;
                processor.queueInput(androidx.media3.common.audio.AudioProcessor.EMPTY_BUFFER);
                assert !processor.getOutput().hasRemaining() : "empty steady-state input replayed output";
                VoiceEnvelopeProcessor.set(id, .3, 0);
                assert Math.abs(frame(processor) - .3) < 1e-6;
                now += 61_000_000_000L; // A lost Flutter restore must never leave music ducked forever.
                for (int frame = 0; frame <= rate * 1.2; frame++) previous = frame(processor);
                assert Math.abs(previous - 1) < 1e-6 : "expired duck did not recover";
                processor.reset();
                VoiceEnvelopeProcessor.remove(id);
            }
        } finally { VoiceEnvelopeProcessor.nanoTime = System::nanoTime; }
        System.out.println("Voice envelopes: sample-smooth duck/restore, stereo, boundary flush and expiry recovery passed at four rates");
    }
    private static float frame(VoiceEnvelopeProcessor processor) {
        ByteBuffer data = ByteBuffer.allocateDirect(8).order(ByteOrder.nativeOrder());
        data.putFloat(1).putFloat(-.5f).flip();
        processor.queueInput(data);
        ByteBuffer output = processor.getOutput().order(ByteOrder.nativeOrder());
        float value = output.getFloat();
        assert Math.abs(output.getFloat() + value / 2) < 1e-6 : "stereo balance changed";
        return value;
    }
}
