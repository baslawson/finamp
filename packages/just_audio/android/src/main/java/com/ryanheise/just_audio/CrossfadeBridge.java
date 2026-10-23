package com.ryanheise.just_audio;

import android.util.Log;
import androidx.media3.common.C;
import androidx.media3.common.audio.AudioProcessor.AudioFormat;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.util.HashMap;
import java.util.Map;
import java.util.function.LongSupplier;
import java.util.ArrayList;
import java.util.List;
import java.util.Set;
import java.util.HashSet;

/**
 * Finamp+ crossfades through a single audio output. The second player decodes the next song, but instead of
 * playing it, its {@link CrossfadeAudioProcessor} hands the sound over here; the main player's processor mixes it into
 * its own output. Once the main player reaches the next song itself, it skips its own copy of what was already heard and
 * continues at exactly the next sample: there's no second clock to line up with, so nothing can drift.
 *
 * <p>Called from both players' playback threads and from Flutter's thread, so everything is synchronized.
 */
public final class CrossfadeBridge {
    private static final String TAG = "CrossfadeBridge";
    // Package-private so the real-time harness can advance time without sleeping.
    static LongSupplier nanoTime = System::nanoTime;
    private static long transition;
    private static long lastInputNanos, maxInputGapNanos, drainedFrames, pauseNanos = -1;
    private static long bypassedOwnFrames;
    private static int underruns;
    private static double minimumLimiterGain = 1;
    private static final List<String> events = new ArrayList<>();
    private static final Set<String> outputPumps = new HashSet<>();
    static synchronized void registerOutputPump(String id) { outputPumps.add(id); }
    static synchronized void unregisterOutputPump(String id) { outputPumps.remove(id); }
    static synchronized long outputLeadMillis(String id, Long positionMs) {
        if (positionMs == null) return 250;
        Long rendered = renderedUntilUs.get(id);
        long endMs = id != null && id.equals(mainId) && status == CATCHING_UP && mainFormat != null
                ? readFrames * 1000 / mainFormat.sampleRate : rendered == null ? -1 : rendered / 1000;
        return endMs < 0 ? 250 : Math.max(0, Math.min(600, endMs - positionMs));
    }

    private static void event(String message) {
        if (events.size() == 40) events.remove(0);
        events.add(message);
        Log.i(TAG, message);
    }

    public static synchronized Map<String, Object> diagnostics() {
        Map<String, Object> result = new HashMap<>();
        result.put("transition", transition);
        result.put("events", new ArrayList<>(events));
        events.clear();
        result.put("status", status);
        result.put("ownFrames", ownFrames);
        result.put("ringFrames", readFrames);
        result.put("bufferedFrames", Math.max(0, writtenFrames - readFrames));
        result.put("drainedFrames", drainedFrames);
        result.put("bypassedOwnFrames", bypassedOwnFrames);
        long stalled = status == CATCHING_UP && lastInputNanos != 0 && pauseNanos < 0
                ? Math.max(maxInputGapNanos, nanoTime.getAsLong() - lastInputNanos) : maxInputGapNanos;
        result.put("maxInputStallMs", stalled / 1_000_000);
        result.put("underruns", underruns);
        result.put("limiterGain", minimumLimiterGain);
        return result;
    }

    static synchronized void underrun(String id, int bufferMs, long elapsedMs) {
        if (id == null || !id.equals(mainId)) return;
        underruns++;
        event("Output underrun: buffer " + bufferMs + " ms, last feed " + elapsedMs + " ms ago; own "
                + ownFrames + ", ring " + readFrames + ", buffered " + Math.max(0, writtenFrames - readFrames)
                + ", drained " + drainedFrames + " frames");
    }

    static synchronized void limiterGain(String id, double gain) {
        if (id != null && id.equals(mainId)) minimumLimiterGain = Math.min(minimumLimiterGain, gain);
    }

