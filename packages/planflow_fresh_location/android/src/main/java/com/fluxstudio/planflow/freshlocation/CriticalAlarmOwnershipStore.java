package com.fluxstudio.planflow.freshlocation;

import android.content.Context;
import android.content.SharedPreferences;
import java.util.LinkedHashMap;
import java.util.Map;
import org.json.JSONObject;
import com.fluxstudio.planflow.freshlocation.CriticalAlarmOwnershipCoordinator.Owner;
import com.fluxstudio.planflow.freshlocation.CriticalAlarmOwnershipCoordinator.Failure;

/** Dedicated app-private file. Never migrate legacy Dart preferences. */
final class CriticalAlarmOwnershipStore implements CriticalAlarmOwnershipCoordinator.Store {
    private static final String FILE = "planflow_critical_alarm_ownership_v1";
    // Failed rollback makes memory/disk state uncertain: fail every engine closed
    // until restart, never acknowledge a phantom owner in SharedPreferences memory.
    private static boolean unavailable;
    private final SharedPreferences preferences;
    CriticalAlarmOwnershipStore(Context context) {
        preferences = context.getApplicationContext().getSharedPreferences(FILE, Context.MODE_PRIVATE);
    }
    private void available() { if (unavailable) throw new Failure("storage_unavailable"); }
    @Override public Owner read(String eventId) {
        synchronized (CriticalAlarmOwnershipCoordinator.LOCK) {
            available();
            Map<String, ?> all = preferences.getAll();
            if (!all.containsKey(eventId)) return null;
            return decode(all.get(eventId));
        }
    }
    @Override public Map<String, Owner> list() {
        synchronized (CriticalAlarmOwnershipCoordinator.LOCK) {
            available();
            Map<String, Owner> result = new LinkedHashMap<>();
            for (Map.Entry<String, ?> entry : preferences.getAll().entrySet()) {
                if (entry.getKey().isEmpty()) throw new Failure("corrupt_owner");
                result.put(entry.getKey(), decode(entry.getValue()));
            }
            return result;
        }
    }
    private static long integer(JSONObject json, String key) throws Exception {
        Object value = json.get(key);
        if (!(value instanceof Long) && !(value instanceof Integer)) throw new Exception();
        return ((Number) value).longValue();
    }
    private static Owner decode(Object raw) {
        try {
            if (!(raw instanceof String)) throw new Exception();
            JSONObject json = new JSONObject((String) raw);
            if (integer(json, "version") != 1 || !json.has("claimedTrigger")) throw new Exception();
            if (json.length() != (json.has("metadataJson") ? 6 : 5)) throw new Exception();
            Object generation = json.get("generation");
            if (!(generation instanceof String)) throw new Exception();
            String metadata = null;
            if (json.has("metadataJson")) {
                Object value = json.get("metadataJson");
                if (!(value instanceof String)) throw new Exception();
                metadata = (String) value;
            }
            Long claimed = json.isNull("claimedTrigger") ? null : integer(json, "claimedTrigger");
            return new Owner((String) generation, integer(json, "triggerAt"),
                    integer(json, "originalNotifyAt"), claimed, metadata);
        } catch (Exception ignored) { throw new Failure("corrupt_owner"); }
    }
    private static String encode(Owner owner) {
        try {
            JSONObject json = new JSONObject();
            json.put("version", 1); json.put("generation", owner.generation);
            json.put("triggerAt", owner.triggerAt); json.put("originalNotifyAt", owner.originalNotifyAt);
            json.put("claimedTrigger", owner.claimedTrigger == null ? JSONObject.NULL : owner.claimedTrigger);
            if (owner.metadataJson != null) json.put("metadataJson", owner.metadataJson);
            return json.toString();
        } catch (Exception ignored) { throw new Failure("storage_failure"); }
    }
    private boolean commit(String eventId, String value) {
        SharedPreferences.Editor edit = preferences.edit();
        if (value == null) edit.remove(eventId); else edit.putString(eventId, value);
        return edit.commit();
    }
    @Override public void write(String eventId, Owner owner) {
        synchronized (CriticalAlarmOwnershipCoordinator.LOCK) {
            available();
            Owner old = read(eventId); // Validate unknown/corrupt record before overwrite.
            String prior = old == null ? null : (String) preferences.getAll().get(eventId);
            String next = owner == null ? null : encode(owner);
            boolean success;
            try { success = commit(eventId, next); } catch (RuntimeException ignored) { success = false; }
            if (success) return;
            boolean restored;
            try { restored = commit(eventId, prior); } catch (RuntimeException ignored) { restored = false; }
            if (!restored) unavailable = true;
            throw new Failure(restored ? "storage_failure" : "storage_unavailable");
        }
    }
}
