package com.unicornsonlsd.finamp

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews

/**
 * Home screen widget with listening stats: time listened today, this week, the top artist and the
 * listening streak. The Dart side computes the (already translated) lines and pushes them through [update].
 */
class StatsWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray) {
        appWidgetManager.updateAppWidget(appWidgetIds, buildViews(context))
    }

    companion object {
        private const val PREFS = "stats_widget"

        fun update(context: Context, headline: String?, today: String?, week: String?, artist: String?, streak: String?) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                .putString("headline", headline)
                .putString("today", today)
                .putString("week", week)
                .putString("artist", artist)
                .putString("streak", streak)
                .apply()
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(ComponentName(context, StatsWidgetProvider::class.java))
            if (ids.isNotEmpty()) {
                manager.updateAppWidget(ids, buildViews(context))
            }
        }

        private fun buildViews(context: Context): RemoteViews {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            return RemoteViews(context.packageName, R.layout.stats_widget).apply {
                setTextViewText(R.id.stats_headline, prefs.getString("headline", null) ?: context.getString(R.string.app_name))
                setTextViewText(R.id.stats_today, prefs.getString("today", null) ?: "–")
                setTextViewText(R.id.stats_week, prefs.getString("week", null) ?: "")
                setTextViewText(R.id.stats_artist, prefs.getString("artist", null) ?: "")
                setTextViewText(R.id.stats_streak, prefs.getString("streak", null) ?: "")
                setOnClickPendingIntent(
                    R.id.stats_root,
                    PendingIntent.getActivity(
                        context,
                        1,
                        Intent(context, MainActivity::class.java),
                        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                    ),
                )
            }
        }
    }
}
