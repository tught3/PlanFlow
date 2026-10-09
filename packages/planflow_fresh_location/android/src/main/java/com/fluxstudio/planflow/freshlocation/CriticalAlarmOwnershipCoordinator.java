package com.fluxstudio.planflow.freshlocation;

import java.util.LinkedHashMap;
import java.util.Map;

/** Same-process arbitration for UI and headless Flutter engines. No Dart-side cache. */
public final class CriticalAlarmOwnershipCoordinator {
    static final Object LOCK = new Object();
    public interface Store {
        Owner read(String eventId);
        Map<String, Owner> list();
        /** Must be durable or throw; on failure restore old state or fail closed. */
        void write(String eventId, Owner owner);
    }
    public static final class Failure extends RuntimeException {
        private static final long serialVersionUID = 1L;
        public final String code;
        public Failure(String code) { super(code); this.code = code; }
    }
    public static final class Owner {
        public final String generation;
        public final long triggerAt, originalNotifyAt;
        public final Long claimedTrigger;
        public final String metadataJson;
        public Owner(String generation, long triggerAt, long originalNotifyAt,
                     Long claimedTrigger, String metadataJson) {
            identifier(generation);
            if (metadataJson != null && metadataJson.length() > 8192) invalid();
            if (claimedTrigger != null && claimedTrigger.longValue() != triggerAt) invalid();
            this.generation = generation; this.triggerAt = triggerAt;
            this.originalNotifyAt = originalNotifyAt; this.claimedTrigger = claimedTrigger;
            this.metadataJson = metadataJson;
        }
        public Map<String, Object> toMap() {
            Map<String, Object> out = new LinkedHashMap<>();
            out.put("generation", generation); out.put("triggerAt", triggerAt);
            out.put("originalNotifyAt", originalNotifyAt); out.put("claimedTrigger", claimedTrigger);
            if (metadataJson != null) out.put("metadataJson", metadataJson);
            return out;
        }
    }
    private final Store store;
    public CriticalAlarmOwnershipCoordinator(Store store) { this.store = store; }
    static void invalid() { throw new Failure("invalid_arguments"); }
    static String identifier(String value) {
        if (value == null || value.isEmpty()) invalid();
        return value;
    }
    private static boolean matches(Owner owner, String generation, long trigger) {
        return owner != null && owner.generation.equals(generation) && owner.triggerAt == trigger;
    }
    public Owner readOwner(String eventId) {
        identifier(eventId); synchronized (LOCK) { return store.read(eventId); }
    }
    public Owner updateOwner(String eventId, String generation, long triggerAt,
                             long originalNotifyAt, String metadataJson) {
        identifier(eventId);
        Owner next = new Owner(generation, triggerAt, originalNotifyAt, null, metadataJson);
        synchronized (LOCK) {
            Owner previous = store.read(eventId);
            store.write(eventId, next); return previous;
        }
    }
    public boolean replaceOwnerIfMatches(String eventId, String expectedGeneration, long expectedTrigger,
            String generation, long triggerAt, long originalNotifyAt, String metadataJson) {
        identifier(eventId); identifier(expectedGeneration);
        Owner next = new Owner(generation, triggerAt, originalNotifyAt, null, metadataJson);
        synchronized (LOCK) {
            if (!matches(store.read(eventId), expectedGeneration, expectedTrigger)) return false;
            store.write(eventId, next); return true;
        }
    }
    public boolean claimTrigger(String eventId, String generation, long triggerAt) {
        identifier(eventId); identifier(generation);
        synchronized (LOCK) {
            Owner old = store.read(eventId);
            if (!matches(old, generation, triggerAt) || old.claimedTrigger != null) return false;
            store.write(eventId, new Owner(generation, triggerAt, old.originalNotifyAt, triggerAt, old.metadataJson));
            return true;
        }
    }
    public boolean updateTriggerIfOwner(String eventId, String generation, long expectedTrigger, long nextTrigger) {
        identifier(eventId); identifier(generation);
        synchronized (LOCK) {
            Owner old = store.read(eventId);
            if (!matches(old, generation, expectedTrigger)) return false;
            store.write(eventId, new Owner(generation, nextTrigger, old.originalNotifyAt, null, old.metadataJson));
            return true;
        }
    }
    public boolean releaseIfOwner(String eventId, String generation, long expectedTrigger) {
        identifier(eventId); identifier(generation);
        synchronized (LOCK) {
            if (!matches(store.read(eventId), generation, expectedTrigger)) return false;
            store.write(eventId, null); return true;
        }
    }
    public Owner invalidateOwner(String eventId) {
        identifier(eventId); synchronized (LOCK) {
            Owner previous = store.read(eventId);
            if (previous != null) store.write(eventId, null);
            return previous;
        }
    }
    public Map<String, Map<String, Object>> listOwners() {
        synchronized (LOCK) {
            Map<String, Map<String, Object>> out = new LinkedHashMap<>();
            for (Map.Entry<String, Owner> item : store.list().entrySet()) out.put(item.getKey(), item.getValue().toMap());
            return out;
        }
    }
}
