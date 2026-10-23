package com.ryanheise.just_audio;

import androidx.media3.common.C;
import androidx.media3.common.Format;
import androidx.media3.common.audio.AudioProcessingPipeline;
import androidx.media3.common.audio.AudioProcessor.AudioFormat;
import androidx.media3.exoplayer.audio.AudioSink;
import com.google.common.collect.ImmutableList;
import java.lang.reflect.Proxy;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.ArrayDeque;

/** Real-time output, rather than an unpaced decoder-only hand-over test. */
public final class CrossfadeRealtimeTest {
    private static final int RATE = 48000, TICK = 480, CAPACITY = RATE / 4;
    private static final AudioFormat FORMAT = new AudioFormat(RATE, 2, C.ENCODING_PCM_FLOAT);
    private static long now;

    public static void main(String[] args) throws Exception {
        try {
            CrossfadeBridge.nanoTime = () -> now;
            int failures = 0;
            for (int speed : new int[] {20, 5, 2}) {
                for (boolean stalls : new boolean[] {false, true}) {
                    try { run(speed, stalls); }
                    catch (AssertionError error) { failures++; System.out.println(error.getMessage()); }
                }
            }
            try { run(2, true, true); }
            catch (AssertionError error) { failures++; System.out.println(error.getMessage()); }
            provenance();
            endOfAlreadyHeardSource();
            sinkBackpressure();
            assert failures == 0 : failures + " real-time scenarios failed";
        } finally {
            CrossfadeBridge.disarm();
            CrossfadeBridge.nanoTime = System::nanoTime;
        }
        System.out.println("Crossfade real-time: 250 ms sink, 20x/5x/2x decoders, 300 ms stalls, phase continuity and exact onset passed");
    }

    private static void provenance() throws Exception {
        CrossfadeBridge.disarm();
        CrossfadeStreamTiming timing = new CrossfadeStreamTiming();
        NormalizationAudioProcessor normalization = new NormalizationAudioProcessor("provenance-main", timing);
        CrossfadeAudioProcessor crossfade = new CrossfadeAudioProcessor("provenance-main", timing);
        normalization.configure(FORMAT); normalization.flush();
        crossfade.configure(FORMAT); crossfade.flush();
        CrossfadeBridge.registerOutputPump("provenance-main");
        CrossfadeBridge.arm("provenance-main", "provenance-next");
        CrossfadeBridge.onConfigure("provenance-next", FORMAT);
        ByteBuffer ring = tone(0, RATE * 2);
        CrossfadeBridge.collect(ring, FORMAT);
        assert CrossfadeBridge.startMix() == 1;
        CrossfadeBridge.setGains(0, 1);
        crossfade.queueInput(buffer(RATE / 5)); crossfade.getOutput();
        assert CrossfadeBridge.markBoundary("provenance-main");
        normalization.queueInput(buffer(10));
        crossfade.queueInput(normalization.getOutput()); crossfade.getOutput();
        timing.pumping = true;
        normalization.queueInput(buffer(1024));
        ByteBuffer deferredCarrier = normalization.getOutput();
        timing.pumping = false; // AudioProcessingPipeline delivers it on a later real-input call.
        crossfade.queueInput(deferredCarrier);
        ByteBuffer output = crossfade.getOutput().order(ByteOrder.nativeOrder());
        assert output.remaining() == 1024 * FORMAT.bytesPerFrame : "deferred carrier was mistaken for decoder input";
        for (int frame = 0; frame < 1024; frame++)
            for (int channel = 0; channel < 2; channel++)
                assert Math.abs(output.getFloat() - sample(RATE / 5 + frame, channel)) < 1e-6
                        : "carrier changed PCM phase";
        assert ((Number) CrossfadeBridge.diagnostics().get("ownFrames")).longValue() == 10 : "carrier advanced own frames";
        normalization.queueInput(buffer(1024));
        ByteBuffer deferredOwn = normalization.getOutput();
        timing.pumping = true; // Conversely, real input may emerge during a ring drain.
        crossfade.queueInput(deferredOwn);
        assert !crossfade.getOutput().hasRemaining() : "real decoder input was replaced by extra ring audio";
        assert ((Number) CrossfadeBridge.diagnostics().get("ownFrames")).longValue() == 1034;
        timing.pumping = false;
        normalization.queueInput(buffer(1024));
        ByteBuffer queuedOwn = normalization.getOutput();
        long read = ((Number) CrossfadeBridge.diagnostics().get("ringFrames")).longValue();
        int skipped = CrossfadeBridge.skipOwn("provenance-main", RATE * 10, timing.queuedOwnFrames());
        timing.advance(skipped);
        assert skipped == read - 1034 - 1024 : "bypass did not reserve older deferred own PCM";
        crossfade.queueInput(queuedOwn);
        assert !crossfade.getOutput().hasRemaining() : "deferred own frames became audible out of order";
        ByteBuffer aligned = tone((int) read, 1024);
        normalization.queueInput(aligned);
        crossfade.queueInput(normalization.getOutput());
        output = crossfade.getOutput().order(ByteOrder.nativeOrder());
        assert output.remaining() == 1024 * FORMAT.bytesPerFrame;
        for (int frame = 0; frame < 1024; frame++)
            for (int channel = 0; channel < 2; channel++)
                assert Math.abs(output.getFloat() - sample(read + frame, channel)) < 1e-6
                        : "bypass changed hand-over PCM phase/order";
        assert CrossfadeBridge.status() == CrossfadeBridge.DONE;
        crossfade.reset(); normalization.reset();
        CrossfadeBridge.unregisterOutputPump("provenance-main");
        System.out.println("Deferred normalized PCM retains carrier/decoder provenance under downstream backpressure");
    }

