package com.fluxstudio.planflow

import android.app.Activity
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognitionSupport
import android.speech.RecognitionSupportCallback
import android.speech.SpeechRecognizer
import android.speech.ModelDownloadListener
import android.speech.RecognizerIntent
import android.util.Log
import android.view.ViewGroup
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import java.util.concurrent.Executor

/** Debug-only, explicit-action QA surface. Never starts recognition or captures audio. */
class GuideSpeechModelDownloadActivity : Activity() {
    private var recognizer: SpeechRecognizer? = null
    private lateinit var status: TextView
    private lateinit var checkButton: Button
    private lateinit var downloadButton: Button
    private var downloadAttempted = false
    private val callbackExecutor: Executor = Executor { command -> runOnUiThread(command) }

    private val recognitionIntent: Intent by lazy {
        Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, "ko-KR")
            putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        status = TextView(this).apply { textSize = 15f; setPadding(24, 20, 24, 16); text = "Ready. No audio will be captured." }
        checkButton = Button(this).apply { text = "Check Korean support"; setOnClickListener { checkSupport() } }
        downloadButton = Button(this).apply { text = "Download Korean model"; setOnClickListener { requestDownload() } }
        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(status, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
            addView(checkButton)
            addView(downloadButton)
        }
        setContentView(ScrollView(this).apply { addView(content) })

        if (Build.VERSION.SDK_INT >= 31 && SpeechRecognizer.isRecognitionAvailable(this)) {
            recognizer = SpeechRecognizer.createSpeechRecognizer(this).apply {
                // Explicit no-op listener; this Activity deliberately never invokes startListening().
                setRecognitionListener(object : RecognitionListener {
                    override fun onReadyForSpeech(params: Bundle?) = Unit
                    override fun onBeginningOfSpeech() = Unit
                    override fun onRmsChanged(rmsdB: Float) = Unit
                    override fun onBufferReceived(buffer: ByteArray?) = Unit
                    override fun onEndOfSpeech() = Unit
                    override fun onError(error: Int) = Unit
                    override fun onResults(results: Bundle?) = Unit
                    override fun onPartialResults(partialResults: Bundle?) = Unit
                    override fun onEvent(eventType: Int, params: Bundle?) = Unit
                })
            }
            status.text = "Ready. Recognition service available; no audio will be captured."
        } else {
            checkButton.isEnabled = false
            downloadButton.isEnabled = false
            status.text = "Speech recognition unavailable (requires API 31+ and an available service)."
        }
    }

    private fun checkSupport() {
        if (Build.VERSION.SDK_INT < 34) {
            status.text = "Support check requires Android API 34+."
            return
        }
        val service = recognizer ?: run { status.text = "No recognition service available."; return }
        checkButton.isEnabled = false
        status.text = "Checking Korean support…"
        try {
            service.checkRecognitionSupport(recognitionIntent, callbackExecutor, object : RecognitionSupportCallback {
                override fun onSupportResult(support: RecognitionSupport) {
                    checkButton.isEnabled = true
                    status.text = buildString {
                        appendLine("Installed on-device languages: ${support.installedOnDeviceLanguages}")
                        appendLine("Pending on-device languages: ${support.pendingOnDeviceLanguages}")
                        append("Supported on-device languages: ${support.supportedOnDeviceLanguages}")
                    }
                    Log.i(TAG, "Support checked; Korean installed=${support.installedOnDeviceLanguages.any { it.equals("ko-KR", ignoreCase = true) }}, pending=${support.pendingOnDeviceLanguages.any { it.equals("ko-KR", ignoreCase = true) }}")
                }
                override fun onError(error: Int) {
                    checkButton.isEnabled = true
                    status.text = "Support check error: $error"
                    Log.w(TAG, "Support check error=$error")
                }
            })
        } catch (e: Exception) {
            checkButton.isEnabled = true
            status.text = "Support check failed: ${e.message ?: e.javaClass.simpleName}"
            Log.w(TAG, "Support check failed: ${e.javaClass.simpleName}")
        }
    }

    private fun requestDownload() {
        if (Build.VERSION.SDK_INT < 34) {
            status.text = "Model download requires Android API 34+."
            return
        }
        if (downloadAttempted) {
            status.text = "Download already requested in this Activity instance. Reopen to make another explicit request."
            return
        }
        val service = recognizer ?: run { status.text = "No recognition service available."; return }
        downloadAttempted = true
        downloadButton.isEnabled = false
        status.text = "Download request submitted…"
        Log.i(TAG, "Explicit Korean model download request started")
        try {
            service.triggerModelDownload(recognitionIntent, callbackExecutor, object : ModelDownloadListener {
                override fun onProgress(progress: Int) {
                    status.text = "Download progress: $progress%"
                    Log.i(TAG, "Download progress=$progress")
                }
                override fun onSuccess() {
                    status.text = "Korean model download completed."
                    Log.i(TAG, "Download succeeded")
                }
                override fun onScheduled() {
                    status.text = "Korean model download scheduled by recognition service."
                    Log.i(TAG, "Download scheduled")
                }
                override fun onError(error: Int) {
                    status.text = "Korean model download error: $error"
                    Log.w(TAG, "Download error=$error")
                }
            })
        } catch (e: Exception) {
            status.text = "Download request failed: ${e.message ?: e.javaClass.simpleName}"
            Log.w(TAG, "Download request failed: ${e.javaClass.simpleName}")
        }
    }

    override fun onDestroy() {
        recognizer?.destroy()
        recognizer = null
        super.onDestroy()
    }

    private companion object { const val TAG = "GuideModelQA" }
}
