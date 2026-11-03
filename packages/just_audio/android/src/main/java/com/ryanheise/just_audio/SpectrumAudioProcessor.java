package com.ryanheise.just_audio;

import androidx.media3.common.C;
import androidx.media3.common.audio.BaseAudioProcessor;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;

/** Observes the visualizer spectrum without modifying playback samples. */
public class SpectrumAudioProcessor extends BaseAudioProcessor {
    private final Spectrum.Analyzer analyzer = new Spectrum.Analyzer();

    @Override
    protected AudioFormat onConfigure(AudioFormat format) {
        if (format.channelCount != 2
                || (format.encoding != C.ENCODING_PCM_16BIT && format.encoding != C.ENCODING_PCM_FLOAT)) {
            return AudioFormat.NOT_SET;
        }
        analyzer.configure(format.sampleRate);
        return format;
    }

    @Override
    public void queueInput(ByteBuffer input) {
        // Media3 drains the chain with EMPTY_BUFFER. Before allocation our output is that same
        // buffer, so copying it into itself throws; an empty call must also preserve pending output.
        if (!input.hasRemaining()) return;
        ByteBuffer output = replaceOutputBuffer(input.remaining());
        if (Spectrum.isEnabled()) {
            ByteBuffer samples = input.duplicate().order(ByteOrder.nativeOrder());
            boolean floats = inputAudioFormat.encoding == C.ENCODING_PCM_FLOAT;
            while (samples.remaining() >= (floats ? 8 : 4)) {
                float left = floats ? samples.getFloat() : samples.getShort() / 32768f;
                float right = floats ? samples.getFloat() : samples.getShort() / 32768f;
                analyzer.add((left + right) * 0.5f);
            }
        }
        output.put(input);
        output.flip();
    }

    @Override
    protected void onReset() {
        analyzer.reset();
    }
}