    private static void endOfAlreadyHeardSource() throws Exception {
        for (int unheard : new int[] {0, 1}) {
            CrossfadeBridge.disarm();
            CrossfadeAudioProcessor processor = new CrossfadeAudioProcessor("eos-main");
            processor.configure(FORMAT); processor.flush();
            CrossfadeBridge.registerOutputPump("eos-main");
            CrossfadeBridge.arm("eos-main", "eos-next");
            CrossfadeBridge.onConfigure("eos-next", FORMAT);
            CrossfadeBridge.collect(tone(0, RATE + unheard), FORMAT);
            assert CrossfadeBridge.startMix() == 1;
            CrossfadeBridge.setGains(0, 1);
            processor.queueInput(buffer(RATE)); processor.getOutput();
            assert CrossfadeBridge.markBoundary("eos-main");
            processor.queueInput(buffer(1)); processor.getOutput();
            assert CrossfadeBridge.skipOwn("eos-main", RATE, 0) == RATE - 1;
            CrossfadeBridge.onQueueEndOfStream("eos-main");
            assert CrossfadeBridge.status() == (unheard == 0 ? CrossfadeBridge.DONE : CrossfadeBridge.CATCHING_UP)
                    : "EOS bypass either stayed stuck or discarded unheard incoming PCM";
            processor.reset();
            CrossfadeBridge.unregisterOutputPump("eos-main");
        }
        System.out.println("An entirely already-heard short source completes at EOS; unheard PCM is retained");
    }

