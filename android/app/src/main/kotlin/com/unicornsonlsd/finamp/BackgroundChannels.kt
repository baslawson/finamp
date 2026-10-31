package com.unicornsonlsd.finamp

import android.app.UiModeManager
import android.content.Context
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.media.audiofx.DynamicsProcessing
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.system.ErrnoException
import android.system.Os
import android.util.Log
import androidx.annotation.WorkerThread
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.ByteArrayInputStream
import java.io.File
import java.security.KeyStore
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext

/**
 * The app's channels that need no activity. They are added to every Flutter engine as it starts, so they also work
 * when playback starts in the background (a Bluetooth or system play button) without the app's screen.
 * Channels that need the screen (voice search, recorder, alarm, output switcher) stay in [MainActivity].
 */
class BackgroundChannels private constructor(private val context: Context) {
    companion object {
        const val CLIENT_CERT_CHANNEL = "com.unicornsonlsd.finamp/client_certificate"
        private const val CLIENT_CERT_CHANNEL_LOG_TAG = "ClientCertChannel"

        const val DOWNLOADS_SERVICE_CHANNEL = "com.unicornsonlsd.finamp/downloads_service"
        private const val DOWNLOADS_SERVICE_CHANNEL_LOG_TAG = "DownloadsServiceChannel"

        const val SET_NATIVE_THEME_CHANNEL = "com.unicornsonlsd.finamp/set_native_theme"
        private const val SET_NATIVE_THEME_CHANNEL_LOG_TAG = "setNativeThemeChannel"

        const val HOME_WIDGET_CHANNEL = "com.unicornsonlsd.finamp/home_widget"
        const val AUDIO_DEVICES_CHANNEL = "com.unicornsonlsd.finamp/audio_devices"
        const val NIGHT_MODE_CHANNEL = "com.unicornsonlsd.finamp/night_mode"
        const val DJ_VOICE_CHANNEL = "com.unicornsonlsd.finamp/dj_voice"
        const val NOTIFY_CHANNEL = "com.unicornsonlsd.finamp/notify"
        const val VISUALIZER_CHANNEL = "com.unicornsonlsd.finamp/visualizer"
        const val CROSSFADE_CHANNEL = "com.unicornsonlsd.finamp/crossfade"
        const val STEPS_CHANNEL = "com.unicornsonlsd.finamp/steps"
        const val UPDATES_CHANNEL = "com.unicornsonlsd.finamp/updates"

        fun register(context: Context, messenger: BinaryMessenger) =
            BackgroundChannels(context.applicationContext).register(messenger)
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val main = Handler(Looper.getMainLooper())
    private val djVoice by lazy { DjVoice(context) }

    private fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, CLIENT_CERT_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "installClientCertificate" -> {
                    val bytes = call.argument<ByteArray>("bytes")
                    val password = call.argument<String>("password")
                    if (bytes == null || password == null) {
                        result.error("INVALID_ARGS", "bytes and password are required", null)
                        return@setMethodCallHandler
                    }
                    scope.launch {
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
                    scope.launch {
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
        MethodChannel(messenger, DOWNLOADS_SERVICE_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "fixDownloadsFileOwner" -> {
                    val downloadLocations = call.argument<List<String>?>("download_locations").orEmpty()
                    scope.launch {
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
        MethodChannel(messenger, SET_NATIVE_THEME_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "setNativeThemeMode" -> {
                    val uiManager: UiModeManager =
                        context.getSystemService(Context.UI_MODE_SERVICE) as UiModeManager

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
        MethodChannel(messenger, HOME_WIDGET_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "updateStats" -> {
                    StatsWidgetProvider.update(
                        context,
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
                        context,
                        title = call.argument<String>("title"),
                        artist = call.argument<String>("artist"),
                        playing = call.argument<Boolean>("playing") ?: false,
                    )
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        EventChannel(messenger, AUDIO_DEVICES_CHANNEL).setStreamHandler(
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
        MethodChannel(messenger, UPDATES_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "info" -> result.success(AppUpdater.info(context))
                "openInstallSettings" -> {
                    AppUpdater.openInstallSettings(AppUpdater.foreground ?: context)
                    result.success(null)
                }
                "problem" -> {
                    val path = call.argument<String>("path") ?: return@setMethodCallHandler result.error("path", null, null)
                    AppUpdater.scope.launch {
                        result.success(withContext(Dispatchers.IO) { AppUpdater.problem(context, path) })
                    }
                }
                "install" -> {
                    val path = call.argument<String>("path") ?: return@setMethodCallHandler result.error("path", null, null)
                    val silent = call.argument<Boolean>("silent") ?: false
                    AppUpdater.lastResult = null
                    AppUpdater.scope.launch {
                        try {
                            withContext(Dispatchers.IO) { AppUpdater.install(context, path, silent) }
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("install", e.message, null)
                        }
                    }
                }
                "lastResult" -> result.success(AppUpdater.lastResult)
                "configure" -> {
                    AppUpdater.configure(
                        context,
                        call.argument<Boolean>("check") ?: false,
                        call.argument<String>("skipped"),
                    )
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(messenger, NOTIFY_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "lyric" -> {
                    FinampNotifications.lyric(
                        context,
                        call.argument<String>("title") ?: "",
                        call.argument<String>("line") ?: "",
                        call.argument<String>("next"),
                    )
                    result.success(null)
                }
                "clearLyric" -> {
                    FinampNotifications.clearLyric(context)
                    result.success(null)
                }
                "concert" -> {
                    FinampNotifications.concert(
                        context,
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
        MethodChannel(messenger, VISUALIZER_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "setEnabled" -> {
                    com.ryanheise.just_audio.Spectrum.setEnabled(call.argument<Boolean>("enabled") ?: false)
                    result.success(null)
                }
                "bands" -> result.success(com.ryanheise.just_audio.Spectrum.read())
                else -> result.notImplemented()
            }
        }
        MethodChannel(messenger, CROSSFADE_CHANNEL).setMethodCallHandler { call, result ->
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
        val stepSensor = StepSensor(context)
        EventChannel(messenger, "$STEPS_CHANNEL/events").setStreamHandler(stepSensor)
        MethodChannel(messenger, STEPS_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "isAvailable" -> result.success(stepSensor.available)
                else -> result.notImplemented()
            }
        }
        MethodChannel(messenger, DJ_VOICE_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "synthesize" -> djVoice.synthesize(
                    call.argument<String>("text")!!,
                    call.argument<String>("language"),
                    call.argument<String>("path")!!,
                    result,
                )
                "decodeAudio" -> {
                    val input = call.argument<String>("input")!!
                    val output = call.argument<String>("output")!!
                    val maxSeconds = call.argument<Int>("maxSeconds")!!
                    Thread {
                        val error = runCatching { DjAudioDecoder.decode(input, output, maxSeconds) }.exceptionOrNull()
                        main.post {
                            if (error == null) result.success(output) else result.error("decode", error.toString(), null)
                        }
                    }.start()
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(messenger, NIGHT_MODE_CHANNEL).setMethodCallHandler { call, result ->
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
        val appUid = context.applicationInfo.uid
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
}
