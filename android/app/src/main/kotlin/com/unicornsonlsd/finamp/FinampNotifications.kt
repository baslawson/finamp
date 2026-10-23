package com.unicornsonlsd.finamp

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.core.app.NotificationCompat

/** Finamp+ notifications that aren't the media player: lock screen lyrics and concert alerts. */
object FinampNotifications {
    private const val LYRICS_CHANNEL = "lyrics"
    private const val CONCERTS_CHANNEL = "concerts"
    private const val LYRICS_ID = 7301

    private fun manager(context: Context) = context.getSystemService(NotificationManager::class.java)

    private fun openApp(context: Context): PendingIntent = PendingIntent.getActivity(
        context,
        1,
        Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    private fun notify(context: Context, id: Int, builder: NotificationCompat.Builder) {
        try {
            manager(context).notify(id, builder.build())
        } catch (e: SecurityException) {
            // No notification permission.
        }
    }

    /** Shows (or updates) the lyric line being sung, visible on the lock screen. Silent. */
    fun lyric(context: Context, title: String, line: String, next: String?) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager(context).createNotificationChannel(
                NotificationChannel(LYRICS_CHANNEL, "Lock screen lyrics", NotificationManager.IMPORTANCE_DEFAULT).apply {
                    setSound(null, null)
                    enableVibration(false)
                    setShowBadge(false)
                    lockscreenVisibility = android.app.Notification.VISIBILITY_PUBLIC
                },
            )
        }
        val text = if (next.isNullOrBlank()) line else "$line\n$next"
        notify(
            context,
            LYRICS_ID,
            NotificationCompat.Builder(context, LYRICS_CHANNEL)
                .setSmallIcon(R.mipmap.white)
                .setContentTitle(line)
                .setContentText(title)
                .setStyle(NotificationCompat.BigTextStyle().bigText(text).setBigContentTitle(title))
                .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                .setCategory(NotificationCompat.CATEGORY_STATUS)
                .setPriority(NotificationCompat.PRIORITY_DEFAULT)
                .setOngoing(true)
                .setSilent(true)
                .setOnlyAlertOnce(true)
                .setShowWhen(false)
                .setContentIntent(openApp(context)),
        )
    }

    fun clearLyric(context: Context) = manager(context).cancel(LYRICS_ID)

    /** Tells about a concert; tapping it opens the ticket page. */
    fun concert(context: Context, id: Int, title: String, text: String, url: String?) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager(context).createNotificationChannel(
                NotificationChannel(CONCERTS_CHANNEL, "Concert alerts", NotificationManager.IMPORTANCE_DEFAULT),
            )
        }
        val intent = if (url != null) {
            PendingIntent.getActivity(
                context,
                id,
                Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
        } else {
            openApp(context)
        }
        notify(
            context,
            id,
            NotificationCompat.Builder(context, CONCERTS_CHANNEL)
                .setSmallIcon(R.mipmap.white)
                .setContentTitle(title)
                .setContentText(text)
                .setStyle(NotificationCompat.BigTextStyle().bigText(text))
                .setAutoCancel(true)
                .setContentIntent(intent),
        )
    }
}
