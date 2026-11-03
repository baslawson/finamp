package com.ryanheise.just_audio;

import androidx.media3.common.C;
import androidx.media3.common.audio.BaseAudioProcessor;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.concurrent.ConcurrentHashMap;
import java.util.function.LongSupplier;

/** Sample-continuous music ducking after both songs have been mixed. */
final class VoiceEnvelopeProcessor extends BaseAudioProcessor {
    static LongSupplier nanoTime = System::nanoTime;
    private static final class Target {
        final double gain;
        final int millis;
        final long expires = nanoTime.getAsLong() + 60_000_000_000L;
        Target(double gain, int millis) { this.gain = gain; this.millis = millis; }
    }
    private static final ConcurrentHashMap<String, Target> targets = new ConcurrentHashMap<>();
    static void set(String id, double gain, int millis) {
        if (id != null) targets.put(id, new Target(Math.max(0, Math.min(1, gain)), Math.max(0, Math.min(5000, millis))));
    }
    static void remove(String id) { if (id != null) targets.remove(id); }
    private final String id;
    private Target target;
    private double gain = 1, from = 1, to = 1;
    private int elapsed, length;
    VoiceEnvelopeProcessor(String id) { this.id = id; }
    @Override protected AudioFormat onConfigure(AudioFormat format) throws UnhandledAudioFormatException {
        if (format.encoding != C.ENCODING_PCM_FLOAT) throw new UnhandledAudioFormatException(format);
        return format;
    }
    @Override public void queueInput(ByteBuffer input) {
        if (!input.hasRemaining()) return;
        input.order(ByteOrder.nativeOrder());
        Target next = targets.get(id);
        if (next != null && next.gain < 1 && nanoTime.getAsLong() > next.expires) {
            targets.replace(id, next, new Target(1, 1200));
            next = targets.get(id);
        }
        if (next != target) {
            target = next;
            from = gain;
            to = target == null ? 1 : target.gain;
            length = target == null ? 0 : (int) ((long) inputAudioFormat.sampleRate * target.millis / 1000);
            elapsed = 0;
        }
        ByteBuffer output = replaceOutputBuffer(input.remaining());
        if (gain == 1 && to == 1 && (length == 0 || elapsed >= length)) {
            output.put(input);
            output.flip();
            return;
        }
        while (input.remaining() >= inputAudioFormat.bytesPerFrame) {
            if (elapsed < length) elapsed++;
            gain = length == 0 || elapsed >= length ? to
                    : from + (to - from) * (.5 - .5 * Math.cos(Math.PI * elapsed / length));
            for (int ch = 0; ch < inputAudioFormat.channelCount; ch++) output.putFloat((float) (input.getFloat() * gain));
        }
        output.flip();
    }
    // Deliberately retain the envelope across playlist pipeline flushes: a DJ
    // line may cross that boundary. Pause/skip/settings cancellation restores it.
}
