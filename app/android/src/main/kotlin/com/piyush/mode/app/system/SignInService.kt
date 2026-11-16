package com.piyush.mode.app.system

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import com.piyush.mode.app.MainActivity
import com.piyush.mode.app.R
import com.piyush.mode.core.common.AppLog

/**
 * Keeps Mode awake while the ChatGPT page is open in the browser. Without it Android freezes Mode about a
 * minute after the browser covers it (seen on a OnePlus 9R, Android 17), and a frozen Mode can't answer the
 * page's callback on 127.0.0.1. A short service: Android 14 and later allow it up to about 3 minutes with no
 * extra permission, which is as long as the sign-in waits anyway. Android 13 doesn't freeze apps by default,
 * so it isn't started there.
 */
class SignInService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            stopSelf()
            return START_NOT_STICKY
        }
        runCatching { startForeground(NOTICE_ID, notice(this), ServiceInfo.FOREGROUND_SERVICE_TYPE_SHORT_SERVICE) }
            .onSuccess { AppLog.log("chatgpt", "kept awake while the page is open") }
            .onFailure { AppLog.log("chatgpt", "couldn't keep awake: ${it::class.simpleName}: ${it.message}"); stopSelf() }
        return START_NOT_STICKY
    }

    /** Android's limit for a short service (about 3 minutes): stop at once, or Android counts it as not responding. */
    override fun onTimeout(startId: Int) {
        AppLog.log("chatgpt", "keep-awake time is up")
        stopSelf()
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        AppLog.log("chatgpt", "keep-awake time is up")
        stopSelf()
    }

    companion object {
        private const val NOTICE_ID = 8
        private const val CHANNEL = "mode.signin"

        /** Starts it while Mode is in front, just before the page opens. */
        fun start(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return
            runCatching { context.startForegroundService(Intent(context, SignInService::class.java)) }
                .onFailure { AppLog.log("chatgpt", "couldn't keep awake: ${it::class.simpleName}: ${it.message}") }
        }

        fun stop(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return
            runCatching { context.stopService(Intent(context, SignInService::class.java)) }
        }

        private fun notice(context: Context): Notification {
            val manager = context.getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL, context.getString(R.string.chatgpt_signin_channel), NotificationManager.IMPORTANCE_LOW),
            )
            val open = PendingIntent.getActivity(
                context, 0, Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            return Notification.Builder(context, CHANNEL)
                .setSmallIcon(R.drawable.ic_mode_notification)
                .setContentTitle(context.getString(R.string.chatgpt_waiting))
                .setContentText(context.getString(R.string.chatgpt_waiting_hint))
                .setContentIntent(open)
                .setOngoing(true)
                .build()
        }
    }
}