    static synchronized void loadError(String id, IOException error, boolean cancelled) {
        if (id == null || (!id.equals(mainId) && !id.equals(nextId))) return;
        event((id.equals(mainId) ? "Main" : "Incoming") + " stream load error: "
                + error.getClass().getSimpleName() + (error.getCause() == null ? "" : "/" + error.getCause().getClass().getSimpleName())
                + "; retry deferred/cancelled=" + cancelled);
    }

    static synchronized void playing(String id, boolean playing) {
        if (id == null || !id.equals(mainId)) return;
        long now = nanoTime.getAsLong();
        if (!playing && pauseNanos < 0) pauseNanos = now;
        if (playing && pauseNanos >= 0) {
            if (catchUpStartNanos != 0) catchUpStartNanos += now - pauseNanos;
            lastInputNanos = now;
            pauseNanos = -1;
        }
    }

    public static final int OFF = 0;
    /** The second player is loading; its sound is collected from the first sample. */
    public static final int ARMED = 1;
    /** Fading: the main player mixes the next song into its own. */
    public static final int MIXING = 2;
    /** The main player reached the next song and is catching up with what was already played. */
    public static final int CATCHING_UP = 3;
    /** The main player plays the next song by itself; the second player can go. */
    public static final int DONE = 4;
    /** Something didn't fit; the main player stays silent until told otherwise, so the song doesn't restart. */
    public static final int FAILED = 5;
    /** Called off before the hand-over (seek, or too much collected); the main player plays on as normal. */
    public static final int ABORTED = 6;

    private static final int RING_SECONDS = 20;
    /** Mixing waits until this much is collected, so small hiccups don't cause dropouts. */
    private static final int PRIMING_MILLIS = 150;
    // During the catch-up: how far ahead of real time the collected sound is played, and at most how much per buffer.
    private static final int CATCH_UP_LEAD_MILLIS = 300;
    private static final int CATCH_UP_CHUNK_MILLIS = 250;
    /** Gains glide to new values over this long, so the steps between updates can't be heard. */
    private static final int GAIN_GLIDE_MILLIS = 100;
    /** Smooth the edges of incoming decoder buffers independently of the musical fade. */
    private static final int BUFFER_FADE_MILLIS = 5;

    private static String mainId;
    private static String nextId;
    private static int status = OFF;

    /** The current format of every player's sound, by player id. */
    private static final Map<String, AudioFormat> formats = new HashMap<>();
    private static final Map<String, Long> renderedUntilUs = new HashMap<>();
    private static AudioFormat mainFormat;
    private static AudioFormat nextFormat;

    // The next song's sound, as interleaved floats, indexed by frame since its first sample.
    private static float[] ring;
    private static int channels;
    private static int capacityFrames;
    private static long writtenFrames;
    private static long readFrames;
    private static boolean primed;

    private static float targetOut = 1f;
    private static float targetIn = 0f;
    private static float gainOut = 1f;
    private static float gainIn = 0f;
    private static float gainStep = 0.001f;
    private static float incomingEnvelope;
    private static float bufferFadeStep;
    private static long fadeStartUs = C.TIME_UNSET;
    private static long fadeEndUs;
    private static float scheduledGain;

    // Hand-over.
    private static boolean boundaryPending;
    private static boolean waitingForFlush;
    private static long ownFrames;
    private static long catchUpStartNanos;
    private static long catchUpPlayed;
    private static long lastProgressLogNanos;
    private static long boundaryOffsetFrames = -1;
    private static boolean usingMain;
    private static float mainBlend;
    private static float mainBlendStep;

    private CrossfadeBridge() {}

    // ---- Flutter side ----

    /** Starts collecting the sound of the player with [next], for crossfading into from the player with [main]. */
    public static synchronized void arm(String main, String next) {
        reset();
        mainId = main;
        nextId = next;
        status = ARMED;
        transition++;
        underruns = 0;
        maxInputGapNanos = lastInputNanos = drainedFrames = 0;
        bypassedOwnFrames = 0;
        minimumLimiterGain = 1;
        event("Armed native transition");
        Log.i(TAG, "Armed " + main + " <- " + next + ", formats known: " + formats.keySet());
    }

