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
                val client = SyncClient(context)
                val prefs = context.getSharedPreferences(
                    "health_gateway", Context.MODE_PRIVATE,
                )
                val firstSyncDone = prefs.getBoolean("first_sync_done", false)
                if (!firstSyncDone) {
                    backfill(client, manager)
                } else {
                    client.post(manager.collectToday())
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "sync failed", e)
            SyncResult(false, null, e.message ?: e.javaClass.simpleName)
        } finally {
            inFlight.set(false)
        }
    }

    private suspend fun backfill(client: SyncClient, manager: HealthConnectManager): SyncResult {
        val payloads = manager.collectBackfill()
        if (payloads.isEmpty()) {
            return SyncResult(false, null, "no health data to backfill")
        }
        var last: SyncResult = SyncResult(true, null, "")
        for (p in payloads) {
            last = client.post(p)
            if (!last.success) return last
        }
        client.markFirstSyncDone()
        return last
    }

    fun runAsync(context: Context, onDone: (SyncResult) -> Unit = {}) {
        CoroutineScope(Dispatchers.IO).launch {
            onDone(run(context))
        }
    }
}
