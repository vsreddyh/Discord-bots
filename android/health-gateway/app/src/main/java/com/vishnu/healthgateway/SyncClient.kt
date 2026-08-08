package com.vishnu.healthgateway

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import java.util.concurrent.TimeUnit

class SyncClient(context: Context) {

    private val prefs = context.getSharedPreferences("health_gateway", Context.MODE_PRIVATE)
    private val http = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .writeTimeout(30, TimeUnit.SECONDS)
        .build()

    companion object {
        private const val TAG = "SyncClient"
        private val JSON = "application/json; charset=utf-8".toMediaType()
    }

    fun serverUrl(): String = prefs.getString("server_url", "") ?: ""
    fun authToken(): String = prefs.getString("auth_token", "") ?: ""

    fun setConfig(serverUrl: String, authToken: String) {
        prefs.edit()
            .putString("server_url", serverUrl.trimEnd('/'))
            .putString("auth_token", authToken.trim())
            .apply()
    }

    suspend fun post(payload: HealthSyncPayload): SyncResult = withContext(Dispatchers.IO) {
        val url = serverUrl()
        if (url.isEmpty()) return@withContext SyncResult(false, null, "server URL not configured")

        val json = Json { ignoreUnknownKeys = true }.encodeToString(payload)
        val request = Request.Builder()
            .url("$url/api/health/sync")
            .header("Authorization", "Bearer ${authToken()}")
            .header("Content-Type", "application/json")
            .post(json.toRequestBody(JSON))
            .build()

        try {
            http.newCall(request).execute().use { response ->
                SyncResult(
                    success = response.isSuccessful,
                    statusCode = response.code,
                    message = response.body?.string()?.take(500) ?: "",
                )
            }
        } catch (e: Exception) {
            SyncResult(false, null, e.message ?: e.javaClass.simpleName)
        }
    }
}