    /**
     * Starts mixing. 1 when it's on, 0 when the formats aren't known yet (try again shortly), -1 when the songs can't be
     * mixed this way (different formats): then the caller crossfades the old way.
     */
    public static synchronized int startMix() {
        if (status == MIXING) return 1;
        if (status != ARMED) return -1;
        mainFormat = formats.get(mainId);
        nextFormat = formats.get(nextId);
        if (mainFormat == null || nextFormat == null) return 0;
        if (!sameFormat(mainFormat, nextFormat)) {
            Log.i(TAG, "Can't mix " + nextFormat + " into " + mainFormat);
            return -1;
        }
        gainOut = targetOut = 1f;
        gainIn = targetIn = 0f;
        gainStep = 1f / Math.max(1, mainFormat.sampleRate * GAIN_GLIDE_MILLIS / 1000);
        incomingEnvelope = 0f;
        bufferFadeStep = 1f / Math.max(1, mainFormat.sampleRate * BUFFER_FADE_MILLIS / 1000);
        status = MIXING;
        Log.i(TAG, "Mixing " + nextFormat);
        return 1;
    }

    /** Schedule ahead of the sink's render head. A missed deadline is rejected, never shifted late. */
    public static synchronized int scheduleMix(long startUs, long endUs, double incomingGain) {
        if (fadeStartUs != C.TIME_UNSET && status == MIXING) return 1;
        if (status != ARMED || endUs <= startUs || startUs < 0) return -1;
        Long rendered = renderedUntilUs.get(mainId);
        if (rendered == null) return 0;
        if (rendered > startUs) return -1;
        AudioFormat next = formats.get(nextId);
        if (next == null || writtenFrames * 1000L < (long) PRIMING_MILLIS * next.sampleRate) return 0;
        int result = startMix();
        if (result != 1) return result;
        fadeStartUs = startUs;
        fadeEndUs = endUs;
        scheduledGain = (float) Math.max(0, Math.min(4, incomingGain));
        Log.i(TAG, "Scheduled fade at " + startUs + " to " + endUs + " us; rendered through " + rendered);
        return 1;
    }

    static synchronized void onPcmTime(String id, long endUs) {
        if (endUs != C.TIME_UNSET) renderedUntilUs.put(id, endUs);
        if (id != null && id.equals(mainId) && status == CATCHING_UP) {
            long now = nanoTime.getAsLong();
            if (lastInputNanos != 0) maxInputGapNanos = Math.max(maxInputGapNanos, now - lastInputNanos);
            lastInputNanos = now;
        }
    }

    /** The volume of the current song ([out]) and of the next one ([in]) in the mix. */
    public static synchronized void setGains(double out, double in) {
        // A late Flutter fade tick mustn't undo the native hand-over's return to unity.
        if (fadeStartUs != C.TIME_UNSET || status == CATCHING_UP || status == DONE) return;
        targetOut = (float) Math.max(0, Math.min(1, out));
        targetIn = (float) Math.max(0, Math.min(4, in));
    }

    public static synchronized int status() {
        return status;
    }

    /** A player went away. */
    static synchronized void forget(String id) {
        if (id == null) return;
        formats.remove(id);
        renderedUntilUs.remove(id);
        if (id.equals(mainId) || id.equals(nextId)) Log.i(TAG, "Player " + id + " left the crossfade (status " + status + ")");
    }

    /** Something went wrong in the mixing itself: stop, so the music carries on unmixed instead of stopping. */
    static synchronized void onError(Throwable error) {
        Log.e(TAG, "Crossfade mixing failed; playing on without it", error);
        reset();
    }

    /** Stops everything; the main player plays its own sound again. */
    public static synchronized void disarm() {
        reset();
    }

