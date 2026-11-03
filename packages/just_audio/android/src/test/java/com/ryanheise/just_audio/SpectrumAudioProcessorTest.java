package com.ryanheise.just_audio;

import androidx.media3.common.C;
import androidx.media3.common.audio.AudioProcessor;
import androidx.media3.common.audio.AudioProcessor.AudioFormat;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;

/** Standalone regression harness; run with -ea and Media3 common plus Android SDK on the classpath. */
public final class SpectrumAudioProcessorTest {
    public static void main(String[] args) throws Exception {
        for (int encoding : new int[] {C.ENCODING_PCM_16BIT, C.ENCODING_PCM_FLOAT}) {
            for (boolean visualizer : new boolean[] {false, true}) {
                Spectrum.setEnabled(visualizer);
                SpectrumAudioProcessor processor = new SpectrumAudioProcessor();
                AudioFormat format = new AudioFormat(48000, 2, encoding);
                processor.configure(format);
                processor.flush();
                // Media3 sends this shared buffer while draining a processor with no audio yet.
                empty(processor);
                passthrough(processor, encoding);
                empty(processor);
                processor.flush();
                empty(processor);
                passthrough(processor, encoding);
                processor.reset();
                processor.configure(format);
                processor.flush();
                empty(processor);
                passthrough(processor, encoding);
                processor.queueEndOfStream();
                assert !processor.getOutput().hasRemaining();
                assert processor.isEnded() : "empty stream did not finish";
            }
        }
        Spectrum.setEnabled(false);
        SpectrumAudioProcessor mono = new SpectrumAudioProcessor();
        assert mono.configure(new AudioFormat(44100, 1, C.ENCODING_PCM_16BIT)) == AudioFormat.NOT_SET;
        assert !mono.isActive() : "mono should bypass the stereo visualizer";
        System.out.println("Spectrum: empty startup/drain/reset buffers and bit-exact PCM16/float playback passed, visualizer on and off");
    }

    private static void empty(SpectrumAudioProcessor processor) {
        for (int i = 0; i < 3; i++) {
            processor.queueInput(AudioProcessor.EMPTY_BUFFER);
            assert !processor.getOutput().hasRemaining() : "empty input produced audio";
        }
    }

    private static void passthrough(SpectrumAudioProcessor processor, int encoding) {
        int sampleBytes = encoding == C.ENCODING_PCM_FLOAT ? 4 : 2;
        ByteBuffer input = ByteBuffer.allocateDirect(2048 * 2 * sampleBytes).order(ByteOrder.nativeOrder());
        for (int i = 0; i < 2048; i++) {
            float sample = (float) (Math.sin(i * .1) * .5);
            if (sampleBytes == 4) {
                input.putFloat(sample).putFloat(-sample);
            } else {
                input.putShort((short) (sample * 32767)).putShort((short) (-sample * 32767));
            }
        }
        input.flip();
        byte[] expected = new byte[input.remaining()];
        input.duplicate().get(expected);
        processor.queueInput(input);
        assert !input.hasRemaining() : "input was not consumed";
        // An empty call must leave already queued output intact too.
        processor.queueInput(AudioProcessor.EMPTY_BUFFER);
        ByteBuffer output = processor.getOutput();
        assert output.remaining() == expected.length : "pending output was lost";
        for (byte sample : expected) assert output.get() == sample : "playback samples changed";
    }
}
