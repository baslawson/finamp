package com.ryanheise.just_audio;

import androidx.media3.common.C;
import androidx.media3.common.audio.BaseAudioProcessor;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;

/** Limit the final mixed signal before its only integer conversion. */
final class NormalizationOutputProcessor extends BaseAudioProcessor {
    private final String id;
    private LookaheadLimiter limiter;
    private float[] frame, limited;
    // Grow-only scratch, so whole buffers move in bulk instead of a sample at a time.
    private float[] in = new float[0];
    private short[] out = new short[0];
    private int written;
    NormalizationOutputProcessor(String id) { this.id = id; }
    @Override protected AudioFormat onConfigure(AudioFormat format) throws UnhandledAudioFormatException {
        if (format.encoding != C.ENCODING_PCM_FLOAT) throw new UnhandledAudioFormatException(format);
        return new AudioFormat(format.sampleRate, format.channelCount, C.ENCODING_PCM_16BIT);
    }
    @Override protected void onFlush() {
        if (inputAudioFormat == AudioFormat.NOT_SET) return;
        limiter = new LookaheadLimiter(inputAudioFormat.sampleRate, inputAudioFormat.channelCount);
        frame = new float[inputAudioFormat.channelCount];
        limited = new float[inputAudioFormat.channelCount];
    }
    private void write() {
        for (float sample : limited) out[written++] = (short) Math.max(-32768, Math.min(32767, Math.round(sample * 32768f)));
    }
    private void flushWritten(ByteBuffer output) {
        output.asShortBuffer().put(out, 0, written);
        output.position(written * 2);
        output.flip();
    }
    @Override public void queueInput(ByteBuffer input) {
        input.order(ByteOrder.nativeOrder());
        ByteBuffer output = replaceOutputBuffer(input.remaining() / 2);
        NormalizationSettings.Value setting = NormalizationSettings.get(id);
        boolean enabled = setting.enabled || CrossfadeBridge.isMixing(id);
        double minimumGain = 1;
        int channels = frame.length;
        int samples = input.remaining() / (channels * 4) * channels;
        if (in.length < samples) in = new float[samples];
        if (out.length < samples) out = new short[samples];
        input.asFloatBuffer().get(in, 0, samples);
        input.position(input.position() + samples * 4);
        written = 0;
        for (int sample = 0; sample < samples; sample += channels) {
            System.arraycopy(in, sample, frame, 0, channels);
            if (limiter.push(frame, limited, setting.ceiling, enabled)) write();
            minimumGain = Math.min(minimumGain, limiter.currentGain());
        }
        CrossfadeBridge.limiterGain(id, minimumGain);
        flushWritten(output);
    }
    @Override protected void onQueueEndOfStream() {
        if (limiter == null) return;
        int samples = ((int) Math.ceil(inputAudioFormat.sampleRate * 0.005) + 1) * frame.length;
        ByteBuffer output = replaceOutputBuffer(samples * 2);
        NormalizationSettings.Value setting = NormalizationSettings.get(id);
        if (out.length < samples) out = new short[samples];
        written = 0;
        while (limiter.pop(limited, setting.ceiling, setting.enabled || CrossfadeBridge.isMixing(id))) write();
        flushWritten(output);
    }
}
