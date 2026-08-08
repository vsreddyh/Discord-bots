package com.vishnu.healthgateway

import android.content.Context
import android.util.Log
import androidx.work.CoroutineWorker
import androidx.work.ForegroundInfo
import androidx.work.WorkerParameters

class SyncWorker(
    context: Context,
    params: WorkerParameters,
) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        setForeground(SyncNotifications.foregroundInfo(applicationContext))
        val ok = SyncRunner.run(applicationContext).success
        return if (ok) Result.success() else Result.retry()
    }
}
