package com.example.planflow

import android.Manifest
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.CalendarContract
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
        private const val REQUEST_CALENDAR_PERMISSION = 4312
    }

    private var planFlowStt: PlanFlowSttChannel? = null
    private var settingsChannel: MethodChannel? = null
    private var permissionsChannel: MethodChannel? = null
    private var microphonePermissionResult: MethodChannel.Result? = null
    private var locationPermissionResult: MethodChannel.Result? = null
    private var calendarPermissionResult: MethodChannel.Result? = null
    private var currentLocationResult: MethodChannel.Result? = null
    private var currentLocationListener: LocationListener? = null
    private val mainHandler = Handler(Looper.getMainLooper())

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
                    "checkCalendarPermission" -> result.success(hasCalendarPermission())
                    "requestCalendarPermission" -> requestCalendarPermission(result)
                    "getLastKnownLocation" -> result.success(getLastKnownLocationMap())
                    "getCurrentLocation" -> requestCurrentLocation(result)
                    "listDeviceCalendars" -> result.success(listDeviceCalendars())
                    "listDeviceCalendarEvents" -> {
                        val calendarIds = call.argument<List<Any>>("calendarIds")
                            ?.mapNotNull { it.toString().toLongOrNull() }
                        val startMillis = call.argument<Number>("startMillis")?.toLong()
                            ?: (System.currentTimeMillis() - 24L * 60L * 60L * 1000L)
                        val endMillis = call.argument<Number>("endMillis")?.toLong()
                            ?: (System.currentTimeMillis() + 365L * 24L * 60L * 60L * 1000L)
                        result.success(
                            listDeviceCalendarEvents(
                                calendarIds = calendarIds,
                                startMillis = startMillis,
                                endMillis = endMillis,
                            ),
                        )
                    }
                    "upsertDeviceCalendarEvent" -> {
                        val eventKey = call.argument<String>("eventKey")
                        val title = call.argument<String>("title")
                        val description = call.argument<String>("description")
                        val location = call.argument<String>("location")
                        val startMillis = call.argument<Number>("startMillis")?.toLong()
                        val endMillis = call.argument<Number>("endMillis")?.toLong()
                        val allDay = call.argument<Boolean>("allDay") ?: false
                        result.success(
                            upsertDeviceCalendarEvent(
                                eventKey = eventKey,
                                title = title,
                                description = description,
                                location = location,
                                startMillis = startMillis,
                                endMillis = endMillis,
                                allDay = allDay,
                            ),
                        )
                    }
                    "openAppSettings" -> result.success(openAppSettings())
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun onDestroy() {
        finishCurrentLocationRequest(null)
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
            REQUEST_CALENDAR_PERMISSION -> {
                calendarPermissionResult?.success(granted)
                calendarPermissionResult = null
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

    private fun hasCalendarPermission(): Boolean {
        val readGranted = ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.READ_CALENDAR,
        ) == PackageManager.PERMISSION_GRANTED
        val writeGranted = ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.WRITE_CALENDAR,
        ) == PackageManager.PERMISSION_GRANTED
        return readGranted && writeGranted
    }

    private fun requestCalendarPermission(result: MethodChannel.Result) {
        if (hasCalendarPermission()) {
            result.success(true)
            return
        }

        if (calendarPermissionResult != null) {
            result.success(false)
            return
        }

        calendarPermissionResult = result
        ActivityCompat.requestPermissions(
            this,
            arrayOf(
                Manifest.permission.READ_CALENDAR,
                Manifest.permission.WRITE_CALENDAR,
            ),
            REQUEST_CALENDAR_PERMISSION,
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

    private fun requestCurrentLocation(result: MethodChannel.Result) {
        if (!hasLocationPermission()) {
            result.success(null)
            return
        }
        if (currentLocationResult != null) {
            result.success(getLastKnownLocationMap())
            return
        }

        val manager = getSystemService(Context.LOCATION_SERVICE) as LocationManager
        val provider = listOf(
            LocationManager.GPS_PROVIDER,
            LocationManager.NETWORK_PROVIDER,
            LocationManager.PASSIVE_PROVIDER,
        ).firstOrNull { providerName ->
            try {
                manager.isProviderEnabled(providerName)
            } catch (_: Exception) {
                false
            }
        }

        if (provider == null) {
            result.success(getLastKnownLocationMap())
            return
        }

        currentLocationResult = result
        val listener = object : LocationListener {
            override fun onLocationChanged(location: Location) {
                finishCurrentLocationRequest(
                    mapOf(
                        "latitude" to location.latitude,
                        "longitude" to location.longitude,
                    ),
                )
            }

            @Deprecated("Deprecated in Java")
            override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) = Unit
            override fun onProviderEnabled(provider: String) = Unit
            override fun onProviderDisabled(provider: String) = Unit
        }
        currentLocationListener = listener
        mainHandler.postDelayed({
            finishCurrentLocationRequest(getLastKnownLocationMap())
        }, 10000L)

        try {
            manager.requestSingleUpdate(provider, listener, Looper.getMainLooper())
        } catch (_: Exception) {
            finishCurrentLocationRequest(getLastKnownLocationMap())
        }
    }

    private fun finishCurrentLocationRequest(value: Map<String, Double>?) {
        val result = currentLocationResult ?: return
        val listener = currentLocationListener
        currentLocationResult = null
        currentLocationListener = null
        if (listener != null) {
            try {
                val manager = getSystemService(Context.LOCATION_SERVICE) as LocationManager
                manager.removeUpdates(listener)
            } catch (_: Exception) {
                // Best-effort cleanup only.
            }
        }
        result.success(value)
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

    private fun listDeviceCalendars(): List<Map<String, Any?>> {
        if (!hasCalendarPermission()) {
            return emptyList()
        }

        val projection = arrayOf(
            CalendarContract.Calendars._ID,
            CalendarContract.Calendars.NAME,
            CalendarContract.Calendars.CALENDAR_DISPLAY_NAME,
            CalendarContract.Calendars.ACCOUNT_NAME,
            CalendarContract.Calendars.ACCOUNT_TYPE,
            CalendarContract.Calendars.OWNER_ACCOUNT,
            CalendarContract.Calendars.IS_PRIMARY,
            CalendarContract.Calendars.VISIBLE,
            CalendarContract.Calendars.SYNC_EVENTS,
            CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL,
        )

        val calendars = mutableListOf<Map<String, Any?>>()
        try {
            contentResolver.query(
                CalendarContract.Calendars.CONTENT_URI,
                projection,
                null,
                null,
                "${CalendarContract.Calendars.CALENDAR_DISPLAY_NAME} COLLATE LOCALIZED ASC",
            )?.use { cursor ->
                while (cursor.moveToNext()) {
                    calendars.add(
                        mapOf(
                            "id" to cursor.getLongOrNull(0)?.toString(),
                            "name" to cursor.getStringOrNull(1),
                            "displayName" to cursor.getStringOrNull(2),
                            "accountName" to cursor.getStringOrNull(3),
                            "accountType" to cursor.getStringOrNull(4),
                            "ownerAccount" to cursor.getStringOrNull(5),
                            "isPrimary" to cursor.getBooleanOrNull(6),
                            "visible" to cursor.getBooleanOrNull(7),
                            "syncEvents" to cursor.getBooleanOrNull(8),
                            "accessLevel" to cursor.getLongOrNull(9),
                        ),
                    )
                }
            }
        } catch (error: Exception) {
            return listOf(mapOf("error" to (error.message ?: error.javaClass.simpleName)))
        }
        return calendars
    }

    private fun listDeviceCalendarEvents(
        calendarIds: List<Long>?,
        startMillis: Long,
        endMillis: Long,
    ): List<Map<String, Any?>> {
        if (!hasCalendarPermission()) {
            return emptyList()
        }

        val projection = arrayOf(
            CalendarContract.Instances.EVENT_ID,
            CalendarContract.Instances.CALENDAR_ID,
            CalendarContract.Instances.TITLE,
            CalendarContract.Instances.DESCRIPTION,
            CalendarContract.Instances.EVENT_LOCATION,
            CalendarContract.Instances.BEGIN,
            CalendarContract.Instances.END,
            CalendarContract.Instances.ALL_DAY,
            CalendarContract.Instances.LAST_DATE,
            CalendarContract.Instances.DTSTART,
            CalendarContract.Instances.DTEND,
            CalendarContract.Events.UID_2445,
        )

        val uri = CalendarContract.Instances.CONTENT_URI.buildUpon().apply {
            appendPath(startMillis.toString())
            appendPath(endMillis.toString())
        }.build()

        val selection: String?
        val selectionArgs: Array<String>?
        if (calendarIds.isNullOrEmpty()) {
            selection = null
            selectionArgs = null
        } else {
            selection = "${CalendarContract.Instances.CALENDAR_ID} IN (${calendarIds.joinToString(",") { "?" }})"
            selectionArgs = calendarIds.map { it.toString() }.toTypedArray()
        }

        val events = mutableListOf<Map<String, Any?>>()
        try {
            contentResolver.query(
                uri,
                projection,
                selection,
                selectionArgs,
                "${CalendarContract.Instances.BEGIN} ASC",
            )?.use { cursor ->
                while (cursor.moveToNext()) {
                    events.add(
                        mapOf(
                            "eventId" to cursor.getLongOrNull(0)?.toString(),
                            "calendarId" to cursor.getLongOrNull(1)?.toString(),
                            "title" to cursor.getStringOrNull(2),
                            "description" to cursor.getStringOrNull(3),
                            "location" to cursor.getStringOrNull(4),
                            "beginMillis" to cursor.getLongOrNull(5),
                            "endMillis" to cursor.getLongOrNull(6),
                            "allDay" to cursor.getBooleanOrNull(7),
                            "lastDateMillis" to cursor.getLongOrNull(8),
                            "dtstartMillis" to cursor.getLongOrNull(9),
                            "dtendMillis" to cursor.getLongOrNull(10),
                            "eventKey" to cursor.getStringOrNull(11),
                        ),
                    )
                }
            }
        } catch (error: Exception) {
            return listOf(mapOf("error" to (error.message ?: error.javaClass.simpleName)))
        }
        return events
    }

    private fun upsertDeviceCalendarEvent(
        eventKey: String?,
        title: String?,
        description: String?,
        location: String?,
        startMillis: Long?,
        endMillis: Long?,
        allDay: Boolean,
    ): Boolean {
        if (!hasCalendarPermission() ||
            eventKey.isNullOrBlank() ||
            title.isNullOrBlank() ||
            startMillis == null
        ) {
            return false
        }

        return try {
            val calendarId = findWritableCalendarId() ?: return false
            val safeEndMillis = endMillis?.takeIf { it > startMillis }
                ?: (startMillis + 30L * 60L * 1000L)
            val values = ContentValues().apply {
                put(CalendarContract.Events.CALENDAR_ID, calendarId)
                put(CalendarContract.Events.TITLE, title)
                put(CalendarContract.Events.DESCRIPTION, description)
                put(CalendarContract.Events.EVENT_LOCATION, location)
                put(CalendarContract.Events.DTSTART, startMillis)
                put(CalendarContract.Events.DTEND, safeEndMillis)
                put(CalendarContract.Events.ALL_DAY, if (allDay) 1 else 0)
                put(CalendarContract.Events.EVENT_TIMEZONE, "Asia/Seoul")
                put(CalendarContract.Events.UID_2445, eventKey)
            }

            val existingId = findEventIdByUid(eventKey)
            if (existingId == null) {
                contentResolver.insert(CalendarContract.Events.CONTENT_URI, values) != null
            } else {
                val uri = Uri.withAppendedPath(
                    CalendarContract.Events.CONTENT_URI,
                    existingId.toString(),
                )
                contentResolver.update(uri, values, null, null) > 0
            }
        } catch (_: Exception) {
            false
        }
    }

    private fun findWritableCalendarId(): Long? {
        val projection = arrayOf(
            CalendarContract.Calendars._ID,
            CalendarContract.Calendars.CALENDAR_DISPLAY_NAME,
            CalendarContract.Calendars.ACCOUNT_TYPE,
            CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL,
            CalendarContract.Calendars.VISIBLE,
        )
        val candidates = mutableListOf<Pair<Long, Int>>()
        contentResolver.query(
            CalendarContract.Calendars.CONTENT_URI,
            projection,
            null,
            null,
            null,
        )?.use { cursor ->
            while (cursor.moveToNext()) {
                val id = cursor.getLongOrNull(0) ?: continue
                val name = cursor.getStringOrNull(1).orEmpty().lowercase(Locale.getDefault())
                val accountType = cursor.getStringOrNull(2).orEmpty().lowercase(Locale.getDefault())
                val accessLevel = cursor.getLongOrNull(3)?.toInt() ?: 0
                val visible = cursor.getBooleanOrNull(4) ?: true
                if (!visible || accessLevel < CalendarContract.Calendars.CAL_ACCESS_CONTRIBUTOR) {
                    continue
                }
                val priority = when {
                    accountType.contains("samsung") || name.contains("samsung") -> 0
                    accountType.contains("local") || name.contains("local") -> 1
                    accountType.contains("google") -> 3
                    else -> 2
                }
                candidates.add(id to priority)
            }
        }
        return candidates.minByOrNull { it.second }?.first
    }

    private fun findEventIdByUid(eventKey: String): Long? {
        val projection = arrayOf(CalendarContract.Events._ID)
        return contentResolver.query(
            CalendarContract.Events.CONTENT_URI,
            projection,
            "${CalendarContract.Events.UID_2445} = ?",
            arrayOf(eventKey),
            null,
        )?.use { cursor ->
            if (cursor.moveToFirst()) cursor.getLongOrNull(0) else null
        }
    }

    private fun android.database.Cursor.getStringOrNull(index: Int): String? {
        return if (isNull(index)) null else getString(index)
    }

    private fun android.database.Cursor.getLongOrNull(index: Int): Long? {
        return if (isNull(index)) null else getLong(index)
    }

    private fun android.database.Cursor.getBooleanOrNull(index: Int): Boolean? {
        return if (isNull(index)) null else getInt(index) != 0
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
