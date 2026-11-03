package com.ryanheise.just_audio;

import android.content.Context;
import androidx.annotation.NonNull;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel.MethodCallHandler;
import io.flutter.plugin.common.MethodChannel.Result;
import java.util.HashMap;
import java.util.List;
import java.util.ArrayList;
import java.util.Map;

public class MainMethodCallHandler implements MethodCallHandler {

    private final Context applicationContext;
    private final BinaryMessenger messenger;

    private final Map<String, AudioPlayer> players = new HashMap<>();

    /** Every live player, by id, for Finamp+ crossfades that need exact positions. */
    private static final Map<String, AudioPlayer> allPlayers = new java.util.concurrent.ConcurrentHashMap<>();

    /** Where the player with [id] is right now in milliseconds, or null when it's unknown or seeking. Main thread only. */
    public static Long exactPosition(String id) {
        AudioPlayer player = id == null ? null : allPlayers.get(id);
        return player == null ? null : player.exactPosition();
    }

    public MainMethodCallHandler(Context applicationContext,
            BinaryMessenger messenger) {
        this.applicationContext = applicationContext;
        this.messenger = messenger;
    }

    @Override
    public void onMethodCall(MethodCall call, @NonNull Result result) {
        switch (call.method) {
        case "setVoiceEnvelope": {
            String id = call.argument("id");
            Number gain = call.argument("gain");
            Number duration = call.argument("durationMs");
            if (!players.containsKey(id) || gain == null || !Double.isFinite(gain.doubleValue())) {
                result.error("Invalid voice envelope", null, null);
                break;
            }
            if (!players.get(id).supportsVoiceEnvelope()) {
                // Preserve the user's offload choice; Dart uses the existing
                // output-volume ramp when PCM processing would be bypassed.
                VoiceEnvelopeProcessor.set(id, 1, 0);
                result.success(null);
                break;
            }
            Long position = exactPosition(id);
            long leadMs = CrossfadeBridge.outputLeadMillis(id, position);
            VoiceEnvelopeProcessor.set(id, gain.doubleValue(), duration == null ? 0 : duration.intValue());
            result.success(leadMs);
            break;
        }
        case "outputLead": {
            // How far ahead of what's heard the music is processed: an envelope set now starts this much later.
            String id = call.argument("id");
            if (!players.containsKey(id) || !players.get(id).supportsVoiceEnvelope()) {
                result.success(null);
                break;
            }
            result.success(CrossfadeBridge.outputLeadMillis(id, exactPosition(id)));
            break;
        }
        case "setNormalization": {
            Number gain = call.argument("gainDb");
            Number headroom = call.argument("headroomDb");
            NormalizationSettings.set(call.argument("id"), Boolean.TRUE.equals(call.argument("enabled")),
                gain == null ? 0 : gain.doubleValue(), headroom == null ? 0 : headroom.doubleValue());
            AudioPlayer player = players.get((String) call.argument("id"));
            if (player != null) player.refreshNormalizationOffload();
            result.success(null);
            break;
        }
        case "init": {
            String id = call.argument("id");
            if (players.containsKey(id)) {
                result.error("Platform player " + id + " already exists", null, null);
                break;
            }
            List<Object> rawAudioEffects = call.argument("androidAudioEffects");
            AudioPlayer created;
            players.put(
                id,
                created = new AudioPlayer(
                    applicationContext,
                    messenger,
                    id,
                    call.argument("audioLoadConfiguration"),
                    rawAudioEffects,
                    call.argument("androidAudioOffloadPreferences"),
                    call.argument("androidOffloadSchedulingEnabled"),
		    call.argument("useLazyPreparation")
                )
            );
            allPlayers.put(id, created);
            result.success(null);
            break;
        }
        case "disposePlayer": {
            String id = call.argument("id");
            AudioPlayer player = players.get(id);
            if (player != null) {
                player.dispose();
                players.remove(id);
                allPlayers.remove(id);
                NormalizationSettings.remove(id);
                VoiceEnvelopeProcessor.remove(id);
            }
            result.success(new HashMap<String, Object>());
            break;
        }
        case "disposeAllPlayers": {
            dispose();
            result.success(new HashMap<String, Object>());
            break;
        }
        default:
            result.notImplemented();
            break;
        }
    }

    void dispose() {
        for (AudioPlayer player : new ArrayList<AudioPlayer>(players.values())) {
            player.dispose();
            for (Map.Entry<String, AudioPlayer> entry : allPlayers.entrySet()) {
                if (entry.getValue() == player) {
                    NormalizationSettings.remove(entry.getKey());
                    VoiceEnvelopeProcessor.remove(entry.getKey());
                }
            }
            allPlayers.values().remove(player);
        }
        players.clear();
    }
}
