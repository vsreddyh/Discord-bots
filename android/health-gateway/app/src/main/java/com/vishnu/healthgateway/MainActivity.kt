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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.health.connect.client.PermissionController
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewmodel.compose.viewModel
import kotlinx.coroutines.launch

class ChatViewModelFactory(
    private val app: android.app.Application,
    private val tab: String,
) : ViewModelProvider.Factory {
    @Suppress("UNCHECKED_CAST")
    override fun <T : ViewModel> create(modelClass: Class<T>): T {
        return ChatViewModel(app, tab) as T
    }
}

private enum class Destination(val title: String) {
    Story("Story"),
    Resumes("Resumes"),
    God("God"),
    Settings("Settings"),
}

class MainActivity : ComponentActivity() {

    private val healthModel: MainViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme {
                var dest by remember { mutableStateOf(Destination.Story) }
                Scaffold(
                    bottomBar = {
                        NavigationBar {
                            Destination.entries.forEach { d ->
                                NavigationBarItem(
                                    selected = dest == d,
                                    onClick = { dest = d },
                                    label = { Text(d.title) },
                                    icon = {},
                                )
                            }
                        }
                    },
                ) { padding ->
                    Box(modifier = Modifier.padding(padding)) {
                        when (dest) {
                            Destination.Story -> ChatTab(app = application, tab = "story", title = "Story")
                            Destination.Resumes -> ChatTab(app = application, tab = "resumes", title = "Resumes")
                            Destination.God -> ChatTab(app = application, tab = "god", title = "God")
                            Destination.Settings -> SettingsScreen(healthModel)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun ChatTab(app: android.app.Application, tab: String, title: String) {
    val factory = remember(tab) { ChatViewModelFactory(app, tab) }
    // Keyed per tab — otherwise all three tabs would share one ViewModel.
    val vm: ChatViewModel = viewModel(key = "chat_$tab", factory = factory)
    val state by vm.state
    LaunchedEffect(Unit) { vm.refreshModel() }
    ChatScreen(title = title, model = state.model.ifEmpty { defaultModel(tab) }, state = state,
        onPending = vm::onPending, onSend = vm::send, onStop = vm::stop, onNew = vm::newConversation)
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ChatScreen(
    title: String,
    model: String,
    state: ChatUiState,
    onPending: (String) -> Unit,
    onSend: () -> Unit,
    onStop: () -> Unit,
    onNew: () -> Unit,
) {
    val listState = rememberLazyListState()
    LaunchedEffect(state.messages.size, state.messages.lastOrNull()?.content?.length) {
        if (state.messages.isNotEmpty()) listState.animateScrollToItem(state.messages.size - 1)
    }
    Column(modifier = Modifier.fillMaxSize()) {
        TopAppBar(
            title = { Text("$title · $model") },
            actions = {
                TextButton(onClick = onNew, enabled = !state.streaming) { Text("New") }
            },
        )
        if (state.error.isNotEmpty()) {
            Text(
                state.error,
                color = MaterialTheme.colorScheme.error,
                style = MaterialTheme.typography.bodySmall,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
            )
        }
        LazyColumn(
            state = listState,
            modifier = Modifier.weight(1f).fillMaxWidth().padding(horizontal = 12.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
            contentPadding = PaddingValues(vertical = 8.dp),
        ) {
            if (state.messages.isEmpty()) {
                item {
                    Text(
                        "No messages yet. Ask anything — history stays in this tab until New.",
                        style = MaterialTheme.typography.bodyMedium,
                    )
                }
            }
            items(state.messages) { msg ->
                Card(
                    modifier = Modifier.fillMaxWidth(),
                    colors = if (msg.role == "user") {
                        CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.primaryContainer)
                    } else {
                        CardDefaults.cardColors()
                    },
                ) {
                    Text(
                        msg.content.ifEmpty { "…" },
                        modifier = Modifier.padding(12.dp),
                        style = MaterialTheme.typography.bodyMedium,
                    )
                }
            }
        }
        Row(
            modifier = Modifier.fillMaxWidth().padding(12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            OutlinedTextField(
                value = state.pending,
                onValueChange = onPending,
                label = { Text("Message") },
                modifier = Modifier.weight(1f),
                maxLines = 4,
            )
            Spacer(modifier = Modifier.width(8.dp))
            if (state.streaming) {
                Button(onClick = onStop) { Text("Stop") }
            } else {
                Button(onClick = onSend, enabled = state.pending.isNotBlank()) { Text("Send") }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(viewModel: MainViewModel) {
    val state by viewModel.state
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    var apiBase by remember { mutableStateOf("") }
    var apiKey by remember { mutableStateOf("") }
    var modelStory by remember { mutableStateOf("") }
    var modelResumes by remember { mutableStateOf("") }
    var modelGod by remember { mutableStateOf("") }
    var modelsResult by remember { mutableStateOf("") }

    LaunchedEffect(Unit) {
        val prefs = context.getSharedPreferences("health_gateway", android.content.Context.MODE_PRIVATE)
        // serverUrl/authToken fields below are the health-sync ones (unchanged keys).
        apiBase = prefs.getString("api_base_url", "") ?: ""
        apiKey = prefs.getString("api_key", "") ?: ""
        modelStory = prefs.getString("model_story", "") ?: ""
        modelResumes = prefs.getString("model_resumes", "") ?: ""
        modelGod = prefs.getString("model_god", "") ?: ""
    }

    val hcPermissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) {
        viewModel.refresh()
    }

    val hcRequest = rememberLauncherForActivityResult(
        PermissionController.createRequestPermissionResultContract()
    ) {
        viewModel.refresh()
        if (!viewModel.state.value.permissionsGranted) {
            viewModel.onSyncError("Still not granted — open the Health Connect app manually")
        }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text("Settings", style = MaterialTheme.typography.headlineMedium)

        Text("Chat backend", style = MaterialTheme.typography.titleMedium)
        OutlinedTextField(
            value = apiBase,
            onValueChange = { apiBase = it },
            label = { Text("API base URL") },
            placeholder = { Text("http://192.168.1.10:8642") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
        OutlinedTextField(
            value = apiKey,
            onValueChange = { apiKey = it },
            label = { Text("API key (shared)") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
        OutlinedTextField(
            value = modelStory,
            onValueChange = { modelStory = it },
            label = { Text("Story model") },
            placeholder = { Text("story") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
        OutlinedTextField(
            value = modelResumes,
            onValueChange = { modelResumes = it },
            label = { Text("Resumes model") },
            placeholder = { Text("resumes") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
        OutlinedTextField(
            value = modelGod,
            onValueChange = { modelGod = it },
            label = { Text("God model") },
            placeholder = { Text("default") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Button(onClick = {
                ChatApi(context).setChatConfig(apiBase, apiKey, modelStory, modelResumes, modelGod)
                modelsResult = "Saved."
            }, modifier = Modifier.weight(1f)) {
                Text("Save chat config")
            }
            OutlinedButton(onClick = {
                ChatApi(context).setChatConfig(apiBase, apiKey, modelStory, modelResumes, modelGod)
                modelsResult = "Checking…"
                scope.launch {
                    val r = ChatApi(context).listModels()
                    modelsResult = r.fold(
                        onSuccess = { ids -> if (ids.isEmpty()) "No models returned." else "Models: ${ids.joinToString()}" },
                        onFailure = { e -> "FAILED — ${e.message}" },
                    )
                }
            }, modifier = Modifier.weight(1f)) {
                Text("Check models")
            }
        }
        if (modelsResult.isNotEmpty()) {
            Text(modelsResult, style = MaterialTheme.typography.bodySmall)
        }

        Text("Health sync", style = MaterialTheme.typography.titleMedium)
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
                    val mgr = HealthConnectManager(context)
                    val launched = mgr.requestPermissions(hcRequest)
                    if (!launched) {
                        viewModel.onSyncError("Permission screen unavailable — opening Health Connect app")
                        mgr.openHealthConnectSettings(context)
                    }
                }) {
                    Text("Grant Health Connect permissions")
                }
                OutlinedButton(onClick = {
                    viewModel.onSyncError("Open Health Connect → Permissions → Health Gateway → allow each")
                    HealthConnectManager(context).openHealthConnectSettings(context)
                }) {
                    Text("Open Health Connect app")
                }
                OutlinedButton(onClick = {
                    val intent = android.content.Intent(
                        android.content.Intent.ACTION_VIEW,
                        android.net.Uri.parse(HealthConnectManager.playStoreUrl()),
                    )
                    runCatching { context.startActivity(intent) }
                }) {
                    Text("Install / Update Health Connect (Play Store)")
                }
                if (state.healthPackageInfo.isNotEmpty()) {
                    Text(
                        "HC package: ${state.healthPackageInfo}",
                        style = MaterialTheme.typography.bodySmall,
                    )
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
            label = { Text("Sync server URL") },
            placeholder = { Text("http://192.168.1.10:8001") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
        OutlinedTextField(
            value = state.authToken,
            onValueChange = viewModel::onAuthToken,
            label = { Text("Sync auth token") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
        Button(onClick = viewModel::saveConfig, modifier = Modifier.fillMaxWidth()) {
            Text("Save sync config")
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