    private static void sinkBackpressure() throws Exception {
        CrossfadeBridge.disarm();
        CrossfadeStreamTiming timing = new CrossfadeStreamTiming();
        AudioProcessingPipeline pipeline = new AudioProcessingPipeline(ImmutableList.of(
                new NormalizationAudioProcessor("sink-main", timing), new CrossfadeAudioProcessor("sink-main", timing)));
        pipeline.configure(FORMAT); pipeline.flush();
        boolean[] blocked = {false}, discontinuity = {true};
        long[] epoch = {0}, submitted = {0};
        ByteBuffer[] pending = {null};
        ArrayDeque<Float> output = new ArrayDeque<>();
        AudioSink delegate = (AudioSink) Proxy.newProxyInstance(AudioSink.class.getClassLoader(), new Class<?>[] {AudioSink.class},
                (proxy, method, args) -> {
                    if (method.getName().equals("handleDiscontinuity")) { discontinuity[0] = true; return null; }
                    if (method.getName().equals("handleBuffer")) {
                        ByteBuffer input = (ByteBuffer) args[0];
                        assert pending[0] == null || pending[0] == input : "sink input changed under backpressure";
                        pending[0] = input;
                        if (blocked[0]) return false;
                        long pts = (Long) args[1];
                        if (discontinuity[0]) { epoch[0] = pts; submitted[0] = 0; discontinuity[0] = false; }
                        assert Math.abs(pts - epoch[0] - submitted[0] * 1_000_000 / RATE) <= 2
                                : "inserted/bypassed input timestamp mismatch: " + pts + ", submitted " + submitted[0];
                        int frames = input.remaining() / FORMAT.bytesPerFrame;
                        pipeline.queueInput(input);
                        for (int pass = 0; pass < 3; pass++) {
                            ByteBuffer pcm = pipeline.getOutput().order(ByteOrder.nativeOrder());
                            while (pcm.hasRemaining()) output.add(pcm.getFloat());
                            pipeline.queueInput(androidx.media3.common.audio.AudioProcessor.EMPTY_BUFFER);
                        }
                        assert !input.hasRemaining();
                        submitted[0] += frames;
                        pending[0] = null;
                        return true;
                    }
                    Class<?> result = method.getReturnType();
                    if (result == boolean.class) return false;
                    if (result == long.class) return 0L;
                    if (result == int.class) return 0;
                    return null;
                });
        CrossfadeAudioSink sink = new CrossfadeAudioSink(delegate, "sink-main", timing);
        sink.configure(new Format.Builder().setSampleRate(RATE).setChannelCount(2).setPcmEncoding(C.ENCODING_PCM_FLOAT).build(), 0, null);
        CrossfadeBridge.arm("sink-main", "sink-next");
        CrossfadeBridge.onConfigure("sink-next", FORMAT);
        CrossfadeBridge.collect(tone(0, RATE * 2), FORMAT);
        assert CrossfadeBridge.startMix() == 1;
        CrossfadeBridge.setGains(0, 1);
        timing.onBuffer(0);
        assert sink.handleBuffer(buffer(RATE / 5), 0, 1);
        output.clear();
        pipeline.flush(); timing.onBuffer(0);
        sink.handleDiscontinuity();
        assert sink.handleBuffer(tone(0, 10), 24_000_000, 1);
        assert CrossfadeBridge.status() == CrossfadeBridge.CATCHING_UP;
        blocked[0] = true;
        sink.pump(); // A carrier is held by the output sink.
        assert sink.handleBuffer(tone(10, 5000), 24_000_000 + 10L * 1_000_000 / RATE, 1)
                : "already-heard decoder input waited for the full output sink";
        ByteBuffer partial = tone(5010, 6000);
        long partialPts = 24_000_000 + 5010L * 1_000_000 / RATE;
        assert !sink.handleBuffer(partial, partialPts, 1);
        assert partial.position() == 4590 * FORMAT.bytesPerFrame : "partial decoder bypass chose the wrong frame";
        blocked[0] = false;
        assert sink.handleBuffer(partial, partialPts, 1) : "retry of partially bypassed input stalled";
        assert sink.handleBuffer(tone(11010, 12000), 24_000_000 + 11010L * 1_000_000 / RATE, 1);
        assert CrossfadeBridge.status() == CrossfadeBridge.DONE;
        for (int frame = RATE / 5; !output.isEmpty(); frame++)
            for (int channel = 0; channel < 2; channel++)
                assert Math.abs(output.remove() - sample(frame, channel)) < 1e-6
                        : "sink backpressure changed PCM phase/frame order";
        sink.reset(); pipeline.reset(); CrossfadeBridge.disarm();
        System.out.println("Sink backpressure: independent decoder bypass, partial-buffer retries, timestamps and exact PCM order passed");
    }

    private static void run(int speed, boolean stalls) throws Exception {
        run(speed, stalls, false);
    }

