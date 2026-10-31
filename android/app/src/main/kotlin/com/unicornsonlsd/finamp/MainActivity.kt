package com.unicornsonlsd.finamp

import android.app.Activity
import android.app.NotificationManager
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.Intent.CATEGORY_APP_MUSIC
import android.media.MediaRecorder
import android.media.AudioManager
import android.os.Build
import android.os.Bundle
import android.provider.MediaStore.INTENT_ACTION_MUSIC_PLAYER
import android.provider.Settings
import android.speech.RecognizerIntent
import android.util.Log
import androidx.core.net.toUri
import androidx.lifecycle.lifecycleScope
import androidx.mediarouter.app.SystemOutputSwitcherDialogController
import androidx.mediarouter.media.MediaRouter
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.launch
import java.io.File


class MainActivity : AudioServiceActivity() {
    companion object {
        private const val OUTPUT_SWITCHER_CHANNEL = "com.unicornsonlsd.finamp/output_switcher"
        private const val OUTPUT_SWITCHER_CHANNEL_LOG_TAG = "OutputSwitcherChannel"

        private const val VOICE_SEARCH_CHANNEL = "com.unicornsonlsd.finamp/voice_search"
        private const val VOICE_SEARCH_REQUEST_CODE = 4711

        private const val RECORDER_CHANNEL = "com.unicornsonlsd.finamp/recorder"
        private const val ALARM_CHANNEL = "com.unicornsonlsd.finamp/alarm"
    }

    private lateinit var mediaRouter: MediaRouter

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

    override fun onResume() {
        super.onResume()
        AppUpdater.foreground = this
    }

    override fun onPause() {
        if (AppUpdater.foreground === this) AppUpdater.foreground = null
        super.onPause()
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

    // Channels that need no screen are in BackgroundChannels, added to every engine by FinampApplication.
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
            RECORDER_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "record" -> recordClip(call.argument<Int>("seconds") ?: 15, result)
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

    /**
     * The microphone as it is, without the gain control and noise suppression that suit calls but change music:
     * unprocessed where the phone offers it, otherwise as for speech recognition, which leaves those out too.
     */
    private fun recognitionSource(): Int {
        val audioManager = getSystemService(AUDIO_SERVICE) as AudioManager
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N &&
            audioManager.getProperty(AudioManager.PROPERTY_SUPPORT_AUDIO_SOURCE_UNPROCESSED) == "true"
        ) MediaRecorder.AudioSource.UNPROCESSED else MediaRecorder.AudioSource.VOICE_RECOGNITION
    }

    /** Records [seconds] of microphone audio to an AAC file for song recognition and returns its path. */
    private fun recordClip(seconds: Int, result: MethodChannel.Result) {
        val file = File(cacheDir, "recognition.m4a")
        val recorder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) MediaRecorder(this) else @Suppress("DEPRECATION") MediaRecorder()
        try {
            recorder.setAudioSource(recognitionSource())
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
