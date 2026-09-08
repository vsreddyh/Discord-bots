package com.vishnu.healthgateway

import android.app.Application
import androidx.compose.runtime.State
import androidx.compose.runtime.mutableStateOf
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

data class ChatUiState(
    val model: String = "",
    val messages: List<ChatMessage> = emptyList(),
    val streaming: Boolean = false,
    val pending: String = "",
    val error: String = "",
)

/**
 * One instance per chat tab (story / resumes / god). Holds the tab's
 * conversation in memory; the full history is sent with each request.
 */
class ChatViewModel(app: Application, val tab: String) : AndroidViewModel(app) {

    private val api = ChatApi(app)

    private val _state = mutableStateOf(ChatUiState(model = api.modelFor(tab)))
    val state: State<ChatUiState> = _state

    private var streamJob: Job? = null

    fun refreshModel() {
        _state.value = _state.value.copy(model = api.modelFor(tab))
    }

    fun onPending(v: String) {
        _state.value = _state.value.copy(pending = v)
    }

    fun newConversation() {
        streamJob?.cancel()
        streamJob = null
        _state.value = _state.value.copy(messages = emptyList(), error = "", streaming = false)
    }

    fun stop() {
        streamJob?.cancel()
        streamJob = null
        _state.value = _state.value.copy(streaming = false)
    }

    fun send() {
        val text = _state.value.pending.trim()
        if (text.isEmpty() || _state.value.streaming) return
        val model = api.modelFor(tab)
        val history = _state.value.messages + ChatMessage("user", text)
        _state.value = _state.value.copy(messages = history, pending = "", streaming = true, error = "")
        // Placeholder assistant message that deltas append to.
        _state.value = _state.value.copy(messages = history + ChatMessage("assistant", ""))
        val acc = StringBuilder()
        streamJob?.cancel()
        streamJob = viewModelScope.launch {
            api.streamChat(model, history).collect { event ->
                when (event) {
                    is ChatEvent.Delta -> {
                        acc.append(event.text)
                        val msgs = _state.value.messages
                        _state.value = _state.value.copy(
                            messages = msgs.dropLast(1) + ChatMessage("assistant", acc.toString()),
                        )
                    }
                    is ChatEvent.Done -> {
                        val final = event.fullText.ifEmpty { acc.toString() }
                        val msgs = _state.value.messages
                        _state.value = _state.value.copy(
                            messages = msgs.dropLast(1) + ChatMessage("assistant", final.ifEmpty { "(empty reply)" }),
                            streaming = false,
                        )
                    }
                    is ChatEvent.Error -> {
                        // Drop the empty placeholder on failure.
                        val msgs = _state.value.messages.dropLast(1)
                        _state.value = _state.value.copy(messages = msgs, streaming = false, error = event.message)
                    }
                }
            }
        }
    }
}
