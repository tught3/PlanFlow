package com.example.planflow

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
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
    }

    private var planFlowStt: PlanFlowSttChannel? = null
    private var settingsChannel: MethodChannel? = null
    private var permissionsChannel: MethodChannel? = null
    private var microphonePermissionResult: MethodChannel.Result? = null

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
                    "requestMicrophonePermission" -> requestMicrophonePermission(result)
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
        if (requestCode != REQUEST_MICROPHONE_PERMISSION) {
            return
        }

        val granted = grantResults.isNotEmpty() &&
            grantResults.first() == PackageManager.PERMISSION_GRANTED
        microphonePermissionResult?.success(granted)
        microphonePermissionResult = null
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
        if (ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.RECORD_AUDIO,
            ) == PackageManager.PERMISSION_GRANTED
        ) {
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
                    latestPartialText = ""
                    recognizer?.cancel()
                    if (listening && !userRequestedStop) {
                        activity.window.decorView.postDelayed({
                            if (listening && !userRequestedStop) {
                                startListening()
                            }
                        }, 150)
                    }
                    result.success(true)
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
        channel.invokeMethod("restarted", null)
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
            channel.invokeMethod("partial", text)
        }
    }

    private fun cancel() {
        listening = false
        recognizer?.cancel()
        channel.invokeMethod("cancelled", latestPartialText)
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
        channel.invokeMethod("segmentEnded", null)
    }
    override fun onEvent(eventType: Int, params: Bundle?) = Unit

    override fun onError(error: Int) {
        if (userRequestedStop) {
            listening = false
            channel.invokeMethod("stopped", latestPartialText)
            return
        }
        restartSoon()
    }

    override fun onResults(results: Bundle?) {
        publishText(results)
        if (userRequestedStop) {
            listening = false
            channel.invokeMethod("stopped", latestPartialText)
            return
        }
        restartSoon()
    }

    override fun onPartialResults(partialResults: Bundle?) {
        publishText(partialResults)
    }
}
