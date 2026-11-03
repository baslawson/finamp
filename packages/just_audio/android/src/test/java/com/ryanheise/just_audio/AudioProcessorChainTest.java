package com.ryanheise.just_audio;

import androidx.media3.common.C;
import androidx.media3.common.audio.AudioProcessingPipeline;
import androidx.media3.common.audio.AudioProcessor;
import androidx.media3.common.audio.AudioProcessor.AudioFormat;
import com.google.common.collect.ImmutableList;
import java.io.ByteArrayOutputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;

/** Exercises the production PCM chain through Media3, including its empty-buffer drains. */
public final class AudioProcessorChainTest {
    public static void main(String[] args) throws Exception {
        for (int channels : new int[] {1, 2}) {
            for (int encoding : new int[] {C.ENCODING_PCM_16BIT, C.ENCODING_PCM_FLOAT}) {
                for (boolean normalized : new boolean[] {false, true}) {
                    for (boolean visualizer : new boolean[] {false, true}) {
                        run(channels, encoding, normalized, visualizer);
                    }
                }
            }
        }
        repeatedDetectorTails();
        Spectrum.setEnabled(false);
        System.out.println("PCM chain: startup, empty drains, sample accuracy, repeated detector tails, flush and reset passed for mono/stereo PCM16/float, normalization and visualizer on/off");
    }

    private static void repeatedDetectorTails() throws Exception {
        String id = "limiter-tail-regression";
        double ceiling = Math.pow(10, -1.0 / 20);
        NormalizationSettings.set(id, true, 0, 0);
        NormalizationOutputProcessor processor = new NormalizationOutputProcessor(id);
        AudioFormat format = new AudioFormat(48000, 2, C.ENCODING_PCM_FLOAT);
        processor.configure(format);
        processor.flush();
        // Both sample peaks are safe. The overshoot appears only when the
        // 4x detector's delayed interpolation tail is flushed at end of stream.
        TruePeakDetector fixture = new TruePeakDetector(2);
        float[] frame = {.75f, -.375f};
        assert fixture.push(frame) < ceiling;
        assert fixture.push(frame) < ceiling;
        double tailPeak = 0;
        for (int i = 0; i < TruePeakDetector.TAPS; i++) tailPeak = Math.max(tailPeak, fixture.push(null));
        assert tailPeak > ceiling : "fixture must need detector-tail protection";
        byte[] first = null;
        for (int stream = 0; stream < 3; stream++) {
            ByteBuffer input = ByteBuffer.allocateDirect(16).order(ByteOrder.nativeOrder());
            input.putFloat(frame[0]).putFloat(frame[1]).putFloat(frame[0]).putFloat(frame[1]).flip();
            processor.queueInput(input);
            assert !input.hasRemaining();
            assert !processor.getOutput().hasRemaining() : "short input should stay in lookahead";
            processor.queueEndOfStream();
            ByteBuffer drained = processor.getOutput();
            byte[] output = new byte[drained.remaining()];
            drained.get(output);
            assert processor.isEnded();
            assert output.length == 8 : "short stream " + stream + " emitted " + output.length + " bytes instead of 8";
            if (first == null) first = output;
            else assert java.util.Arrays.equals(first, output) : "detector tail was not protected after flush/reset";
            ByteBuffer pcm = ByteBuffer.wrap(output).order(ByteOrder.nativeOrder());
            TruePeakDetector meter = new TruePeakDetector(2);
            double peak = 0;
            while (pcm.hasRemaining()) {
                peak = Math.max(peak, meter.push(new float[] {pcm.getShort() / 32768f, pcm.getShort() / 32768f}));
            }
            for (int i = 0; i < TruePeakDetector.TAPS; i++) peak = Math.max(peak, meter.push(null));
            assert peak <= ceiling : "drained detector tail escaped ceiling";
            if (stream == 1) {
                processor.reset();
                processor.configure(format);
            }
            processor.flush();
        }
        processor.reset();
        NormalizationSettings.remove(id);
    }

    private static void run(int channels, int encoding, boolean normalized, boolean visualizer) throws Exception {
        String id = "pcm-regression";
        NormalizationSettings.set(id, normalized, -6, 0);
        Spectrum.setEnabled(visualizer);
        AudioProcessingPipeline chain = new AudioProcessingPipeline(ImmutableList.of(
            new NormalizationAudioProcessor(id), new CrossfadeAudioProcessor(id),
            new VoiceEnvelopeProcessor(id),
            new SpectrumAudioProcessor(), new NormalizationOutputProcessor(id)));
        AudioFormat inputFormat = new AudioFormat(48000, channels, encoding);
        assert chain.configure(inputFormat).encoding == C.ENCODING_PCM_16BIT;
        chain.flush();
        // Check a second song too, after every processor has released its buffers.
        for (int song = 0; song < 2; song++) {
            chain.queueInput(AudioProcessor.EMPTY_BUFFER);
            assert !chain.getOutput().hasRemaining();
            ByteArrayOutputStream output = new ByteArrayOutputStream();
            ByteArrayOutputStream expected = new ByteArrayOutputStream();
            for (int frames : new int[] {1, 17, 512, 2048}) {
                int bytes = encoding == C.ENCODING_PCM_FLOAT ? 4 : 2;
                ByteBuffer input = ByteBuffer.allocateDirect(frames * channels * bytes).order(ByteOrder.nativeOrder());
                ByteBuffer wanted = ByteBuffer.allocate(frames * channels * 2).order(ByteOrder.nativeOrder());
                for (int i = 0; i < frames * channels; i++) {
                    short pcm = (short) (Math.sin(i * .1) * 8000);
                    if (bytes == 4) input.putFloat(pcm / 32768f);
                    else input.putShort(pcm);
                    wanted.putShort((short) Math.round(pcm * (normalized ? Math.pow(10, -6.0 / 20) : 1)));
                }
                expected.write(wanted.array());
                input.flip();
                for (int attempt = 0; input.hasRemaining() && attempt < 100; attempt++) {
                    chain.queueInput(input);
                    drain(chain, output);
                }
                assert !input.hasRemaining() : "input stalled";
                chain.queueInput(AudioProcessor.EMPTY_BUFFER);
                drain(chain, output);
            }
            chain.queueEndOfStream();
            for (int attempt = 0; !chain.isEnded() && attempt < 100; attempt++) drain(chain, output);
            assert chain.isEnded() : "end-of-stream stalled";
            byte[] actual = output.toByteArray(), wanted = expected.toByteArray();
            assert actual.length == wanted.length : "song tail lost";
            for (int i = 0; i < actual.length; i++) assert actual[i] == wanted[i] : "sample changed at " + i;
            // No nonempty input reaches a drained limiter before a flush:
            // Media3's pipeline refuses to consume it after end of stream.
            ByteBuffer afterEnd = ByteBuffer.allocateDirect(channels * (encoding == C.ENCODING_PCM_FLOAT ? 4 : 2));
            chain.queueInput(afterEnd);
            assert afterEnd.position() == 0 && !chain.getOutput().hasRemaining();
            chain.reset();
            chain.configure(inputFormat);
            chain.flush();
        }
        chain.reset();
        NormalizationSettings.remove(id);
    }

    private static void drain(AudioProcessingPipeline chain, ByteArrayOutputStream output) {
        ByteBuffer buffer = chain.getOutput();
        while (buffer.hasRemaining()) output.write(buffer.get());
    }
}
