package com.fluxstudio.planflow.freshlocation;

import android.Manifest;
import android.content.Context;
import android.content.pm.PackageManager;
import android.location.Location;
import android.location.LocationListener;
import android.location.LocationManager;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;
import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/** No ActivityAware dependency: generated registration works in headless engines. */
public final class PlanflowFreshLocationPlugin implements FlutterPlugin, MethodChannel.MethodCallHandler {
    private static final long TIMEOUT_MS = 10000;
    private static final Object PENDING_LOCK = new Object();
    private static final Set<FixRequest> PROCESS_PENDING = new HashSet<>();
    private final Handler main = new Handler(Looper.getMainLooper());
    private final Set<FixRequest> pending = new HashSet<>();
    private Context context;
    private MethodChannel channel;
    private CriticalAlarmOwnershipChannel ownershipChannel;

    @Override public void onAttachedToEngine(FlutterPluginBinding binding) {
        context = binding.getApplicationContext();
        channel = new MethodChannel(binding.getBinaryMessenger(), "planflow/fresh_location");
        channel.setMethodCallHandler(this);
        ownershipChannel = new CriticalAlarmOwnershipChannel(
            binding.getApplicationContext(), binding.getBinaryMessenger());
    }
    @Override public void onDetachedFromEngine(FlutterPluginBinding binding) {
        if (ownershipChannel != null) ownershipChannel.dispose();
        ownershipChannel = null;
        channel.setMethodCallHandler(null);
        for (FixRequest request : new HashSet<>(pending)) request.finish(null);
        context = null;
        channel = null;
    }
    @Override public void onMethodCall(MethodCall call, MethodChannel.Result result) {
        Context app = context;
        if (app == null) {
            result.success(call.method.equals("canUseBackgroundPermission") ? false : null);
            return;
        }
        if (call.method.equals("canUseBackgroundPermission")) {
            result.success(hasBackgroundLocationPermission(app));
            return;
        }
        if (call.method.equals("cancelPendingBackgroundRequests")) {
            Set<FixRequest> toCancel = new HashSet<>();
            synchronized (PENDING_LOCK) {
                for (FixRequest request : PROCESS_PENDING) {
                    if (request.requireBackgroundPermission) toCancel.add(request);
                }
            }
            int canceled = 0;
            for (FixRequest request : toCancel) {
                if (request.finish(null)) canceled++;
            }
            result.success(canceled);
            return;
        }
        if (!call.method.equals("getFreshCurrentLocation")) { result.notImplemented(); return; }
        boolean fine = app.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED;
        boolean coarse = app.checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED;
        if (!fine && !coarse) { result.success(null); return; }
        // Headless alarm callers must explicitly require background authorization.
        // A foreground caller can keep using the existing foreground-only path.
        boolean requireBackground = call.argument("requireBackgroundPermission") != null
            && Boolean.TRUE.equals(call.argument("requireBackgroundPermission"));
        if (requireBackground && !hasBackgroundLocationPermission(app)) {
            result.success(null);
            return;
        }
        LocationManager manager = (LocationManager) app.getSystemService(Context.LOCATION_SERVICE);
        if (manager == null) { result.success(null); return; }
        try {
            String provider = fine && manager.isProviderEnabled(LocationManager.GPS_PROVIDER)
                ? LocationManager.GPS_PROVIDER
                : manager.isProviderEnabled(LocationManager.NETWORK_PROVIDER) ? LocationManager.NETWORK_PROVIDER : null;
            if (provider == null) { result.success(null); return; }
            FixRequest request = new FixRequest(
                manager, provider, result, requireBackground);
            synchronized (PENDING_LOCK) {
                pending.add(request);
                PROCESS_PENDING.add(request);
            }
            request.start();
        } catch (RuntimeException unavailable) { result.success(null); }
    }
    private boolean hasBackgroundLocationPermission(Context app) {
        boolean foreground = app.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION)
                == PackageManager.PERMISSION_GRANTED
            || app.checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION)
                == PackageManager.PERMISSION_GRANTED;
        if (!foreground) return false;
        return android.os.Build.VERSION.SDK_INT < 29
            || app.checkSelfPermission(Manifest.permission.ACCESS_BACKGROUND_LOCATION)
                == PackageManager.PERMISSION_GRANTED;
    }

    private final class FixRequest implements LocationListener {
        final LocationManager manager;
        final String provider;
        final MethodChannel.Result result;
        final boolean requireBackgroundPermission;
        final long startedNanos = SystemClock.elapsedRealtimeNanos();
        final long startedMillis = System.currentTimeMillis();
        final Runnable timeout = () -> finish(null);
        boolean finished;
        FixRequest(LocationManager manager, String provider, MethodChannel.Result result,
                boolean requireBackgroundPermission) {
            this.manager = manager;
            this.provider = provider;
            this.result = result;
            this.requireBackgroundPermission = requireBackgroundPermission;
        }
        void start() {
            main.postDelayed(timeout, TIMEOUT_MS);
            try {
                // One bounded subscription, never a last-known/cached read.
                manager.requestLocationUpdates(provider, 0L, 0f, this, Looper.getMainLooper());
            } catch (RuntimeException deniedOrUnavailable) { finish(null); }
        }
        boolean finish(Map<String, Object> fix) {
            if (finished) return false;
            finished = true;
            main.removeCallbacks(timeout);
            try { manager.removeUpdates(this); } catch (RuntimeException ignored) { }
            synchronized (PENDING_LOCK) {
                pending.remove(this);
                PROCESS_PENDING.remove(this);
            }
            result.success(fix);
            return true;
        }
        @Override public void onLocationChanged(Location location) {
            if (finished || location == null) return;
            long nowNanos = SystemClock.elapsedRealtimeNanos();
            long requestAge = (nowNanos - startedNanos) / 1000000L;
            long fixNanos = location.getElapsedRealtimeNanos();
            long fixAge = (nowNanos - fixNanos) / 1000000L;
            long wallNow = System.currentTimeMillis();
            double lat = location.getLatitude(), lng = location.getLongitude();
            // A stationary fix is valid: sample time, not motion, proves freshness.
            if (requestAge < 0 || requestAge > TIMEOUT_MS || fixNanos < startedNanos
                    || fixNanos > nowNanos || fixAge < 0 || fixAge > TIMEOUT_MS
                    || location.getTime() < startedMillis - 2000 || location.getTime() > wallNow + 2000
                    || wallNow - location.getTime() > TIMEOUT_MS
                    || !Double.isFinite(lat) || !Double.isFinite(lng) || Math.abs(lat) > 90 || Math.abs(lng) > 180
                    || !provider.equals(location.getProvider())) { finish(null); return; }
            Map<String, Object> fix = new HashMap<>();
            fix.put("latitude", lat); fix.put("longitude", lng);
            fix.put("source", "current_request"); fix.put("isFresh", true);
            fix.put("timestampMillis", location.getTime());
            fix.put("requestAgeMillis", requestAge); fix.put("fixAgeMillis", fixAge);
            finish(fix);
        }
        @Override public void onProviderDisabled(String disabled) { if (provider.equals(disabled)) finish(null); }
        @Override public void onProviderEnabled(String enabled) { }
        @Override public void onStatusChanged(String changed, int status, Bundle extras) {
            if (provider.equals(changed) && status != android.location.LocationProvider.AVAILABLE) finish(null);
        }
    }
}
