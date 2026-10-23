package com.unicornsonlsd.finamp

import android.app.Activity
import android.app.NotificationManager
import android.app.UiModeManager
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.Intent.CATEGORY_APP_MUSIC
import android.media.MediaRecorder
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.media.audiofx.DynamicsProcessing
import android.os.Build
import android.os.Bundle
import android.provider.MediaStore.INTENT_ACTION_MUSIC_PLAYER
import android.provider.Settings
import android.speech.RecognizerIntent
import android.system.ErrnoException
import android.system.Os
import android.util.Log
import androidx.annotation.WorkerThread
import androidx.core.net.toUri
import androidx.lifecycle.lifecycleScope
import androidx.mediarouter.app.SystemOutputSwitcherDialogController
import androidx.mediarouter.media.MediaRouter
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.ByteArrayInputStream
import java.io.File
import java.security.KeyStore
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext


class MainActivity : AudioServiceActivity() {
    companion object {
        private const val CLIENT_CERT_CHANNEL = "com.unicornsonlsd.finamp/client_certificate"
        private const val CLIENT_CERT_CHANNEL_LOG_TAG = "ClientCertChannel"

        private const val DOWNLOADS_SERVICE_CHANNEL = "com.unicornsonlsd.finamp/downloads_service"
        private const val DOWNLOADS_SERVICE_CHANNEL_LOG_TAG = "DownloadsServiceChannel"

        private const val OUTPUT_SWITCHER_CHANNEL = "com.unicornsonlsd.finamp/output_switcher"
        private const val OUTPUT_SWITCHER_CHANNEL_LOG_TAG = "OutputSwitcherChannel"

        private const val SET_NATIVE_THEME_CHANNEL = "com.unicornsonlsd.finamp/set_native_theme"
        private const val SET_NATIVE_THEME_CHANNEL_LOG_TAG = "setNativeThemeChannel"

        private const val VOICE_SEARCH_CHANNEL = "com.unicornsonlsd.finamp/voice_search"
        private const val VOICE_SEARCH_REQUEST_CODE = 4711

        private const val HOME_WIDGET_CHANNEL = "com.unicornsonlsd.finamp/home_widget"
        private const val RECORDER_CHANNEL = "com.unicornsonlsd.finamp/recorder"
        private const val AUDIO_DEVICES_CHANNEL = "com.unicornsonlsd.finamp/audio_devices"
        private const val NIGHT_MODE_CHANNEL = "com.unicornsonlsd.finamp/night_mode"
        private const val ALARM_CHANNEL = "com.unicornsonlsd.finamp/alarm"
        private const val DJ_VOICE_CHANNEL = "com.unicornsonlsd.finamp/dj_voice"
        private const val NOTIFY_CHANNEL = "com.unicornsonlsd.finamp/notify"
        private const val VISUALIZER_CHANNEL = "com.unicornsonlsd.finamp/visualizer"
        private const val STEPS_CHANNEL = "com.unicornsonlsd.finamp/steps"
    }

    private lateinit var mediaRouter: MediaRouter

    private val djVoice by lazy { DjVoice(this) }

    /** Result of the voice search that is currently waiting for the speech recognizer. */
    private var pendingVoiceSearch: MethodChannel.Result? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        updateIntent(intent)
        super.onCreate(savedInstanceState)