    private static void run(int speed, boolean stalls, boolean pause) throws Exception {
        CrossfadeBridge.disarm();
        CrossfadeStreamTiming timing = new CrossfadeStreamTiming();
        CrossfadeAudioProcessor processor = new CrossfadeAudioProcessor("realtime-main", timing);
        processor.configure(FORMAT);
        processor.flush();
        CrossfadeBridge.registerOutputPump("realtime-main");
        timing.onBuffer(0);
        ArrayDeque<ByteBuffer> sink = new ArrayDeque<>();
        ByteBuffer pending = null;
        int queued = 0, own = 0, outgoing = 0, collected = 0, outputFrame = 0;
        int underruns = 0;
        long boundaryTick = -1, doneTick = -1, firstAudible = -1;
        boolean armed = false, boundary = false;
        double credit = 0;
        for (int tick = 0; tick < 9000; tick++) {
            now = 1_000_000_000L + tick * 10_000_000L;
            if (pause && boundaryTick >= 0 && tick == boundaryTick + 60) CrossfadeBridge.playing("realtime-main", false);
            if (pause && boundaryTick >= 0 && tick >= boundaryTick + 60 && tick < boundaryTick + 260) continue;
            if (pause && boundaryTick >= 0 && tick == boundaryTick + 260) CrossfadeBridge.playing("realtime-main", true);
            if (tick >= 800) {
                if (!armed) {
                    CrossfadeBridge.arm("realtime-main", "realtime-next");
                    CrossfadeBridge.onConfigure("realtime-next", FORMAT);
                    armed = true;
                }
                CrossfadeBridge.collect(tone(collected, TICK), FORMAT);
                collected += TICK;
                if (tick == 820) assert CrossfadeBridge.scheduleMix(10_000_000, 17_000_000, 1) == 1;
            }
            boolean stall = stalls && boundaryTick >= 0 && CrossfadeBridge.status() == CrossfadeBridge.CATCHING_UP
                    && ((tick - boundaryTick >= 20 && tick - boundaryTick < 50)
                    || (tick - boundaryTick >= 120 && tick - boundaryTick < 150));
            credit = Math.min(RATE * 2, credit + (stall ? 0 : speed * TICK));
            while (true) {
                if (pending == null || !pending.hasRemaining()) {
                    int buffered = queued < CAPACITY ? CrossfadeBridge.drainFrames("realtime-main") : 0;
                    if (buffered > 0) {
                        timing.pumping = true;
                        try { processor.queueInput(buffer(buffered)); }
                        finally { timing.pumping = false; }
                    } else if (stall || credit < TICK) break;
                    else if (outgoing < RATE * 21) {
                        credit -= TICK;
                        processor.queueInput(buffer(TICK));
                        outgoing += TICK;
                    } else {
                        credit -= TICK;
                        if (!boundary) {
                            assert CrossfadeBridge.markBoundary("realtime-main");
                            CrossfadeBridge.onQueueEndOfStream("realtime-main");
                            CrossfadeBridge.onFlush("realtime-main");
                            boundary = true;
                            boundaryTick = tick;
                        }
                        processor.queueInput(tone(own, TICK));
                        own += TICK;
                    }
                    pending = processor.getOutput().order(ByteOrder.nativeOrder());
                    if (!pending.hasRemaining()) continue;
                    // Check actual PCM order even if the wall-clock simulation underruns.
                    ByteBuffer check = pending.duplicate().order(ByteOrder.nativeOrder());
                    while (check.hasRemaining()) {
                        float left = check.getFloat(), right = check.getFloat();
                        long incoming = outputFrame - RATE * 10L;
                        double t = Math.max(0, Math.min(1, incoming / (RATE * 7.0)));
                        double gain = Math.sin(t * Math.PI / 2) * Math.min(1, (incoming + 1.0) / (RATE / 200));
                        float expectedLeft = incoming < 0 ? 0 : sample(incoming, 0) * (float) gain;
                        float expectedRight = incoming < 0 ? 0 : sample(incoming, 1) * (float) gain;
                        assert Math.abs(left - expectedLeft) < .00002 : "left frame repeated/skipped at " + outputFrame;
                        assert Math.abs(right - expectedRight) < .00002 : "right frame repeated/skipped at " + outputFrame;
                        if (firstAudible < 0 && (Math.abs(left) + Math.abs(right)) > 0) firstAudible = outputFrame;
                        outputFrame++;
                    }
                }
                if (queued == CAPACITY) break;
                int frames = Math.min(CAPACITY - queued, pending.remaining() / FORMAT.bytesPerFrame);
                ByteBuffer part = pending.slice().order(ByteOrder.nativeOrder());
                part.limit(frames * FORMAT.bytesPerFrame);
                sink.add(part);
                pending.position(pending.position() + part.remaining());
                queued += frames;
            }
            int drain = TICK;
            if (queued < drain && tick >= 1000) underruns++;
            queued = Math.max(0, queued - drain);
            while (drain > 0 && !sink.isEmpty()) {
                ByteBuffer head = sink.peek();
                int take = Math.min(drain, head.remaining() / FORMAT.bytesPerFrame);
                head.position(head.position() + take * FORMAT.bytesPerFrame);
                drain -= take;
                if (!head.hasRemaining()) sink.remove();
            }
            if (CrossfadeBridge.status() == CrossfadeBridge.DONE && doneTick < 0) doneTick = tick;
            if (doneTick >= 0 && tick >= doneTick + 200) break;
        }
        System.out.println("Decoder " + speed + "x, stalls=" + stalls + ", pause=" + pause + ": underruns=" + underruns
                + ", first incoming frame=" + firstAudible + ", catch-up ms=" + (doneTick - boundaryTick) * 10
                + ", own=" + own + ", stats=" + CrossfadeBridge.diagnostics());
        assert doneTick >= 0 : "hand-over never completed";
        assert firstAudible == RATE * 10L + 1 : "incoming song did not start at exactly 10 s";
        assert underruns == 0 : "output underruns with buffered incoming audio: " + underruns;
        processor.reset();
        CrossfadeBridge.unregisterOutputPump("realtime-main");
    }

    private static ByteBuffer buffer(int frames) {
        return ByteBuffer.allocateDirect(frames * FORMAT.bytesPerFrame).order(ByteOrder.nativeOrder());
    }

    private static float sample(long frame, int channel) {
        double phase = 2 * Math.PI * 173 * frame / RATE;
        return (float) (.12 * (channel == 0 ? Math.sin(phase) : Math.cos(phase)));
    }

    private static ByteBuffer tone(int start, int frames) {
        ByteBuffer data = buffer(frames);
        for (int i = 0; i < frames; i++) data.putFloat(sample(start + i, 0)).putFloat(sample(start + i, 1));
        data.flip();
        return data;
    }
}
