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
    // The 20 ms gain smoothing for smoothingRate, worked out once per rate.
    private double smoothing;
    private int smoothingRate;
    // Grow-only scratch, so whole buffers move in bulk instead of a sample at a time.
    private float[] floats = new float[0];
    private short[] shorts = new short[0];
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
        boolean floatInput = inputAudioFormat.encoding == C.ENCODING_PCM_FLOAT;
        int samples = input.remaining() / (floatInput ? 4 : 2);
        ByteBuffer output = replaceOutputBuffer(samples * 4);
        NormalizationSettings.Value setting = NormalizationSettings.get(id);
        double target = setting.gain;
        if (smoothingRate != inputAudioFormat.sampleRate) {
            smoothingRate = inputAudioFormat.sampleRate;
            smoothing = Math.exp(-1.0 / (inputAudioFormat.sampleRate * 0.020));
        }
        int channels = inputAudioFormat.channelCount;
        if (timing != null) timing.tag(samples / channels);
        if (floats.length < samples) floats = new float[samples];
        if (floatInput) {
            input.asFloatBuffer().get(floats, 0, samples);
        } else {
            if (shorts.length < samples) shorts = new short[samples];
            input.asShortBuffer().get(shorts, 0, samples);
            for (int sample = 0; sample < samples; sample++) floats[sample] = shorts[sample] / 32768f;
        }
        input.position(input.position() + samples * (floatInput ? 4 : 2));
        // The gain moves once per frame, before its first sample, as it always has.
        for (int sample = 0; sample < samples; ) {
            gain = target + (gain - target) * smoothing;
            for (int end = Math.min(samples, sample + channels); sample < end; sample++) {
                float value = floats[sample];
                floats[sample] = (float) ((Float.isFinite(value) ? value : 0) * gain);
            }
        }
        output.asFloatBuffer().put(floats, 0, samples);
        output.position(samples * 4);
        output.flip();
    }
}