    private static void reset() {
        mainId = null;
        nextId = null;
        status = OFF;
        mainFormat = null;
        nextFormat = null;
        ring = null;
        capacityFrames = 0;
        writtenFrames = 0;
        readFrames = 0;
        primed = false;
        boundaryPending = false;
        waitingForFlush = false;
        ownFrames = 0;
        catchUpStartNanos = 0;
        catchUpPlayed = 0;
        boundaryOffsetFrames = -1;
        usingMain = false;
        mainBlend = 0f;
        targetOut = gainOut = 1f;
        targetIn = gainIn = 0f;
        incomingEnvelope = 0f;
        fadeStartUs = C.TIME_UNSET;
        pauseNanos = -1;
    }

    private static boolean sameFormat(AudioFormat a, AudioFormat b) {
        return a.sampleRate == b.sampleRate && a.channelCount == b.channelCount && a.encoding == b.encoding;
    }

    // ---- Audio sink side (main player) ----

    /** The main player's output is about to get the first sample of a new song. True when that's the hand-over. */
    static synchronized boolean markBoundary(String id) {
        if (id == null || !id.equals(mainId) || status != MIXING) return false;
        boundaryPending = true;
        // The main player's own copy of the new song must be normalized like the collected one from its first
        // sample. Flutter only updates the gain once the track change is heard, after the catch-up has processed it,
        // so the level would jump at the blend and again when that late update lands.
        NormalizationSettings.copy(nextId, mainId);
        return true;
    }

    /** How many frames of the new song were already played when the main player reached it, once known; else -1. */
    static synchronized long boundaryOffsetFrames(String id) {
        if (id == null || !id.equals(mainId)) return -1;
        return boundaryOffsetFrames;
    }

    static synchronized int mainSampleRate() {
        return mainFormat == null ? 0 : mainFormat.sampleRate;
    }

    /** The main player seeked or stopped: whatever was going on is off. */
    static synchronized void onSinkFlush(String id) {
        renderedUntilUs.remove(id);
        if (id != null && id.equals(mainId) && (status == MIXING || status == CATCHING_UP)) {
            Log.i(TAG, "Main player flushed during a crossfade (status " + status + ")");
            boundaryPending = false;
            waitingForFlush = false;
            status = ABORTED;
        }
    }

    // ---- Processor side ----

    static synchronized void onConfigure(String id, AudioFormat format) {
        if (id == null) return;
        formats.put(id, format);
        if (id.equals(mainId) && boundaryPending && waitingForFlush) {
            // Reconfigured at the hand-over: the format has to stay the same, or the samples don't line up.
            if (nextFormat != null && !sameFormat(format, nextFormat)) {
                Log.w(TAG, "Format changed at the hand-over: " + format + " vs " + nextFormat);
                status = FAILED;
            }
        }
    }

    static synchronized void onQueueEndOfStream(String id) {
        // A pipeline drain at the hand-over: the old song's last samples come out first, the new song after the flush.
        if (id == null || !id.equals(mainId)) return;
        if (status == CATCHING_UP && writtenFrames > 0 && ownFrames == readFrames && readFrames == writtenFrames) {
            // A short incoming song can end entirely through the ring before
            // its own copy catches up. There is no next own sample to trigger
            // the usual blend; all its audio has already been delivered.
            status = DONE;
            event("Hand-over done at end of already-heard source: " + ownFrames + " frames; ring output " + drainedFrames);
            return;
        }
        if (boundaryPending || status == CATCHING_UP) waitingForFlush = true;
    }

    static synchronized void onFlush(String id) {
        // A seek/new stream invalidates the old source position. Scheduling must
        // wait for freshly timestamped PCM rather than reject against stale time.
        renderedUntilUs.remove(id);
        if (id == null || !id.equals(mainId) || !waitingForFlush) return;
        waitingForFlush = false;
        if (status == CATCHING_UP) {
            // What came before the drain was the old song's held-back end (already silent at the end of the fade),
            // not the new song: the new song starts now.
            ownFrames = 0;
        }
    }

