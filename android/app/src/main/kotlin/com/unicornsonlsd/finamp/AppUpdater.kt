package com.unicornsonlsd.finamp

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import android.util.Log
import androidx.core.net.toUri
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.TimeUnit

/**
 * Finamp+ updating itself from its GitHub releases: what's installed, the permission to install, checking a
 * downloaded APK is really the next Finamp+, installing it, and a daily check while the app is closed.
 */
object AppUpdater {
    private const val TAG = "AppUpdater"
    private const val PREFS = "finamp_updates"
    private const val WORK = "finamp-update-check"
    private const val LATEST = "https://api.github.com/repos/baslawson/finamp/releases/latest"
    const val ACTION_STATUS = "com.unicornsonlsd.finamp.UPDATE_STATUS"

    /** For calls from Flutter: lives as long as the app, so a call made after the activity closed still answers. */
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    /** The last install result, for the app to show the next time it asks. */
    @Volatile
    var lastResult: Map<String, Any?>? = null

    /** Whether the app is in front, so Android's confirmation can open at once instead of as a notification. */
    @Volatile
    var foreground: Activity? = null

    private fun ownInfo(context: Context, flags: Int = 0): PackageInfo =
        context.packageManager.getPackageInfo(context.packageName, flags)

    @Suppress("DEPRECATION")
    private fun versionCode(info: PackageInfo): Long =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) info.longVersionCode else info.versionCode.toLong()

    fun info(context: Context): Map<String, Any?> {
        val own = ownInfo(context)
        val installer = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                context.packageManager.getInstallSourceInfo(context.packageName).installingPackageName
            } else {
                @Suppress("DEPRECATION")
                context.packageManager.getInstallerPackageName(context.packageName)
            }
        } catch (e: Exception) {
            null
        }
        return mapOf(
            "version" to own.versionName,
            "build" to versionCode(own),
            "installedAt" to own.firstInstallTime,
            "updatedAt" to own.lastUpdateTime,
            "installer" to installer,
            "self" to (installer == context.packageName),
            "canInstall" to canInstall(context),
            "abis" to Build.SUPPORTED_ABIS.toList(),
            "sdk" to Build.VERSION.SDK_INT,
        )
    }

    fun canInstall(context: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.O || context.packageManager.canRequestPackageInstalls()

    /** Opens Android's "Install unknown apps" switch for Finamp+. */
    fun openInstallSettings(activity: Activity) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            activity.startActivity(
                Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, "package:${activity.packageName}".toUri()),
            )
        }
    }

    /**
     * Why the APK at [path] can't update this app, or null when it can: it must be Finamp+ itself, newer, and signed
     * with the same key. Android refuses the others anyway, but this tells the user why.
     */
    @Suppress("DEPRECATION")
    fun problem(context: Context, path: String): String? {
        val pm = context.packageManager
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            PackageManager.GET_SIGNING_CERTIFICATES
        } else {
            PackageManager.GET_SIGNATURES
        }
        val apk = pm.getPackageArchiveInfo(path, flags) ?: return "The download isn't a working app."
        if (apk.packageName != context.packageName) return "The download is a different app."
        val own = ownInfo(context, flags)
        if (versionCode(apk) <= versionCode(own)) return "The download isn't newer than this version."
        val same = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val signers = apk.signingInfo?.apkContentsSigners ?: emptyArray()
            signers.isNotEmpty() && signers.all { pm.hasSigningCertificate(context.packageName, it.toByteArray(), PackageManager.CERT_INPUT_RAW_X509) }
        } else {
            apk.signatures?.toSet() == own.signatures?.toSet()
        }
        return if (same) null else "The download isn't signed like this Finamp+."
    }

    /**
     * Installs the APK at [path] over this app. With [silent], Android 12 and later skip the confirmation when
     * Finamp+ installed itself last time; otherwise (and the first time) Android asks.
     */
    fun install(context: Context, path: String, silent: Boolean) {
        val installer = context.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
            setAppPackageName(context.packageName)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                setRequireUserAction(
                    if (silent) {
                        PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED
                    } else {
                        PackageInstaller.SessionParams.USER_ACTION_REQUIRED
                    },
                )
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                setPackageSource(PackageInstaller.PACKAGE_SOURCE_DOWNLOADED_FILE)
            }
        }
        val file = File(path)
        val id = installer.createSession(params)
        installer.openSession(id).use { session ->
            try {
                file.inputStream().use { input ->
                    session.openWrite("finamp-plus.apk", 0, file.length()).use { output ->
                        input.copyTo(output)
                        session.fsync(output)
                    }
                }
            } catch (e: Exception) {
                // Out of room, say: Android drops what it was given instead of keeping it.
                session.abandon()
                throw e
            }
            val status = PendingIntent.getBroadcast(
                context,
                id,
                Intent(context, UpdateInstallReceiver::class.java).setAction(ACTION_STATUS),
                // Mutable: Android fills in the result.
                PendingIntent.FLAG_UPDATE_CURRENT or
                    (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0),
            )
            session.commit(status.intentSender)
        }
    }

    /** Remembers the update settings for the daily check, and starts or stops it. */
    fun configure(context: Context, check: Boolean, skipped: String?) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putBoolean("check", check)
            .putString("skipped", skipped)
            .apply()
        val work = WorkManager.getInstance(context)
        if (check) {
            val request = PeriodicWorkRequestBuilder<UpdateCheckWorker>(1, TimeUnit.DAYS)
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                .build()
            work.enqueueUniquePeriodicWork(WORK, ExistingPeriodicWorkPolicy.KEEP, request)
        } else {
            work.cancelUniqueWork(WORK)
        }
    }

    /** The newest release's tag, when it's newer than this app and not skipped or already told about. */
    suspend fun checkInBackground(context: Context): String? = withContext(Dispatchers.IO) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (!prefs.getBoolean("check", false)) return@withContext null
        val connection = URL(LATEST).openConnection() as HttpURLConnection
        connection.connectTimeout = 15000
        connection.readTimeout = 15000
        connection.setRequestProperty("Accept", "application/vnd.github+json")
        val tag = try {
            if (connection.responseCode != 200) return@withContext null
            JSONObject(connection.inputStream.bufferedReader().readText()).optString("tag_name")
        } finally {
            connection.disconnect()
        }
        val installed = ownInfo(context).versionName ?: return@withContext null
        if (!isNewer(tag, installed) || tag == prefs.getString("skipped", null) || tag == prefs.getString("told", null)) {
            return@withContext null
        }
        // Not shown, so not told: the next check tries again once notifications are allowed.
        if (!FinampNotifications.updatesAllowed(context)) return@withContext null
        prefs.edit().putString("told", tag).apply()
        tag
    }

    /** Whether release [tag] ("v1.6.72") is newer than [installed] ("1.6.71"). Same rule as the app's. */
    fun isNewer(tag: String, installed: String): Boolean {
        val pattern = Regex("""(\d+)\.(\d+)\.(\d+)""")
        val remote = pattern.find(tag)?.groupValues?.drop(1)?.map { it.toInt() } ?: return false
        val local = pattern.find(installed)?.groupValues?.drop(1)?.map { it.toInt() } ?: return false
        for (i in 0 until 3) {
            if (remote[i] != local[i]) return remote[i] > local[i]
        }
        return false
    }

    fun log(message: String) = Log.i(TAG, message)
}

