package com.vishnu.healthgateway

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.work.ForegroundInfo

object SyncNotifications {
    private const val TAG = "SyncNotifications"
    private const val CHANNEL_ID = "health_sync"
    private const val NOTIFICATION_ID = 4242

    fun ensureChannel(context: Context) {
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (nm.getNotificationChannel(CHANNEL_ID) == null) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                context.getString(R.string.channel_name),
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = context.getString(R.string.channel_desc)
            }
            nm.createNotificationChannel(channel)
        }
    }

    fun foregroundInfo(context: Context): ForegroundInfo {
        ensureChannel(context)
        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setContentTitle(context.getString(R.string.sync_notif_title))
            .setContentText(context.getString(R.string.sync_notif_text))
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
        return ForegroundInfo(NOTIFICATION_ID, notification)
    }
}
