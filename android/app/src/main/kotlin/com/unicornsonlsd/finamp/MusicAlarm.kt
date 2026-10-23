package com.unicornsonlsd.finamp

import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.net.toUri
import java.util.Calendar

/**
 * The music alarm. Android forgets alarms on reboot, so the time and days live in native preferences where
 * [MusicAlarmReceiver] can schedule them again. What to play is decided in Dart once the app opens.
 */
object MusicAlarm {
    private const val PREFS = "finamp_plus_alarm"
    const val ACTION_FIRE = "com.baslawson.finampplus.ALARM_FIRE"
    const val EXTRA_SNOOZE = "snooze"
    const val ALARM_URI = "finamp://alarm"
    private const val CHANNEL_ID = "finamp_plus_alarm"
    const val NOTIFICATION_ID = 7311
    private const val REQUEST_ALARM = 7311
    private const val REQUEST_SNOOZE = 7312

    data class Settings(val enabled: Boolean, val hour: Int, val minute: Int, val days: Int)

    fun load(context: Context): Settings {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        return Settings(
            prefs.getBoolean("enabled", false),
            prefs.getInt("hour", 7),
            prefs.getInt("minute", 0),
            prefs.getInt("days", 0),
        )
    }

    /** Saves the alarm and schedules it. Returns the next ring time, or null when it's off. */
    fun save(context: Context, settings: Settings): Long? {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putBoolean("enabled", settings.enabled)
            .putInt("hour", settings.hour)
            .putInt("minute", settings.minute)
            .putInt("days", settings.days)
            .apply()
        return schedule(context)
    }

    fun schedule(context: Context): Long? {
        val alarmManager = context.getSystemService(AlarmManager::class.java)
        val settings = load(context)
        val fire = fireIntent(context, REQUEST_ALARM, snooze = false)
        alarmManager.cancel(fire)
        if (!settings.enabled) return null
        val next = nextTrigger(settings, Calendar.getInstance())
        alarmManager.setAlarmClock(AlarmManager.AlarmClockInfo(next, openIntent(context)), fire)
        return next
    }

    fun snooze(context: Context, minutes: Int): Long {
        val time = System.currentTimeMillis() + minutes * 60_000L
        context.getSystemService(AlarmManager::class.java).setAlarmClock(
            AlarmManager.AlarmClockInfo(time, openIntent(context)),
            fireIntent(context, REQUEST_SNOOZE, snooze = true),
        )
        return time
    }

    /**
     * The next time the alarm rings after [now]. [Settings.days] is a bit mask with Monday as bit 0 and Sunday as
     * bit 6; 0 rings once at the next occurrence of the time.
     */
    fun nextTrigger(settings: Settings, now: Calendar): Long {
        val candidate = (now.clone() as Calendar).apply {
            set(Calendar.HOUR_OF_DAY, settings.hour)
            set(Calendar.MINUTE, settings.minute)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }
        for (offset in 0..7) {
            val day = (candidate.clone() as Calendar).apply { add(Calendar.DAY_OF_YEAR, offset) }
            if (!day.after(now)) continue
            // Calendar counts Sunday as 1 and Saturday as 7.
            val weekday = (day.get(Calendar.DAY_OF_WEEK) + 5) % 7
            if (settings.days == 0 || settings.days and (1 shl weekday) != 0) return day.timeInMillis
        }
        return candidate.timeInMillis + 24 * 60 * 60 * 1000L
    }

    fun openIntent(context: Context): PendingIntent = PendingIntent.getActivity(
        context,
        0,
        Intent(context, MainActivity::class.java)
            .setData(ALARM_URI.toUri())
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    private fun fireIntent(context: Context, request: Int, snooze: Boolean): PendingIntent =
        PendingIntent.getBroadcast(
            context,
            request,
            Intent(context, MusicAlarmReceiver::class.java).setAction(ACTION_FIRE).putExtra(EXTRA_SNOOZE, snooze),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

    /**
     * Shows the alarm. On a locked or idle phone the full-screen intent opens Finamp+ straight away; while the phone
     * is in use it shows as a heads-up notification to tap.
     */
    fun ring(context: Context) {
        val notifications = context.getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            notifications.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Music alarm", NotificationManager.IMPORTANCE_HIGH).apply {
                    setSound(null, null)
                },
            )
        }
        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.mipmap.white)
            .setContentTitle("Finamp+ alarm")
            .setContentText("Tap to start your music")
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setContentIntent(openIntent(context))
            .setFullScreenIntent(openIntent(context), true)
            .setAutoCancel(true)
            .build()
        try {
            notifications.notify(NOTIFICATION_ID, notification)
        } catch (e: SecurityException) {
            // No notification permission; the alarm can't show itself.
        }
    }
}

/** Rings the alarm, and schedules it again after a reboot, an app update or a clock change. */
class MusicAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == MusicAlarm.ACTION_FIRE) {
            MusicAlarm.ring(context)
            val settings = MusicAlarm.load(context)
            if (!intent.getBooleanExtra(MusicAlarm.EXTRA_SNOOZE, false) && settings.days == 0) {
                // A one-time alarm turns itself off once it has rung.
                MusicAlarm.save(context, settings.copy(enabled = false))
                return
            }
        }
        MusicAlarm.schedule(context)
    }
}
