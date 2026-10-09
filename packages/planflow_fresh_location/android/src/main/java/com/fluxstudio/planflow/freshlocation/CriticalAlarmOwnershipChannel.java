package com.fluxstudio.planflow.freshlocation;

import android.content.Context;
import java.util.Map;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import com.fluxstudio.planflow.freshlocation.CriticalAlarmOwnershipCoordinator.Owner;
import com.fluxstudio.planflow.freshlocation.CriticalAlarmOwnershipCoordinator.Failure;

/** Engine wrapper; no notification, permission, or location side effects. */
public final class CriticalAlarmOwnershipChannel implements MethodChannel.MethodCallHandler {
    private final MethodChannel channel;
    private final CriticalAlarmOwnershipCoordinator coordinator;
    private boolean disposed;
    public CriticalAlarmOwnershipChannel(Context appContext, BinaryMessenger messenger) {
        coordinator = new CriticalAlarmOwnershipCoordinator(new CriticalAlarmOwnershipStore(appContext));
        channel = new MethodChannel(messenger, "planflow/critical_alarm_ownership");
        channel.setMethodCallHandler(this);
    }
    public void dispose() { disposed = true; channel.setMethodCallHandler(null); }
    private static String text(Map<?, ?> args, String key) {
        Object value = args.get(key);
        if (!(value instanceof String)) throw new Failure("invalid_arguments");
        return CriticalAlarmOwnershipCoordinator.identifier((String) value);
    }
    private static long integer(Map<?, ?> args, String key) {
        Object value = args.get(key);
        if (!(value instanceof Integer) && !(value instanceof Long)) throw new Failure("invalid_arguments");
        return ((Number) value).longValue();
    }
    private static String metadata(Map<?, ?> args) {
        Object value = args.get("metadataJson");
        if (value == null) return null;
        if (!(value instanceof String) || ((String) value).length() > 8192) throw new Failure("invalid_arguments");
        return (String) value;
    }
    private static Object map(Owner owner) { return owner == null ? null : owner.toMap(); }
    @Override public void onMethodCall(MethodCall call, MethodChannel.Result result) {
        if (disposed) { result.error("channel_disposed", "Ownership channel unavailable", null); return; }
        try {
            if ("listOwners".equals(call.method)) { result.success(coordinator.listOwners()); return; }
            switch (call.method) {
                case "readOwner": case "updateOwner": case "claimTrigger":
                case "updateTriggerIfOwner": case "releaseIfOwner": case "invalidateOwner":
                case "replaceOwnerIfMatches": break;
                default: result.notImplemented(); return;
            }
            if (!(call.arguments instanceof Map)) throw new Failure("invalid_arguments");
            Map<?, ?> args = (Map<?, ?>) call.arguments;
            String eventId = text(args, "eventId");
            Object value;
            switch (call.method) {
                case "readOwner": value = map(coordinator.readOwner(eventId)); break;
                case "updateOwner": value = map(coordinator.updateOwner(eventId, text(args, "generation"),
                    integer(args, "triggerAt"), integer(args, "originalNotifyAt"), metadata(args))); break;
                case "claimTrigger": value = coordinator.claimTrigger(eventId, text(args, "generation"), integer(args, "triggerAt")); break;
                case "updateTriggerIfOwner": value = coordinator.updateTriggerIfOwner(eventId, text(args, "generation"),
                    integer(args, "expectedTrigger"), integer(args, "nextTrigger")); break;
                case "releaseIfOwner": value = coordinator.releaseIfOwner(eventId, text(args, "generation"), integer(args, "expectedTrigger")); break;
                case "invalidateOwner": value = map(coordinator.invalidateOwner(eventId)); break;
                case "replaceOwnerIfMatches": value = coordinator.replaceOwnerIfMatches(eventId, text(args, "expectedGeneration"),
                    integer(args, "expectedTrigger"), text(args, "generation"), integer(args, "triggerAt"),
                    integer(args, "originalNotifyAt"), metadata(args)); break;
                default: throw new Failure("invalid_arguments");
            }
            result.success(value);
        } catch (Failure failure) {
            result.error(failure.code, "Ownership operation rejected", null);
        } catch (RuntimeException ignored) {
            result.error("storage_failure", "Ownership storage unavailable", null);
        }
    }
}
