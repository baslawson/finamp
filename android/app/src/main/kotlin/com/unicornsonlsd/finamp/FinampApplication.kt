package com.unicornsonlsd.finamp

import android.app.Application
import com.ryanheise.just_audio.JustAudioPlugin

class FinampApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        // Playback can start an engine with no activity (a Bluetooth or system play button), which never
        // reaches MainActivity.configureFlutterEngine. Hooking plugin registration reaches every engine.
        JustAudioPlugin.engineHook = JustAudioPlugin.EngineHook { context, messenger ->
            BackgroundChannels.register(context, messenger)
        }
    }
}