        mediaRouter = MediaRouter.getInstance(this)
    }

    override fun onNewIntent(intent: Intent) {
        updateIntent(intent)
        super.onNewIntent(intent)
    }

    private fun updateIntent(intent: Intent) {
        if (intent.data?.toString() == MusicAlarm.ALARM_URI) {
            // Opened by the alarm: show over the lock screen and wake the display.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                setShowWhenLocked(true)
                setTurnScreenOn(true)
            }
            getSystemService(NotificationManager::class.java).cancel(MusicAlarm.NOTIFICATION_ID)
        }
        if (
            (intent.action == INTENT_ACTION_MUSIC_PLAYER || intent.action == CATEGORY_APP_MUSIC) &&
            intent.data == null
        ) {
            intent.data = "finamp://play/surprisemix".toUri()
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CLIENT_CERT_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "installClientCertificate" -> {
                    val bytes = call.argument<ByteArray>("bytes")
                    val password = call.argument<String>("password")
                    if (bytes == null || password == null) {
                        result.error("INVALID_ARGS", "bytes and password are required", null)
                        return@setMethodCallHandler
                    }
                    lifecycleScope.launch {
                        withContext(Dispatchers.IO) {
                            try {
                                installClientCertificate(bytes, password)

                                Log.i(
                                    CLIENT_CERT_CHANNEL_LOG_TAG,
                                    "Client certificate installed in Android SSL context"
                                )
                                result.success(null)
                            } catch (e: Exception) {
                                Log.e(
                                    CLIENT_CERT_CHANNEL_LOG_TAG,
                                    "Failed to install client certificate",
                                    e
                                )
                                result.error("CERT_ERROR", e.message, null)
                            }
                        }
                    }
                }
                "clearClientCertificate" -> {
                    lifecycleScope.launch {
                        withContext(Dispatchers.IO) {
                            try {
                                clearClientCertificate()

                                Log.i(
                                    CLIENT_CERT_CHANNEL_LOG_TAG,
                                    "Client certificate cleared from Android SSL context"
                                )
                                result.success(null)
                            } catch (e: Exception) {
                                Log.e(CLIENT_CERT_CHANNEL_LOG_TAG, "Failed to clear client certificate", e)
                                result.error("CERT_ERROR", e.message, null)
                            }
                        }
                    }
                }
                else -> {
                    Log.e(CLIENT_CERT_CHANNEL_LOG_TAG, "Method not found: '${call.method}'")
                    result.notImplemented()
                }
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            DOWNLOADS_SERVICE_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "fixDownloadsFileOwner" -> {
                    val downloadLocations = call.argument<List<String>?>("download_locations").orEmpty()
                    lifecycleScope.launch {
                        withContext(Dispatchers.IO) {
                            fixDownloadsFileOwner(downloadLocations)
                        }
                    }
                    result.success(null)
                }
                else -> {
                    Log.e(DOWNLOADS_SERVICE_CHANNEL_LOG_TAG, "Method not found: '${call.method}'")
                    result.notImplemented()
                }
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            SET_NATIVE_THEME_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "setNativeThemeMode" -> {
                    val uiManager: UiModeManager =
                        applicationContext.getSystemService(UI_MODE_SERVICE) as UiModeManager

                    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
                        // Only api >= 31 supports uiManager.setApplicationNightMode
                        // There might be a way to set this on older versions of android, but
                        // I don't feel like debugging that at the moment
                        result.success(null)
                        return@setMethodCallHandler
                    }
                    val targetMode = call.argument<Int?>("targetMode")
                    when (targetMode) {
                        0 -> {
                            uiManager.setApplicationNightMode(UiModeManager.MODE_NIGHT_AUTO)
                            result.success(null)
                        }
                        1 -> {
                            uiManager.setApplicationNightMode(UiModeManager.MODE_NIGHT_NO)
                            result.success(null)
                        }
                        2 -> {
                            uiManager.setApplicationNightMode(UiModeManager.MODE_NIGHT_YES)
                            result.success(null)
                        }
                        else -> {
                            Log.e(SET_NATIVE_THEME_CHANNEL_LOG_TAG, "Method not found: '${call.method}'")
                            result.notImplemented()
                        }
                    }
                }
                else -> {
                    Log.e(SET_NATIVE_THEME_CHANNEL_LOG_TAG, "Method not found: '${call.method}'")
                    result.notImplemented()
                }
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            VOICE_SEARCH_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "isAvailable" -> result.success(speechRecognizerIntent(null).resolveActivity(packageManager) != null)
                "listen" -> {
                    if (pendingVoiceSearch != null) {
                        result.error("BUSY", "A voice search is already running", null)
                        return@setMethodCallHandler
                    }
                    try {
                        startActivityForResult(
                            speechRecognizerIntent(call.argument<String>("prompt")),
                            VOICE_SEARCH_REQUEST_CODE,
                        )
                        pendingVoiceSearch = result
                    } catch (e: ActivityNotFoundException) {
                        result.error("UNAVAILABLE", "No speech recognizer installed", null)
                    }
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            HOME_WIDGET_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "updateStats" -> {
                    StatsWidgetProvider.update(
                        applicationContext,
                        headline = call.argument<String>("headline"),
                        today = call.argument<String>("today"),
                        week = call.argument<String>("week"),
                        artist = call.argument<String>("artist"),
                        streak = call.argument<String>("streak"),
                    )
                    result.success(null)
                }
                "update" -> {
                    NowPlayingWidgetProvider.update(
                        applicationContext,
                        title = call.argument<String>("title"),
                        artist = call.argument<String>("artist"),
                        playing = call.argument<Boolean>("playing") ?: false,
                    )
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            RECORDER_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "record" -> recordClip(call.argument<Int>("seconds") ?: 10, result)
                else -> result.notImplemented()
            }
        }
        val audioManager = getSystemService(AUDIO_SERVICE) as AudioManager
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, AUDIO_DEVICES_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                private var callback: AudioDeviceCallback? = null

                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    // Sends the names of the connected Bluetooth outputs whenever they change, for car mode.
                    val send = { events.success(bluetoothOutputs(audioManager)) }
                    callback = object : AudioDeviceCallback() {
                        override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>) = send()
                        override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>) = send()
                    }
                    audioManager.registerAudioDeviceCallback(callback, null)
                    send()
                }

                override fun onCancel(arguments: Any?) {
                    callback?.let { audioManager.unregisterAudioDeviceCallback(it) }
                    callback = null
                }
            }
        )
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, NOTIFY_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "lyric" -> {
                    FinampNotifications.lyric(
                        applicationContext,
                        call.argument<String>("title") ?: "",
                        call.argument<String>("line") ?: "",
                        call.argument<String>("next"),
                    )
                    result.success(null)
                }
                "clearLyric" -> {
                    FinampNotifications.clearLyric(applicationContext)
                    result.success(null)
                }
                "concert" -> {
                    FinampNotifications.concert(
                        applicationContext,
                        call.argument<Int>("id") ?: 0,
                        call.argument<String>("title") ?: "",
                        call.argument<String>("text") ?: "",
                        call.argument<String>("url"),
                    )
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, VISUALIZER_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "setEnabled" -> {
                    com.ryanheise.just_audio.Spectrum.setEnabled(call.argument<Boolean>("enabled") ?: false)
                    result.success(null)
                }
                "bands" -> result.success(com.ryanheise.just_audio.Spectrum.read())
                else -> result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.unicornsonlsd.finamp/crossfade").setMethodCallHandler { call, result ->
            when (call.method) {
                // Read back to back, so both positions are from the same moment.
                "positions" -> result.success(
                    (call.argument<List<String>>("ids") ?: emptyList()).map {
                        com.ryanheise.just_audio.MainMethodCallHandler.exactPosition(it)
                    }
                )
                "arm" -> {
                    com.ryanheise.just_audio.CrossfadeBridge.arm(call.argument<String>("main"), call.argument<String>("next"))
                    result.success(null)
                }
                "startMix" -> result.success(com.ryanheise.just_audio.CrossfadeBridge.startMix())
                "scheduleMix" -> result.success(com.ryanheise.just_audio.CrossfadeBridge.scheduleMix(
                    call.argument<Number>("startUs")!!.toLong(),
                    call.argument<Number>("endUs")!!.toLong(),
                    call.argument<Double>("in") ?: 1.0,
                ))
                "gains" -> {
                    com.ryanheise.just_audio.CrossfadeBridge.setGains(
                        call.argument<Double>("out") ?: 1.0,
                        call.argument<Double>("in") ?: 0.0,
                    )
                    result.success(null)
                }
                "status" -> result.success(com.ryanheise.just_audio.CrossfadeBridge.status())
                "diagnostics" -> result.success(com.ryanheise.just_audio.CrossfadeBridge.diagnostics())
                "disarm" -> {
                    com.ryanheise.just_audio.CrossfadeBridge.disarm()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        val stepSensor = StepSensor(applicationContext)
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "$STEPS_CHANNEL/events").setStreamHandler(stepSensor)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, STEPS_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "isAvailable" -> result.success(stepSensor.available)
                else -> result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DJ_VOICE_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "synthesize" -> djVoice.synthesize(
                    call.argument<String>("text")!!,
                    call.argument<String>("language"),
                    call.argument<String>("path")!!,
                    result,
                )
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ALARM_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "get" -> {
                    val settings = MusicAlarm.load(this)
                    result.success(
                        mapOf(
                            "enabled" to settings.enabled,
                            "hour" to settings.hour,
                            "minute" to settings.minute,
                            "days" to settings.days,
                        ),
                    )
                }
                "save" -> result.success(
                    MusicAlarm.save(
                        this,
                        MusicAlarm.Settings(
                            call.argument<Boolean>("enabled") ?: false,
                            call.argument<Int>("hour") ?: 7,
                            call.argument<Int>("minute") ?: 0,
                            call.argument<Int>("days") ?: 0,
                        ),
                    ),
                )
                "snooze" -> result.success(MusicAlarm.snooze(this, call.argument<Int>("minutes") ?: 10))
                "finish" -> {
                    // The alarm is dealt with, so stop showing over the lock screen.
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                        setShowWhenLocked(false)
                        setTurnScreenOn(false)
                    }
                    result.success(null)
                }
                "canUseFullScreenIntent" -> result.success(
                    Build.VERSION.SDK_INT < 34 ||
                        getSystemService(NotificationManager::class.java).canUseFullScreenIntent(),
                )
                "openFullScreenIntentSettings" -> {
                    if (Build.VERSION.SDK_INT >= 34) {
                        startActivity(
                            Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT, "package:$packageName".toUri()),
                        )
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, NIGHT_MODE_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "set" -> {
                    try {
                        setNightMode(call.argument<Int>("sessionId"), call.argument<Boolean>("enabled") ?: false)
                        result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.P)
                    } catch (e: Exception) {
                        result.error("NIGHT_MODE_FAILED", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            OUTPUT_SWITCHER_CHANNEL,
        ).setMethodCallHandler { call, result ->
            Log.d(OUTPUT_SWITCHER_CHANNEL_LOG_TAG, "Calling method: '${call.method}'")
            when (call.method) {
                "showOutputSwitcherDialog" -> {
                    showOutputSwitcherDialog()
                    result.success(null)
                }
                "getRoutes" -> {
                    val routes = mediaRouter.routes
                    routes.log()
                    result.success(routes.map { route ->
                        mapOf(
                            "name" to route.name,
                            "connectionState" to route.connectionState,
                            "isSystemRoute" to route.isSystemRoute,
                            "isDefault" to route.isDefault,
                            "isDeviceSpeaker" to route.isDeviceSpeaker,
                            "isBluetooth" to route.isBluetooth,
                            "volume" to route.volume,
                            "providerPackageName" to route.provider.packageName,
                            "isSelected" to route.isSelected,
                            "deviceType" to route.deviceType,
                            "description" to route.description,
                            "extras" to route.extras,
                            "iconUri" to route.iconUri,
                            // "controlFilters" to route.controlFilters,
                        )
                    })
                }
                "setOutputToDeviceSpeaker" -> {
                    val routes = mediaRouter.routes
                    routes.log()
                    val deviceSpeakerRoute = routes.first { route -> route.isDeviceSpeaker }
                    mediaRouter.selectRoute(deviceSpeakerRoute)
                    result.success(null)
                }
                "setOutputToBluetoothDevice" -> {
                    val routes = mediaRouter.routes
                    routes.log()
                    val bluetoothRoute = routes.first { route -> route.isBluetooth }
                    mediaRouter.selectRoute(bluetoothRoute)
                    result.success(null)
                }
                "setOutputToRouteByName" -> {
                    val routes = mediaRouter.routes
                    routes.log()
                    val targetRoute = routes.first { route ->
                        route.name == call.argument<String>("name")
                    }
                    mediaRouter.selectRoute(targetRoute)
                    result.success(null)
                }
                "openBluetoothSettings" -> {
                    startActivity(Intent(Settings.ACTION_BLUETOOTH_SETTINGS))
                    result.success(null)
                }
                else -> {
                    Log.e(OUTPUT_SWITCHER_CHANNEL_LOG_TAG, "Method not found: '${call.method}'")
                    result.notImplemented()
                }
            }
        }
    }

    private fun bluetoothOutputs(audioManager: AudioManager): List<String> {
        val bluetoothTypes = mutableSetOf(AudioDeviceInfo.TYPE_BLUETOOTH_A2DP)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            bluetoothTypes += AudioDeviceInfo.TYPE_BLE_HEADSET
            bluetoothTypes += AudioDeviceInfo.TYPE_BLE_SPEAKER
        }
        return audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
            .filter { it.type in bluetoothTypes }
            .map { it.productName.toString() }
            .distinct()
    }

    private var nightModeProcessing: Any? = null
    private var nightModeSession: Int? = null

    /**
     * Night mode: a compressor that lifts quiet passages and tames loud ones, plus a limiter, on the player's
     * audio session. Needs Android 9; does nothing on older versions.
     */
    private fun setNightMode(sessionId: Int?, enabled: Boolean) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return
        val current = nightModeProcessing as DynamicsProcessing?
        if (!enabled || sessionId == null || sessionId != nightModeSession) {
            current?.release()
            nightModeProcessing = null
            nightModeSession = null
        }
        if (!enabled || sessionId == null || nightModeProcessing != null) return

        val config = DynamicsProcessing.Config.Builder(
            DynamicsProcessing.VARIANT_FAVOR_FREQUENCY_RESOLUTION,
            2, false, 0, true, 1, false, 0, true,
        ).build()
        val processing = DynamicsProcessing(0, sessionId, config)
        // enabled, cutoff, attack ms, release ms, ratio, threshold dB, knee, noise gate, expander, pre gain, post gain
        processing.setMbcBandAllChannelsTo(
            0,
            DynamicsProcessing.MbcBand(true, 20000f, 10f, 250f, 4f, -30f, 6f, -90f, 1f, 0f, 8f),
        )
        // in use, enabled, link group, attack ms, release ms, ratio, threshold dB, post gain
        processing.setLimiterAllChannelsTo(DynamicsProcessing.Limiter(true, true, 0, 1f, 60f, 10f, -2f, 0f))
        processing.enabled = true
        nightModeProcessing = processing
        nightModeSession = sessionId
    }

    private fun speechRecognizerIntent(prompt: String?) =
        Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            if (prompt != null) putExtra(RecognizerIntent.EXTRA_PROMPT, prompt)
        }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == VOICE_SEARCH_REQUEST_CODE) {
            val phrase = if (resultCode == Activity.RESULT_OK) {
                data?.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)?.firstOrNull()
            } else {
                null
            }
            pendingVoiceSearch?.success(phrase)
            pendingVoiceSearch = null
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    private fun installClientCertificate(bytes: ByteArray, password: String) {
        val keyStore = KeyStore.getInstance("PKCS12")
        keyStore.load(ByteArrayInputStream(bytes), password.toCharArray())

        val keyManagerFactory = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm())
        keyManagerFactory.init(keyStore, password.toCharArray())

        val sslContext = SSLContext.getInstance("TLS")
        sslContext.init(keyManagerFactory.keyManagers, null, null)

        SSLContext.setDefault(sslContext)
        HttpsURLConnection.setDefaultSSLSocketFactory(sslContext.socketFactory)
    }

    private fun clearClientCertificate() {
        val defaultContext = SSLContext.getInstance("TLS")
        defaultContext.init(null, null, null)
        SSLContext.setDefault(defaultContext)
        HttpsURLConnection.setDefaultSSLSocketFactory(defaultContext.socketFactory)
    }

    /**
     * Fixes the owner of downloaded files.
     *
     * Originally, files downloaded by the app were set to a special "cache" user group,
     * which caused the system to count all downloads as cache files.
     * Manually setting the group to the app's UID (which is equal to the gid) fixes this behavior for past downloads.
     */
    @WorkerThread
    private fun fixDownloadsFileOwner(downloadLocations: List<String>) {
        val appUid = applicationInfo.uid
        val cacheGid = try {
            Os.stat(context.cacheDir.absolutePath).st_gid
        } catch (e: ErrnoException) {
            Log.e(DOWNLOADS_SERVICE_CHANNEL_LOG_TAG, "Failed to get cache directory GID", e)
            return
        }
        for (downloadLocation in downloadLocations) {
            val downloadDirectory = File(downloadLocation)
            if (!downloadDirectory.isDirectory) {
                Log.w(DOWNLOADS_SERVICE_CHANNEL_LOG_TAG, "Download location is not a directory: $downloadLocation")
                continue
            }

            for (file in downloadDirectory.walkTopDown()) {
                try {
                    if (!file.isFile) continue

                    // Skip files not owned by the cache group
                    val gid = Os.stat(file.absolutePath).st_gid
                    if (gid != cacheGid) continue

                    Os.chown(file.absolutePath, -1, appUid) // uid -1 keeps current owner
                } catch (e: ErrnoException) {
                    Log.e(DOWNLOADS_SERVICE_CHANNEL_LOG_TAG, "Failed to fix owner for: ${file.absolutePath}", e)
                }
            }
        }
    }

    private fun List<MediaRouter.RouteInfo>.log() {
        forEach { route ->
            Log.d(
                OUTPUT_SWITCHER_CHANNEL_LOG_TAG,
                "Route: ${route.name}, connection state: ${route.connectionState}, system route: ${route.isSystemRoute}, default: ${route.isDefault}, device speaker: ${route.isDeviceSpeaker}, bluetooth: ${route.isBluetooth}, volume: ${route.volume}, provider: ${route.provider.packageName}"
            )
        }
    }

    private fun showOutputSwitcherDialog() {
        SystemOutputSwitcherDialogController.showDialog(this)
    }

    /** Records [seconds] of microphone audio to an AAC file for song recognition and returns its path. */
    private fun recordClip(seconds: Int, result: MethodChannel.Result) {
        val file = File(cacheDir, "recognition.m4a")
        val recorder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) MediaRecorder(this) else @Suppress("DEPRECATION") MediaRecorder()
        try {
            recorder.setAudioSource(MediaRecorder.AudioSource.MIC)
            recorder.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            recorder.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            recorder.setAudioSamplingRate(44100)
            recorder.setAudioEncodingBitRate(128000)
            recorder.setOutputFile(file.absolutePath)
            recorder.prepare()
            recorder.start()
        } catch (e: Exception) {
            recorder.release()
            result.error("RECORD_FAILED", e.message, null)
            return
        }
        lifecycleScope.launch {
            kotlinx.coroutines.delay(seconds * 1000L)
            try {
                recorder.stop()
                result.success(file.absolutePath)
            } catch (e: Exception) {
                result.error("RECORD_FAILED", e.message, null)
            } finally {
                recorder.release()
            }
        }
    }
}
