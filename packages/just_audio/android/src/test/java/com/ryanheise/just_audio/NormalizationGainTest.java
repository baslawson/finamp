package com.ryanheise.just_audio;

import androidx.media3.common.C;
import androidx.media3.common.audio.AudioProcessor.AudioFormat;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;

/** Explicit setting changes ramp, including Off; initial gain is ready before PCM starts. */
public final class NormalizationGainTest {
    public static void main(String[] args) throws Exception {
        for (int channels : new int[] {1, 2}) {
            String id = "gain-ramp";
            NormalizationSettings.set(id, true, -12, 0);
            NormalizationAudioProcessor processor = new NormalizationAudioProcessor(id);
            processor.configure(new AudioFormat(48000, channels, C.ENCODING_PCM_FLOAT));
            processor.flush();
            float previous = .4f * (float) Math.pow(10, -12.0 / 20);
            for (boolean enabled : new boolean[] {true, false, true}) {
                NormalizationSettings.set(id, enabled, -12, 0);
                ByteBuffer input = ByteBuffer.allocateDirect(48000 * channels * 4).order(ByteOrder.nativeOrder());
                while (input.hasRemaining()) input.putFloat(.4f);
                input.flip();
                processor.queueInput(input);
                ByteBuffer output = processor.getOutput().order(ByteOrder.nativeOrder());
                while (output.hasRemaining()) {
                    float first = output.getFloat();
                    assert Math.abs(first - previous) < .001 : "gain setting clicked";
                    for (int channel = 1; channel < channels; channel++) assert output.getFloat() == first;
                    previous = first;
                }
                double wanted = enabled ? .4 * Math.pow(10, -12.0 / 20) : .4;
                assert Math.abs(previous - wanted) < .00001 : "setting did not settle";
            }
            processor.reset();
            NormalizationSettings.remove(id);
        }
        System.out.println("Normalization gain: first-sample gain, smooth On/Off changes and channel linking passed");
    }
}
