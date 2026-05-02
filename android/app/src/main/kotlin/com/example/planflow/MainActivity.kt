package com.example.planflow

import android.content.Intent
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

class MainActivity : FlutterActivity() {
    private var planFlowStt: PlanFlowSttChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        planFlowStt = PlanFlowSttChannel(this, flutterEngine)
    }

    override fun onDestroy() {
        planFlowStt?.dispose()
        planFlowStt = null
        super.onDestroy()
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
