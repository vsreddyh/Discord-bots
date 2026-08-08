package com.vishnu.healthgateway

import android.content.Context
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import java.util.concurrent.atomic.AtomicBoolean

object SyncRunner {
    private const val TAG = "SyncRunner"
    private val inFlight = AtomicBoolean(false)

    suspend fun run(context: Context): SyncResult {
        if (!inFlight.compareAndSet(false, true)) {
            return SyncResult(false, null, "sync already in progress")
        }
        return try {
            val manager = HealthConnectManager(context)
            val granted = manager.grantedPermissions()
            if (granted.intersect(HealthConnectManager.PERMISSIONS).isEmpty()) {
                SyncResult(false, null, "Health Connect permissions not granted")
            } else {
                val payload = manager.collectToday()
                SyncClient(context).post(payload)
            }
        } catch (e: Exception) {
            Log.e(TAG, "sync failed", e)
            SyncResult(false, null, e.message ?: e.javaClass.simpleName)
        } finally {
            inFlight.set(false)
        }
    }

    fun runAsync(context: Context, onDone: (SyncResult) -> Unit = {}) {
        CoroutineScope(Dispatchers.IO).launch {
            onDone(run(context))
        }
    }
}
