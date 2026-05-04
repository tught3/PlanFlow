package com.example.planflow

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationManager
import android.net.Uri
import android.os.Bundle
import android.provider.Settings
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

class MainActivity : FlutterActivity() {
    companion object {
        private const val REQUEST_MICROPHONE_PERMISSION = 4310
        private const val REQUEST_LOCATION_PERMISSION = 4311
    }

    private var planFlowStt: PlanFlowSttChannel? = null
    private var settingsChannel: MethodChannel? = null
    private var permissionsChannel: MethodChannel? = null
    private var microphonePermissionResult: MethodChannel.Result? = null
    private var locationPermissionResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        planFlowStt = PlanFlowSttChannel(this, flutterEngine)
        settingsChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "planflow/android_settings",
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "openNotificationSettings" -> {
                        result.success(openNotificationSettings())
                    }
                    else -> result.notImplemented()
                }
            }
        }
        permissionsChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "planflow/android_permissions",
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "checkMicrophonePermission" -> result.success(hasMicrophonePermission())
                    "requestMicrophonePermission" -> requestMicrophonePermission(result)
                    "checkLocationPermission" -> result.success(hasLocationPermission())
                    "requestLocationPermission" -> requestLocationPermission(result)
                    "getLastKnownLocation" -> result.success(getLastKnownLocationMap())
                    "openAppSettings" -> result.success(openAppSettings())
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun onDestroy() {
        planFlowStt?.dispose()
        planFlowStt = null
        settingsChannel?.setMethodCallHandler(null)
        settingsChannel = null
        permissionsChannel?.setMethodCallHandler(null)
        permissionsChannel = null
        super.onDestroy()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        val granted = grantResults.isNotEmpty() &&
            grantResults.any { it == PackageManager.PERMISSION_GRANTED }
        when (requestCode) {
            REQUEST_MICROPHONE_PERMISSION -> {
                microphonePermissionResult?.success(granted)
                microphonePermissionResult = null
            }
            REQUEST_LOCATION_PERMISSION -> {
                locationPermissionResult?.success(granted)
                locationPermissionResult = null
            }
        }
    }

    private fun openNotificationSettings(): Boolean {
        return try {
            val intent = if (android.os.Build.VERSION.SDK_INT >= 26) {
                Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                    putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                }
            } else {
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                    data = Uri.parse("package:$packageName")
                }
            }
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
            true
        } catch (_: Exception) {
            try {
                val fallback = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                    data = Uri.parse("package:$packageName")
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                startActivity(fallback)
                true
            } catch (_: Exception) {
                false
            }
        }
    }

    private fun openAppSettings(): Boolean {
        return try {
            val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                data = Uri.parse("package:$packageName")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun requestMicrophonePermission(result: MethodChannel.Result) {
        if (hasMicrophonePermission()) {
            result.success(true)
            return
        }

        if (microphonePermissionResult != null) {
            result.success(false)
            return
        }

        microphonePermissionResult = result
        ActivityCompat.requestPermissions(
            this,
            arrayOf(Manifest.permission.RECORD_AUDIO),
            REQUEST_MICROPHONE_PERMISSION,
        )
    }

    private fun hasMicrophonePermission(): Boolean {
        return ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.RECORD_AUDIO,
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun hasLocationPermission(): Boolean {
        val fine = ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.ACCESS_FINE_LOCATION,
        ) == PackageManager.PERMISSION_GRANTED
        val coarse = ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.ACCESS_COARSE_LOCATION,
        ) == PackageManager.PERMISSION_GRANTED
        return fine || coarse
    }

    private fun requestLocationPermission(result: MethodChannel.Result) {
        if (hasLocationPermission()) {
            result.success(true)
            return
        }

        if (locationPermissionResult != null) {
            result.success(false)
            return
        }

        locationPermissionResult = result
        ActivityCompat.requestPermissions(
            this,
            arrayOf(
                Manifest.permission.ACCESS_FINE_LOCATION,
                Manifest.permission.ACCESS_COARSE_LOCATION,
            ),
            REQUEST_LOCATION_PERMISSION,
        )
    }

    private fun getLastKnownLocationMap(): Map<String, Double>? {
        if (!hasLocationPermission()) {
            return null
        }

        return try {
            val manager = getSystemService(Context.LOCATION_SERVICE) as LocationManager
            val providers = listOf(
                LocationManager.GPS_PROVIDER,
                LocationManager.NETWORK_PROVIDER,
                LocationManager.PASSIVE_PROVIDER,
            )
            val location = providers
                .mapNotNull { provider -> safeLastKnownLocation(manager, provider) }
                .maxByOrNull { it.time }
            if (location == null) {
                null
            } else {
                mapOf(
                    "latitude" to location.latitude,
                    "longitude" to location.longitude,
                )
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun safeLastKnownLocation(
        manager: LocationManager,
        provider: String,
    ): Location? {
        return try {
            if (manager.isProviderEnabled(provider)) {
                manager.getLastKnownLocation(provider)
            } else {
                null
            }
        } catch (_: Exception) {
            null
        }
    }
}

private class PlanFlowSttChannel(
    private val activity: FlutterActivity,
    flutterEngine: FlutterEngine,
) : RecognitionListener {
    private val channel = MethodChannel(
        flutterEngine.dartExecutor.binaryMessenger,
        "planflow/native_stt",
    )
    private var recognizer: SpeechRecognizer? = null
    private var listening = false
    private var userRequestedStop = false
    private var latestPartialText = ""
    private var sessionId = 0

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    start()
                    result.success(true)
                }
                "stop" -> {
                    userRequestedStop = true
                    recognizer?.stopListening()
                    result.success(latestPartialText)
                }
                "cancel" -> {
                    userRequestedStop = true
                    cancel()
                    result.success(latestPartialText)
                }
                "clearPartial" -> {
                    latestPartialText = ""
                    result.success(true)
                }
                "resetTranscript" -> {
                    sessionId += 1
                    latestPartialText = ""
                    recognizer?.cancel()
                    if (listening && !userRequestedStop) {
                        activity.window.decorView.postDelayed({
                            if (listening && !userRequestedStop) {
                                startListening()
                            }
                        }, 150)
                    }
                    result.success(sessionId)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun start() {
        if (!SpeechRecognizer.isRecognitionAvailable(activity)) {
            channel.invokeMethod("error", "unavailable")
            return
        }
        listening = true
        userRequestedStop = false
        latestPartialText = ""
        sessionId += 1
        ensureRecognizer()
        startListening()
    }

    private fun ensureRecognizer() {
        if (recognizer != null) {
            return
        }
        recognizer = if (android.os.Build.VERSION.SDK_INT >= 31) {
            SpeechRecognizer.createOnDeviceSpeechRecognizer(activity)
        } else {
            SpeechRecognizer.createSpeechRecognizer(activity)
        }
        recognizer?.setRecognitionListener(this)
    }

    private fun startListening() {
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, Locale.KOREA.toLanguageTag())
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 10)
            putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS, 30000)
            putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS, 30000)
            putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_MINIMUM_LENGTH_MILLIS, 300000)
        }
        recognizer?.startListening(intent)
    }

    private fun restartSoon() {
        if (!listening || userRequestedStop) {
            return
        }
        channel.invokeMethod("restarted", mapOf("sessionId" to sessionId))
        activity.window.decorView.postDelayed({
            if (listening && !userRequestedStop) {
                startListening()
            }
        }, 150)
    }

    private fun publishText(results: Bundle?) {
        val text = results
            ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
            ?.firstOrNull()
            ?.trim()
            .orEmpty()
        if (text.isNotEmpty()) {
            latestPartialText = text
            channel.invokeMethod(
                "partial",
                mapOf("text" to text, "sessionId" to sessionId),
            )
        }
    }

    private fun cancel() {
        listening = false
        recognizer?.cancel()
        channel.invokeMethod(
            "cancelled",
            mapOf("text" to latestPartialText, "sessionId" to sessionId),
        )
    }

    fun dispose() {
        listening = false
        channel.setMethodCallHandler(null)
        recognizer?.destroy()
        recognizer = null
    }

    override fun onReadyForSpeech(params: Bundle?) = Unit
    override fun onBeginningOfSpeech() = Unit
    override fun onRmsChanged(rmsdB: Float) = Unit
    override fun onBufferReceived(buffer: ByteArray?) = Unit
    override fun onEndOfSpeech() {
        channel.invokeMethod("segmentEnded", mapOf("sessionId" to sessionId))
    }
    override fun onEvent(eventType: Int, params: Bundle?) = Unit

    override fun onError(error: Int) {
        if (userRequestedStop) {
            listening = false
            channel.invokeMethod(
                "stopped",
                mapOf("text" to latestPartialText, "sessionId" to sessionId),
            )
            return
        }
        restartSoon()
    }

    override fun onResults(results: Bundle?) {
        publishText(results)
        if (userRequestedStop) {
            listening = false
            channel.invokeMethod(
                "stopped",
                mapOf("text" to latestPartialText, "sessionId" to sessionId),
            )
            return
        }
        restartSoon()
    }

    override fun onPartialResults(partialResults: Bundle?) {
        publishText(partialResults)
    }
}
