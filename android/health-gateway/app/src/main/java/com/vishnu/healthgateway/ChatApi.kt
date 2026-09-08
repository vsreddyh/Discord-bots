package com.vishnu.healthgateway

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.TimeUnit

data class ChatMessage(
    val role: String, // "user" | "assistant"
    val content: String,
)

sealed interface ChatEvent {
    data class Delta(val text: String) : ChatEvent
    data class Done(val fullText: String) : ChatEvent
    data class Error(val message: String) : ChatEvent
}

/**
 * Minimal OpenAI-compatible chat client for the Hermes API server
 * (gateway :8642). One base URL + shared bearer key; each tab sends
 * its profile's model name. Streaming via SSE.
 */
class ChatApi(context: Context) {

    private val prefs = context.getSharedPreferences("health_gateway", Context.MODE_PRIVATE)
    private val http = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.SECONDS) // streaming: no read timeout
        .writeTimeout(30, TimeUnit.SECONDS)
        .build()

    companion object {
        private val JSON = "application/json; charset=utf-8".toMediaType()
    }

    fun baseUrl(): String = prefs.getString("api_base_url", "") ?: ""
    fun apiKey(): String = prefs.getString("api_key", "") ?: ""
    fun modelFor(tab: String): String =
        prefs.getString("model_$tab", "")?.ifEmpty { null } ?: defaultModel(tab)

    fun setChatConfig(baseUrl: String, apiKey: String, modelStory: String, modelResumes: String, modelGod: String) {
        prefs.edit()
            .putString("api_base_url", baseUrl.trimEnd('/'))
            .putString("api_key", apiKey.trim())
            .putString("model_story", modelStory.trim())
            .putString("model_resumes", modelResumes.trim())
            .putString("model_god", modelGod.trim())
            .apply()
    }

    suspend fun listModels(): Result<List<String>> = withContext(Dispatchers.IO) {
        val base = baseUrl()
        if (base.isEmpty()) return@withContext Result.failure(IllegalStateException("API base URL not configured"))
        val request = Request.Builder()
            .url("$base/v1/models")
            .header("Authorization", "Bearer ${apiKey()}")
            .get()
            .build()
        try {
            http.newCall(request).execute().use { response ->
                val body = response.body?.string() ?: ""
                if (!response.isSuccessful) return@withContext Result.failure(RuntimeException("HTTP ${response.code}: ${body.take(200)}"))
                val ids = mutableListOf<String>()
                val data = JSONObject(body).optJSONArray("data")
                if (data != null) {
                    for (i in 0 until data.length()) {
                        data.optJSONObject(i)?.optString("id")?.takeIf { it.isNotEmpty() }?.let { ids.add(it) }
                    }
                }
                Result.success(ids)
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    /** Streams reply deltas for [messages]; emits Done(fullText) at `[DONE]`. */
    fun streamChat(model: String, messages: List<ChatMessage>): Flow<ChatEvent> = callbackFlow {
        val base = baseUrl()
        if (base.isEmpty()) {
            trySend(ChatEvent.Error("API base URL not configured — see Settings"))
            close()
            return@callbackFlow
        }
        val payload = JSONObject()
        payload.put("model", model)
        val arr = JSONArray()
        for (m in messages) {
            arr.put(JSONObject().put("role", m.role).put("content", m.content))
        }
        payload.put("messages", arr)
        payload.put("stream", true)
        val body = payload.toString().toRequestBody(JSON)
        val request = Request.Builder()
            .url("$base/v1/chat/completions")
            .header("Authorization", "Bearer ${apiKey()}")
            .header("Content-Type", "application/json")
            .header("Accept", "text/event-stream")
            .post(body)
            .build()
        val call = http.newCall(request)
        val job = launch(Dispatchers.IO) {
            try {
                call.execute().use { response ->
                    if (!response.isSuccessful) {
                        val err = response.body?.string()?.take(300) ?: ""
                        trySend(ChatEvent.Error("HTTP ${response.code}: $err"))
                        return@launch
                    }
                    val source = response.body?.source()
                    if (source == null) {
                        trySend(ChatEvent.Error("empty response body"))
                        return@launch
                    }
                    val full = StringBuilder()
                    // OkHttp in this project has no sse module; parse SSE lines manually.
                    while (!source.exhausted()) {
                        val line = source.readUtf8Line() ?: break
                        if (!line.startsWith("data:")) continue
                        val data = line.removePrefix("data:").trim()
                        if (data.isEmpty()) continue
                        if (data == "[DONE]") break
                        val delta = runCatching {
                            val choices = JSONObject(data).optJSONArray("choices") ?: return@runCatching ""
                            val choice = choices.optJSONObject(0) ?: return@runCatching ""
                            // chat completions: choices[0].delta.content;
                            // responses API: choices[0].message.content (fallback)
                            choice.optJSONObject("delta")?.optString("content")
                                ?: choice.optJSONObject("message")?.optString("content")
                                ?: ""
                        }.getOrDefault("")
                        if (delta.isNotEmpty()) {
                            full.append(delta)
                            trySend(ChatEvent.Delta(delta))
                        }
                    }
                    trySend(ChatEvent.Done(full.toString()))
                }
            } catch (e: Exception) {
                trySend(ChatEvent.Error(e.message ?: e.javaClass.simpleName))
            } finally {
                close()
            }
        }
        awaitClose {
            job.cancel()
            call.cancel()
        }
    }
}

fun defaultModel(tab: String): String = when (tab) {
    "story" -> "story"
    "resumes" -> "resumes"
    else -> "default"
}
