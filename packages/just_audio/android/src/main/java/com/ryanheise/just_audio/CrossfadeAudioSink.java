package com.ryanheise.just_audio;

import androidx.media3.common.C;
import androidx.media3.common.Format;
import androidx.media3.common.util.Util;
import androidx.media3.exoplayer.audio.AudioSink;
import androidx.media3.exoplayer.audio.ForwardingAudioSink;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;

/**
 * Finamp+: keeps the main player's clock right after a {@link CrossfadeBridge} hand-over. The player skips the part of
 * the new song that was already heard, so its output runs that much behind the song; this adds it back from the moment
 * the new song is heard, so positions, the next song's start and everything else stay where they belong.
 */
public class CrossfadeAudioSink extends ForwardingAudioSink {
    private final String playerId;
    private final CrossfadeStreamTiming timing;
    private boolean discontinuity;
    private long boundaryTimeUs = C.TIME_UNSET;
    private boolean mixedBoundary;
    private final CrossfadeClock clock = new CrossfadeClock();
    private Format inputFormat;
    private ByteBuffer carrier, carrierStorage, pendingReal, offeredReal;
    private long offeredSkipFrames;
    private long carrierTimeUs, lastRealEndUs = C.TIME_UNSET;
    // Signed input accounting: ring carriers add pipeline input, bypassing
    // already-heard own PCM removes it. Neither changes the source PCM clock.
    private long adjustmentFrames, adjustmentBaseUs, boundaryShiftUs;

    private long adjustmentUs() {
        return adjustmentBaseUs + (inputFormat == null ? 0 : adjustmentFrames * C.MICROS_PER_SECOND / inputFormat.sampleRate);
    }

    @Override
    public void configure(Format format, int specifiedBufferSize, int[] outputChannels) throws ConfigurationException {
        if (Util.isEncodingLinearPcm(format.pcmEncoding)) {
            CrossfadeBridge.registerOutputPump(playerId);
        } else {
            CrossfadeBridge.unregisterOutputPump(playerId);
            CrossfadeBridge.forget(playerId);
            CrossfadeBridge.onSinkFlush(playerId);
        }
        if (inputFormat != null && inputFormat.sampleRate != format.sampleRate) {
            adjustmentBaseUs = adjustmentUs();
            adjustmentFrames = 0;
        }
        inputFormat = format;
        super.configure(format, specifiedBufferSize, outputChannels);
    }

    /** Called on every playback render iteration, including while the decoder has no input. */
    void pump() throws InitializationException, WriteException {
        if (pendingReal != null || inputFormat == null || lastRealEndUs == C.TIME_UNSET) return;
        if (carrier == null) {
            int frames = CrossfadeBridge.drainFrames(playerId);
            if (frames == 0) return;
            if (!Util.isEncodingLinearPcm(inputFormat.pcmEncoding)) return;
            int size = frames * Util.getPcmFrameSize(inputFormat.pcmEncoding, inputFormat.channelCount);
            if (carrierStorage == null || carrierStorage.capacity() < size)
                carrierStorage = ByteBuffer.allocateDirect(size).order(ByteOrder.nativeOrder());
            carrier = carrierStorage;
            carrier.clear();
            carrier.limit(size);
            carrierTimeUs = lastRealEndUs + adjustmentUs();
            adjustmentFrames += frames;
        }
        timing.pumping = true;
        try {
            if (super.handleBuffer(carrier, carrierTimeUs, 1)) carrier = null;
        } finally {
            timing.pumping = false;
        }
    }

    public CrossfadeAudioSink(AudioSink sink, String playerId) {
        this(sink, playerId, new CrossfadeStreamTiming());
    }

    CrossfadeAudioSink(AudioSink sink, String playerId, CrossfadeStreamTiming timing) {
        super(sink);
        this.playerId = playerId;
        this.timing = timing;
    }

    @Override
    public void handleDiscontinuity() {
        // A new song starts with the next buffer.
        discontinuity = true;
        // The processor resets its PCM clock after the old pipeline has drained.
        // Resetting it here could timestamp an old, held-back tail as the new song.
        super.handleDiscontinuity();
    }