/** The daily check while Finamp+ is closed: a notification when there's a new version. */
class UpdateCheckWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        return try {
            AppUpdater.checkInBackground(applicationContext)?.let { FinampNotifications.updateAvailable(applicationContext, it) }
            Result.success()
        } catch (e: Exception) {
            AppUpdater.log("Background update check failed: $e")
            Result.success()
        }
    }
}

/** Android's answer to an install: ask the user to confirm, or report how it went. */
class UpdateInstallReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
        val message = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)
        when (status) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                @Suppress("DEPRECATION")
                val confirm = (
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
                    } else {
                        intent.getParcelableExtra(Intent.EXTRA_INTENT)
                    }
                    ) ?: return
                val activity = AppUpdater.foreground
                AppUpdater.lastResult = mapOf("status" to "confirm")
                if (activity != null) {
                    activity.startActivity(confirm)
                } else {
                    // Android doesn't let an app in the background open screens: the user taps to confirm.
                    FinampNotifications.updateConfirm(context, confirm)
                }
            }
            PackageInstaller.STATUS_SUCCESS -> AppUpdater.lastResult = mapOf("status" to "installed")
            PackageInstaller.STATUS_FAILURE_ABORTED -> AppUpdater.lastResult = mapOf("status" to "cancelled")
            else -> {
                AppUpdater.log("Update install failed ($status): $message")
                AppUpdater.lastResult = mapOf("status" to "failed", "message" to message)
            }
        }
    }
}
