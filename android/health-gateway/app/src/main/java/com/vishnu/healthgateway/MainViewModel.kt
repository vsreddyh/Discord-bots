package com.vishnu.healthgateway

import android.app.Application
import androidx.compose.runtime.State
import androidx.compose.runtime.mutableStateOf
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.launch

data class UiState(
    val serverUrl: String = "",
    val authToken: String = "",
    val healthAvailable: Boolean = false,
    val healthUpdateRequired: Boolean = false,
    val healthPackageInfo: String = "",
    val permissionsGranted: Boolean = false,
    val syncing: Boolean = false,
    val lastResult: String = "",
    val lastSyncAt: String = "",
)

class MainViewModel(app: Application) : AndroidViewModel(app) {

    private val client = SyncClient(app)

    private val _state = mutableStateOf(UiState())
    val state: State<UiState> = _state

    init {
        refresh()
    }

    fun refresh() {
        val prefs = getApplication<Application>().getSharedPreferences("health_gateway", android.content.Context.MODE_PRIVATE)
        _state.value = _state.value.copy(
            serverUrl = prefs.getString("server_url", "") ?: "",
            authToken = prefs.getString("auth_token", "") ?: "",
            lastSyncAt = prefs.getString("last_sync_at", "") ?: "",
        )
        val availability = HealthConnectManager.availabilityStatus(getApplication())
        _state.value = _state.value.copy(
            healthAvailable = availability == HealthConnectAvailability.AVAILABLE,
            healthUpdateRequired = availability == HealthConnectAvailability.UPDATE_REQUIRED,
            healthPackageInfo = HealthConnectManager.healthConnectPackageInfo(getApplication()),
        )
        viewModelScope.launch {
            val granted = try {
                HealthConnectManager(getApplication()).grantedPermissions()
            } catch (e: Exception) {
                emptySet()
            }
            _state.value = _state.value.copy(
                permissionsGranted = granted.intersect(HealthConnectManager.PERMISSIONS).isNotEmpty(),
            )
        }
    }

    fun onServerUrl(v: String) {
        _state.value = _state.value.copy(serverUrl = v)
    }

    fun onAuthToken(v: String) {
        _state.value = _state.value.copy(authToken = v)
    }

    fun onSyncError(message: String) {
        _state.value = _state.value.copy(lastResult = "FAILED — $message")
    }

    fun saveConfig() {
        client.setConfig(_state.value.serverUrl, _state.value.authToken)
        refresh()
    }

    fun syncNow() {
        if (_state.value.syncing) return
        _state.value = _state.value.copy(syncing = true, lastResult = "syncing…")
        val app = getApplication<Application>()
        SyncRunner.runAsync(app) { result ->
            val prefs = app.getSharedPreferences("health_gateway", android.content.Context.MODE_PRIVATE)
            if (result.success) {
                prefs.edit().putString("last_sync_at", java.time.Instant.now().toString()).apply()
            }
            _state.value = _state.value.copy(
                syncing = false,
                lastResult = if (result.success) {
                    "OK (${result.statusCode}) — ${result.message.take(80)}"
                } else {
                    "FAILED — ${result.message}"
                },
            )
            refresh()
        }
    }
}