    /** Whether [id] is the second player while its sound is collected. */
    static synchronized boolean isCollecting(String id) {
        return id != null && id.equals(nextId) && (status == ARMED || status == MIXING || status == CATCHING_UP);
    }

    /** Whether [id] is the main player while it has to do something other than play its own sound. */
    static synchronized boolean isMixing(String id) {
        return id != null && id.equals(mainId) && (status == MIXING || status == CATCHING_UP || status == FAILED);
    }

    /** Keeps the second player's samples ([input] as [format]), without consuming the buffer. */
    static synchronized void collect(ByteBuffer input, AudioFormat format) {
        int frames = input.remaining() / (format.bytesPerFrame);
        if (frames == 0) return;
        if (ring == null) {
            channels = format.channelCount;
            capacityFrames = format.sampleRate * RING_SECONDS;
            ring = new float[capacityFrames * channels];
        }
        if (writtenFrames + frames - readFrames > capacityFrames) {
            Log.w(TAG, "Collected sound overflowed; giving up on this crossfade");
            status = status == CATCHING_UP ? FAILED : ABORTED;
            return;
        }
        int position = input.position();
        boolean isFloat = format.encoding == C.ENCODING_PCM_FLOAT;
        for (int frame = 0; frame < frames; frame++) {
            int base = (int) ((writtenFrames % capacityFrames) * channels);
            for (int channel = 0; channel < channels; channel++) {
                ring[base + channel] = isFloat
                        ? input.getFloat(position + (frame * channels + channel) * 4)
                        : input.getShort(position + (frame * channels + channel) * 2) / 32768f;
            }
            writtenFrames++;
        }
    }

    private static boolean ringHasFrame() {
        if (ring == null) return false;
        long available = writtenFrames - readFrames;
        if (!primed) {
            if (available * 1000L < (long) PRIMING_MILLIS * nextFormat.sampleRate) return false;
            primed = true;
        }
        if (available <= 0) {
            primed = false;
            return false;
        }
        return true;
    }

    private static long maxCatchUpFrames(int rate) {
        return (long) rate * CATCH_UP_CHUNK_MILLIS / 1000;
    }

    /** Bypass already-heard decoder input before output backpressure can stall it. */
    static synchronized int skipOwn(String id, int frames, int queuedOwnFrames) {
        if (id == null || !id.equals(mainId) || status != CATCHING_UP || usingMain || waitingForFlush) return 0;
        // Normalized own PCM can be waiting inside AudioProcessingPipeline.
        // Reserve those older frames so every one is still discarded before
        // the first audible own sample. Only already-heard audio is bypassed.
        int skip = (int) Math.max(0, Math.min(frames, readFrames - ownFrames - queuedOwnFrames));
        ownFrames += skip;
        bypassedOwnFrames += skip;
        return skip;
    }

    /** Ring output is paced by time, never by the number of main-decoder input frames. */
    static synchronized int drainFrames(String id) {
        if (id == null || !id.equals(mainId) || status != CATCHING_UP || usingMain || waitingForFlush) return 0;
        long now = pauseNanos >= 0 ? pauseNanos : nanoTime.getAsLong();
        if (catchUpStartNanos == 0) catchUpStartNanos = now;
        int rate = mainFormat.sampleRate;
        long due = (now - catchUpStartNanos) * rate / 1_000_000_000L
                + (long) rate * CATCH_UP_LEAD_MILLIS / 1000 - catchUpPlayed;
        return (int) Math.max(0, Math.min(Math.min(due, writtenFrames - readFrames), maxCatchUpFrames(rate)));
    }

    static synchronized void drain(String id, ByteBuffer output, AudioFormat format, int limit) {
        int frames = Math.min(limit, drainFrames(id));
        boolean floats = format.encoding == C.ENCODING_PCM_FLOAT;
        for (int frame = 0; frame < frames; frame++) {
            glide();
            glideBufferedEnvelope();
            int base = (int) ((readFrames % capacityFrames) * channels);
            for (int channel = 0; channel < channels; channel++)
                write(output, ring[base + channel] * gainIn * incomingEnvelope, floats);
            readFrames++;
        }
        catchUpPlayed += frames;
        drainedFrames += frames;
    }

