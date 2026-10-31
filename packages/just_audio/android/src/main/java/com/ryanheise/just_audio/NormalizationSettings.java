package com.ryanheise.just_audio;

import java.util.concurrent.ConcurrentHashMap;

/** Immutable snapshots shared by the platform and audio threads. */
final class NormalizationSettings {
    static final class Value {
        final boolean enabled;
        final double gain, ceiling;
        Value(boolean enabled, double gainDb, double headroomDb) {
            this.enabled = enabled;
            gain = enabled ? Math.pow(10, Math.max(-60, Math.min(24, gainDb)) / 20) : 1;
            ceiling = Math.pow(10, (-1 - Math.max(0, Math.min(60, headroomDb))) / 20);
        }
    }
    private static final ConcurrentHashMap<String, Value> values = new ConcurrentHashMap<>();
    private static final Value OFF = new Value(false, 0, 0);
    static Value get(String id) { return values.getOrDefault(id, OFF); }
    static void set(String id, boolean enabled, double gain, double headroom) {
        if (id == null || !Double.isFinite(gain) || !Double.isFinite(headroom)) return;
        values.put(id, new Value(enabled, gain, headroom));
    }
    static void remove(String id) { values.remove(id); }
    /** Gives [to] the settings of [from], when [from] has any. */
    static void copy(String from, String to) {
        if (from == null || to == null) return;
        Value value = values.get(from);
        if (value != null) values.put(to, value);
    }
}
