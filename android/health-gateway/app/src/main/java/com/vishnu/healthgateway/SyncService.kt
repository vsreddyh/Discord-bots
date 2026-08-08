package com.vishnu.healthgateway

import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat

class SyncService : Service() {

    override fun onCreate() {
        super.onCreate()
        SyncNotifications.ensureChannel(this)
        startForegroundCompat()
    }

    private fun startForegroundCompat() {
        val info = SyncNotifications.foregroundInfo(this)
        ServiceCompat.startForeground(
            this,
            info.notificationId,
            info.notification,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            } else {
                0
            },
        )
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        SyncRunner.runAsync(this) { result ->
            Log.d("SyncService", "sync done: $result")
        }
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        fun start(context: Context) {
            val intent = Intent(context, SyncService::class.java)
            ContextCompat.startForegroundService(context, intent)
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, SyncService::class.java))
        }
    }
}