    /** Room the main player's output needs for an input of [inputBytes]: more while catching up. */
    static synchronized int outputCapacity(String id, int inputBytes, AudioFormat format) {
        if (id == null || !id.equals(mainId) || (status != MIXING && status != CATCHING_UP) || mainFormat == null) {
            return inputBytes;
        }
        // Mixing may turn into catching up within this very buffer.
        return inputBytes + (int) maxCatchUpFrames(mainFormat.sampleRate) * format.bytesPerFrame;
    }

    private static void glide() {
        gainOut += Math.max(-gainStep, Math.min(gainStep, targetOut - gainOut));
        gainIn += Math.max(-gainStep, Math.min(gainStep, targetIn - gainIn));
    }

    private static void glideBufferedEnvelope() {
        incomingEnvelope = Math.min(1f, Math.min(incomingEnvelope + bufferFadeStep,
                (writtenFrames - readFrames) * bufferFadeStep));
    }

    /**
     * The main player's processing: [input] in [format] becomes what's written to [output] (which has room for at least
     * as many bytes as the input). Returns false when the main player should just pass its sound through.
     */
    static synchronized boolean mix(ByteBuffer input, ByteBuffer output, AudioFormat format) {
        return mix(input, output, format, C.TIME_UNSET);
    }

    static synchronized boolean mix(ByteBuffer input, ByteBuffer output, AudioFormat format, long timeUs) {
        if (status == FAILED) {
            // Silent, so a failed hand-over doesn't let the new song start over from the top. Consumes the input.
            input.position(input.limit());
            return true;
        }
        if (boundaryPending && !waitingForFlush && status == MIXING) {
            // Usually the next sample is the new song's first. If the sink still drains the old song's end first,
            // onFlush starts the count over.
            boundaryPending = false;
            status = CATCHING_UP;
            ownFrames = 0;
            catchUpStartNanos = pauseNanos >= 0 ? pauseNanos : nanoTime.getAsLong();
            catchUpPlayed = 0;
            boundaryOffsetFrames = readFrames;
            // Keep the current gain/envelope: jumping straight to raw PCM here clicks.
            targetOut = 0f;
            targetIn = 1f;
            usingMain = false;
            mainBlend = 0f;
            lastInputNanos = nanoTime.getAsLong();
            event("Hand-over start: " + readFrames + " incoming frames already heard ("
                    + readFrames * 1000 / mainFormat.sampleRate + " ms)");
        }
        boolean isFloat = format.encoding == C.ENCODING_PCM_FLOAT;
        int ch = format.channelCount;
        int bytesPerSample = isFloat ? 4 : 2;
        int frames = input.remaining() / format.bytesPerFrame;
        int position = input.position();
        if (status == MIXING) {
            for (int frame = 0; frame < frames; frame++) {
                boolean scheduled = fadeStartUs != C.TIME_UNSET;
                long sampleUs = timeUs == C.TIME_UNSET ? C.TIME_UNSET : timeUs + frame * 1_000_000L / format.sampleRate;
                boolean started = !scheduled || (sampleUs != C.TIME_UNSET && sampleUs >= fadeStartUs);
                if (scheduled) {
                    double t = started ? Math.min(1, (double) (sampleUs - fadeStartUs) / (fadeEndUs - fadeStartUs)) : 0;
                    gainOut = (float) Math.cos(t * Math.PI / 2);
                    gainIn = (float) Math.sin(t * Math.PI / 2) * scheduledGain;
                } else glide();
                // Nothing may be collected yet (the next song only just started): then there's no ring to read.
                boolean incoming = started && ringHasFrame();
                // The musical gain may already have risen while priming waited
                // for data. Starting at that gain clicks on the first sample.
                // Also taper the last buffered frames before an underrun, then
                // ease back in on refill instead of switching whole PCM chunks.
                if (incoming) glideBufferedEnvelope();
                else incomingEnvelope = 0f;
                int base = incoming ? (int) ((readFrames % capacityFrames) * channels) : 0;
                for (int channel = 0; channel < ch; channel++) {
                    float own = read(input, position + (frame * ch + channel) * bytesPerSample, isFloat);
                    float sample = own * gainOut;
                    if (incoming) sample += ring[base + channel] * gainIn * incomingEnvelope;
                    write(output, sample, isFloat);
                }
                // Scheduled fades keep their sample alignment even if decoding starves.
                // Missing frames stay missing; a refill mustn't shift the song backwards.
                if (incoming || (scheduled && started)) readFrames++;
            }
            input.position(input.limit());
            return true;
        }
        if (status == CATCHING_UP) {
            long now = nanoTime.getAsLong();
            int rate = mainFormat.sampleRate;
            // A render-loop pump supplies ring output independently. Decoder
            // input must then be free to catch up even when the sink is full;
            // tying more ring output to each input would backpressure decoding.
            if (!outputPumps.contains(mainId)) drain(mainId, output, format, (int) maxCatchUpFrames(rate));
            if (now - lastProgressLogNanos > 5_000_000_000L) {
                lastProgressLogNanos = now;
                Log.i(TAG, "Catching up: own " + ownFrames + " of " + readFrames + " frames, "
                        + (now - catchUpStartNanos) / 1_000_000 + " ms in");
            }
            for (int frame = 0; frame < frames; frame++) {
                if (!usingMain && ownFrames < readFrames) {
                    ownFrames++;
                    continue;
                }
                if (!usingMain) {
                    usingMain = true;
                    // Blend copies of the SAME frames, without replaying or skipping audio. Finish
                    // before the ring runs out; when empty, its envelope already tapered to silence.
                    long available = writtenFrames - readFrames;
                    mainBlendStep = 1f / Math.max(1, Math.min(available,
                            (long) rate * BUFFER_FADE_MILLIS / 1000));
                }
                glide();
                incomingEnvelope = Math.min(1f, incomingEnvelope + bufferFadeStep);
                mainBlend = Math.min(1f, mainBlend + mainBlendStep);
                boolean buffered = writtenFrames > ownFrames;
                int base = buffered ? (int) ((ownFrames % capacityFrames) * channels) : 0;
                for (int channel = 0; channel < ch; channel++) {
                    float own = read(input, position + (frame * ch + channel) * bytesPerSample, isFloat);
                    float sample = buffered ? ring[base + channel] * (1f - mainBlend) + own * mainBlend : own;
                    write(output, sample * gainIn * incomingEnvelope, isFloat);
                }
                ownFrames++;
                readFrames = ownFrames;
                // Keep processing across small buffers until every ramp is finished. DONE lets
                // Flutter dispose the secondary decoder and makes subsequent buffers pass through.
                if (status != DONE && mainBlend == 1f && incomingEnvelope == 1f && gainIn == 1f) {
                    status = DONE;
                    event("Hand-over done at frame " + ownFrames + " after "
                            + (now - catchUpStartNanos) / 1_000_000 + " ms; ring output " + drainedFrames
                            + " frames, max input gap " + maxInputGapNanos / 1_000_000 + " ms");
                }
            }
            input.position(input.limit());
            return true;
        }
        return false;
    }

    private static float read(ByteBuffer buffer, int index, boolean isFloat) {
        return isFloat ? buffer.getFloat(index) : buffer.getShort(index) / 32768f;
    }

    private static void write(ByteBuffer buffer, float sample, boolean isFloat) {
        if (isFloat) {
            buffer.putFloat(sample);
        } else {
            buffer.putShort((short) Math.max(Short.MIN_VALUE, Math.min(Short.MAX_VALUE, Math.round(sample * 32768f))));
        }
    }
}
