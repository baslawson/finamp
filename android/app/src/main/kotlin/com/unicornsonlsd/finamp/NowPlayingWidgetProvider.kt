package com.unicornsonlsd.finamp

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.view.KeyEvent
import android.widget.RemoteViews
import com.ryanheise.audioservice.MediaButtonReceiver

/**
 * Home screen widget showing the current track with previous, play/pause and next buttons.
 *
 * The Dart side pushes the now playing state through [update]. The buttons send media
 * button events to audio_service, the same way headset buttons control playback.
 */
class NowPlayingWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray) {
        appWidgetManager.updateAppWidget(appWidgetIds, buildViews(context))
    }

    companion object {
        private const val PREFS = "now_playing_widget"

        fun update(context: Context, title: String?, artist: String?, playing: Boolean) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                .putString("title", title)
                .putString("artist", artist)
                .putBoolean("playing", playing)
                .apply()
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(ComponentName(context, NowPlayingWidgetProvider::class.java))
            if (ids.isNotEmpty()) {
                manager.updateAppWidget(ids, buildViews(context))
            }
        }

        private fun buildViews(context: Context): RemoteViews {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val playing = prefs.getBoolean("playing", false)
            return RemoteViews(context.packageName, R.layout.now_playing_widget).apply {
                setTextViewText(R.id.widget_title, prefs.getString("title", null) ?: context.getString(R.string.app_name))
                setTextViewText(R.id.widget_artist, prefs.getString("artist", null) ?: "")
                setImageViewResource(
                    R.id.widget_play_pause,
                    if (playing) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play,
                )
                setOnClickPendingIntent(R.id.widget_info, openAppIntent(context))
                setOnClickPendingIntent(R.id.widget_previous, mediaButtonIntent(context, KeyEvent.KEYCODE_MEDIA_PREVIOUS))
                setOnClickPendingIntent(R.id.widget_play_pause, mediaButtonIntent(context, KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE))
                setOnClickPendingIntent(R.id.widget_next, mediaButtonIntent(context, KeyEvent.KEYCODE_MEDIA_NEXT))
            }
        }

        private fun openAppIntent(context: Context): PendingIntent = PendingIntent.getActivity(
            context,
            0,
            Intent(context, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        private fun mediaButtonIntent(context: Context, keyCode: Int): PendingIntent {
            val intent = Intent(Intent.ACTION_MEDIA_BUTTON)
                .setComponent(ComponentName(context, MediaButtonReceiver::class.java))
                .putExtra(Intent.EXTRA_KEY_EVENT, KeyEvent(KeyEvent.ACTION_DOWN, keyCode))
            // The key code doubles as request code, so each button keeps its own PendingIntent.
            return PendingIntent.getBroadcast(
                context,
                keyCode,
                intent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
        }
    }
}