    @Override
    public boolean handleBuffer(ByteBuffer buffer, long presentationTimeUs, int encodedAccessUnitCount)
            throws InitializationException, WriteException {
        if (offeredReal == null) {
            offeredReal = buffer;
            offeredSkipFrames = 0;
            if (inputFormat != null && inputFormat.sampleRate > 0 && inputFormat.channelCount > 0
                    && Util.isEncodingLinearPcm(inputFormat.pcmEncoding))
                lastRealEndUs = presentationTimeUs + buffer.remaining()
                        / Util.getPcmFrameSize(inputFormat.pcmEncoding, inputFormat.channelCount)
                        * C.MICROS_PER_SECOND / inputFormat.sampleRate;
        }
        if (pendingReal == null && inputFormat != null && inputFormat.sampleRate > 0
                && inputFormat.channelCount > 0 && Util.isEncodingLinearPcm(inputFormat.pcmEncoding)) {
            int frameSize = Util.getPcmFrameSize(inputFormat.pcmEncoding, inputFormat.channelCount);
            int frames = buffer.remaining() / frameSize;
            int skipped = CrossfadeBridge.skipOwn(playerId, frames, timing.queuedOwnFrames());
            if (skipped > 0) {
                buffer.position(buffer.position() + skipped * frameSize);
                adjustmentFrames -= skipped;
                offeredSkipFrames += skipped;
                timing.advance(skipped);
                CrossfadeBridge.onPcmTime(playerId, timing.positionUs(inputFormat.sampleRate));
                // Do not wait for a full output pipeline just to throw away
                // another decoder buffer. The ring pump owns audible output.
                if (!buffer.hasRemaining()) { offeredReal = null; return true; }
            }
        }
        if (offeredSkipFrames > 0)
            presentationTimeUs += offeredSkipFrames * C.MICROS_PER_SECOND / inputFormat.sampleRate;
        if (carrier != null) {
            pump();
            if (carrier != null) return false;
        }
        if (pendingReal == null) {
            pendingReal = buffer;
        }
        if (discontinuity) {
            discontinuity = false;
            boundaryTimeUs = presentationTimeUs;
            boundaryShiftUs = adjustmentUs();
            mixedBoundary = CrossfadeBridge.markBoundary(playerId);
        }
        // Account inserted and bypassed INPUT frames in Media3's consistency
        // check. The bridge separately retains the original song frame order.
        boolean handled = super.handleBuffer(buffer, presentationTimeUs + adjustmentUs(), encodedAccessUnitCount);
        if (handled) pendingReal = offeredReal = null;
        if (boundaryTimeUs != C.TIME_UNSET) {
            long frames = mixedBoundary ? CrossfadeBridge.boundaryOffsetFrames(playerId) : 0;
            int sampleRate = mixedBoundary ? CrossfadeBridge.mainSampleRate() : 1;
            if (frames >= 0 && sampleRate > 0) {
                // The sink re-anchors to this presentation timestamp for each
                // stream, including ordinary gapless changes after a crossfade.
                clock.onStream(boundaryTimeUs + boundaryShiftUs,
                        frames * C.MICROS_PER_SECOND / sampleRate - boundaryShiftUs);
                boundaryTimeUs = C.TIME_UNSET;
            }
        }
        return handled;
    }

    @Override public void play() { CrossfadeBridge.playing(playerId, true); super.play(); }
    @Override public void pause() { CrossfadeBridge.playing(playerId, false); super.pause(); }

    private void clearPump() {
        carrier = pendingReal = offeredReal = null;
        offeredSkipFrames = 0;
        lastRealEndUs = C.TIME_UNSET;
        adjustmentFrames = adjustmentBaseUs = boundaryShiftUs = 0;
        timing.pumping = false;
    }

    @Override
    public long getCurrentPositionUs(boolean sourceEnded) {
        long positionUs = super.getCurrentPositionUs(sourceEnded);
        return positionUs == CURRENT_POSITION_NOT_SET ? positionUs : clock.positionUs(positionUs);
    }

    @Override
    public void flush() {
        // A seek or a new start: the sink's time starts over from the next buffer.
        clock.clear();
        clearPump();
        boundaryTimeUs = C.TIME_UNSET;
        discontinuity = false;
        CrossfadeBridge.onSinkFlush(playerId);
        timing.flush();
        super.flush();
    }

    @Override
    public void reset() {
        CrossfadeBridge.unregisterOutputPump(playerId);
        clock.clear();
        clearPump();
        boundaryTimeUs = C.TIME_UNSET;
        discontinuity = false;
        timing.flush();
        super.reset();
    }
}
