package com.unicornsonlsd.finamp

import android.content.Context
import android.os.Bundle
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.Locale
import java.util.UUID

/** Renders the DJ's lines with the system text-to-speech engine, for when no AI voice is available. */
class DjVoice(private val context: Context) {
    private var tts: TextToSpeech? = null
    private var ready = false
    private val waiting = mutableListOf<() -> Unit>()
    private val pending = mutableMapOf<String, Pair<MethodChannel.Result, String>>()

    private fun withEngine(action: () -> Unit) {
        if (ready) return action()
        waiting.add(action)
        if (tts != null) return
        tts = TextToSpeech(context.applicationContext) { status ->
            ready = status == TextToSpeech.SUCCESS
            if (ready) {
                tts!!.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                    override fun onStart(utteranceId: String) {}

                    override fun onDone(utteranceId: String) {
                        pending.remove(utteranceId)?.let { (result, path) -> post { result.success(path) } }
                    }

                    @Deprecated("Deprecated in Java")
                    override fun onError(utteranceId: String) {
                        pending.remove(utteranceId)?.let { (result, _) -> post { result.success(null) } }
                    }
                })
            }
            val actions = waiting.toList()
            waiting.clear()
            actions.forEach { it() }
        }
    }

    private fun post(action: () -> Unit) = android.os.Handler(context.mainLooper).post(action)

    /** Writes [text] spoken in [language] to a WAV file at [path]; the result is the path, or null on failure. */
    fun synthesize(text: String, language: String?, path: String, result: MethodChannel.Result) {
        withEngine {
            val engine = tts
            if (!ready || engine == null) return@withEngine result.success(null)
            language?.let { engine.language = Locale.forLanguageTag(it) }
            // A touch quicker and brighter than the default, closer to a radio host.
            engine.setSpeechRate(1.05f)
            engine.setPitch(1.0f)
            val id = UUID.randomUUID().toString()
            pending[id] = result to path
            val status = engine.synthesizeToFile(text, Bundle(), File(path), id)
            if (status != TextToSpeech.SUCCESS) {
                pending.remove(id)
                result.success(null)
            }
        }
    }

    fun shutdown() {
        tts?.shutdown()
        tts = null
        ready = false
    }
}
