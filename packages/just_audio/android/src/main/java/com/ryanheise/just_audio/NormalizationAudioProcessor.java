package com.ryanheise.just_audio;

import androidx.media3.common.C;
import androidx.media3.common.audio.BaseAudioProcessor;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;

/** Gain before collection/mixing. Float output preserves boosts and overlap peaks. */
final class NormalizationAudioProcessor extends BaseAudioProcessor {
    private final String id;
    private final CrossfadeStreamTiming timing;
    private double gain = 1;
    NormalizationAudioProcessor(String id) { this(id, null); }
    NormalizationAudioProcessor(String id, CrossfadeStreamTiming timing) { this.id = id; this.timing = timing; }
    @Override protected AudioFormat onConfigure(AudioFormat format) throws UnhandledAudioFormatException {
        if (format.encoding != C.ENCODING_PCM_16BIT && format.encoding != C.ENCODING_PCM_FLOAT)
            throw new UnhandledAudioFormatException(format);
        return new AudioFormat(format.sampleRate, format.channelCount, C.ENCODING_PCM_FLOAT);
    }
    @Override protected void onFlush() { gain = NormalizationSettings.get(id).gain; }
    @Override public void queueInput(ByteBuffer input) {
        input.order(ByteOrder.nativeOrder());
        boolean floats = inputAudioFormat.encoding == C.ENCODING_PCM_FLOAT;
        int samples = input.remaining() / (floats ? 4 : 2);
        ByteBuffer output = replaceOutputBuffer(samples * 4);
        NormalizationSettings.Value setting = NormalizationSettings.get(id);
        double target = setting.gain;
        double smoothing = Math.exp(-1.0 / (inputAudioFormat.sampleRate * 0.020));
        int channels = inputAudioFormat.channelCount;
        if (timing != null) timing.tag(samples / channels);
        for (int sample = 0; sample < samples; sample++) {
            if (sample % channels == 0) gain = target + (gain - target) * smoothing;
            float value = floats ? input.getFloat() : input.getShort() / 32768f;
            output.putFloat((float) ((Float.isFinite(value) ? value : 0) * gain));
        }
        output.flip();
    }
}
