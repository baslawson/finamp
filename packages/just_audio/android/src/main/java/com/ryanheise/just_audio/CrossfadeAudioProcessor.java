package com.ryanheise.just_audio;

import androidx.media3.common.C;
import androidx.media3.common.audio.BaseAudioProcessor;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;

/**
 * Finamp+: the part of {@link CrossfadeBridge} inside each player's audio chain. Plays the sound through unchanged,
 * except while the player is crossfading: the second player's sound is collected, and the main player mixes it in.
 */
public class CrossfadeAudioProcessor extends BaseAudioProcessor {
    private final String playerId;
    private final CrossfadeStreamTiming timing;

    public CrossfadeAudioProcessor(String playerId) {
        this(playerId, new CrossfadeStreamTiming());
    }

    CrossfadeAudioProcessor(String playerId, CrossfadeStreamTiming timing) {
        this.playerId = playerId;
        this.timing = timing;
    }

    @Override
    protected AudioFormat onConfigure(AudioFormat inputAudioFormat) throws UnhandledAudioFormatException {
        if (inputAudioFormat.encoding != C.ENCODING_PCM_16BIT && inputAudioFormat.encoding != C.ENCODING_PCM_FLOAT) {
            // Can't take part; the bridge then crossfades the old way.
            CrossfadeBridge.forget(playerId);
            return AudioFormat.NOT_SET;
        }
        CrossfadeBridge.onConfigure(playerId, inputAudioFormat);
        return inputAudioFormat;
    }

    @Override
    public void queueInput(ByteBuffer inputBuffer) {
        int remaining = inputBuffer.remaining();
        if (remaining == 0) return;
        inputBuffer.order(ByteOrder.nativeOrder());
        ByteBuffer output = replaceOutputBuffer(CrossfadeBridge.outputCapacity(playerId, remaining, inputAudioFormat));
        int start = inputBuffer.position();
        try {
            if (timing.consumeTag(remaining / inputAudioFormat.bytesPerFrame)) {
                // The render loop requests ring audio even when no decoder input is
                // available. These carrier frames never advance either song clock
                // and are replaced entirely by already-normalized incoming PCM.
                CrossfadeBridge.drain(playerId, output, inputAudioFormat, remaining / inputAudioFormat.bytesPerFrame);
                inputBuffer.position(inputBuffer.limit());
                output.flip();
                return;
            }
            long timeUs = timing.positionUs(inputAudioFormat.sampleRate);
            timing.advance(remaining / inputAudioFormat.bytesPerFrame);
            CrossfadeBridge.onPcmTime(playerId, timing.positionUs(inputAudioFormat.sampleRate));
            if (CrossfadeBridge.isCollecting(playerId)) CrossfadeBridge.collect(inputBuffer, inputAudioFormat);
            if (CrossfadeBridge.isMixing(playerId) && CrossfadeBridge.mix(inputBuffer, output, inputAudioFormat, timeUs)) {
                output.flip();
                return;
            }
        } catch (RuntimeException e) {
            // Never let the crossfade take playback down: drop it and pass this buffer through as it is.
            CrossfadeBridge.onError(e);
            inputBuffer.position(start);
            output.clear();
        }
        output.put(inputBuffer);
        output.flip();
    }

    @Override
    protected void onQueueEndOfStream() {
        CrossfadeBridge.onQueueEndOfStream(playerId);
    }

    @Override
    protected void onFlush() {
        timing.flush();
        CrossfadeBridge.onFlush(playerId);
    }

    @Override
    protected void onReset() {
        CrossfadeBridge.forget(playerId);
    }
}
