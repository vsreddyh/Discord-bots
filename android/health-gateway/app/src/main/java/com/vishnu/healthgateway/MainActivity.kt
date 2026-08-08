package com.vishnu.healthgateway

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.health.connect.client.PermissionController
import androidx.health.connect.client.HealthConnectClient

class MainActivity : ComponentActivity() {

    private val viewModel: MainViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme {
                GatewayScreen(viewModel)
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun GatewayScreen(viewModel: MainViewModel) {
    val state by viewModel.state
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    val hcPermissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) {
        viewModel.refresh()
    }

    val hcRequest = rememberLauncherForActivityResult(
        PermissionController.createRequestPermissionResultContract()
    ) {
        viewModel.refresh()
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text("Health Gateway", style = MaterialTheme.typography.headlineMedium)

        HealthStatusCard(state)

        when {
            !state.healthAvailable -> {
                Button(onClick = {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                        ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS)
                        != PackageManager.PERMISSION_GRANTED
                    ) {
                        hcPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
                    }
                    HealthConnectManager(context).openHealthConnectSettings(context)
                }) {
                    Text("Install / Update Health Connect")
                }
            }
            !state.permissionsGranted -> {
                Button(onClick = {
                    HealthConnectManager(context).requestPermissions(hcRequest)
                }) {
                    Text("Grant Health Connect permissions")
                }
            }
            else -> {
                Button(
                    onClick = { viewModel.syncNow() },
                    enabled = !state.syncing,
                ) {
                    Text(if (state.syncing) "Syncing…" else "Sync now")
                }
            }
        }

        OutlinedTextField(
            value = state.serverUrl,
            onValueChange = viewModel::onServerUrl,
            label = { Text("Bot server URL") },
            placeholder = { Text("http://192.168.1.10:8000") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
        OutlinedTextField(
            value = state.authToken,
            onValueChange = viewModel::onAuthToken,
            label = { Text("Auth token") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
        Button(onClick = viewModel::saveConfig, modifier = Modifier.fillMaxWidth()) {
            Text("Save")
        }

        if (state.lastSyncAt.isNotEmpty()) {
            Text("Last sync: ${state.lastSyncAt}", style = MaterialTheme.typography.bodySmall)
        }
        if (state.lastResult.isNotEmpty()) {
            Text(
                state.lastResult,
                style = MaterialTheme.typography.bodyMedium,
                color = if (state.lastResult.startsWith("FAILED")) {
                    MaterialTheme.colorScheme.error
                } else {
                    MaterialTheme.colorScheme.onSurface
                },
            )
        }
    }
}

@Composable
private fun HealthStatusCard(state: UiState) {
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            val healthText = when {
                !state.healthAvailable -> "Health Connect not installed"
                state.healthUpdateRequired -> "Health Connect update required"
                else -> "Health Connect ready"
            }
            val permText = if (state.permissionsGranted) {
                "Permissions granted"
            } else {
                "Permissions not granted"
            }
            Text(healthText, style = MaterialTheme.typography.bodyLarge)
            Text(permText, style = MaterialTheme.typography.bodyMedium)
        }
    }
}
