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
    private void write(ByteBuffer output) {
        for (float sample : limited) output.putShort((short) Math.max(-32768, Math.min(32767, Math.round(sample * 32768f))));
    }
    @Override public void queueInput(ByteBuffer input) {
        input.order(ByteOrder.nativeOrder());
        ByteBuffer output = replaceOutputBuffer(input.remaining() / 2);
        NormalizationSettings.Value setting = NormalizationSettings.get(id);
        boolean enabled = setting.enabled || CrossfadeBridge.isMixing(id);
        double minimumGain = 1;
        while (input.remaining() >= frame.length * 4) {
            for (int i = 0; i < frame.length; i++) frame[i] = input.getFloat();
            if (limiter.push(frame, limited, setting.ceiling, enabled)) write(output);
            minimumGain = Math.min(minimumGain, limiter.currentGain());
        }
        CrossfadeBridge.limiterGain(id, minimumGain);
        output.flip();
    }
    @Override protected void onQueueEndOfStream() {
        if (limiter == null) return;
        ByteBuffer output = replaceOutputBuffer(((int) Math.ceil(inputAudioFormat.sampleRate * 0.005) + 1) * frame.length * 2);
        NormalizationSettings.Value setting = NormalizationSettings.get(id);
        while (limiter.pop(limited, setting.ceiling, setting.enabled || CrossfadeBridge.isMixing(id))) write(output);
        output.flip();
    }
}
