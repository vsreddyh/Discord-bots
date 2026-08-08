package com.vishnu.healthgateway

import kotlinx.serialization.Serializable

@Serializable
data class HealthSyncPayload(
    val device: String = "Redmi Watch 5 Lite",
    val syncedAtIso: String,
    val steps: Long? = null,
    val activeCaloriesKcal: Double? = null,
    val sleep: List<SleepEntry> = emptyList(),
    val workouts: List<WorkoutEntry> = emptyList(),
)

@Serializable
data class SleepEntry(
    val startIso: String,
    val endIso: String,
    val totalMinutes: Long,
    val stages: Map<String, Long> = emptyMap(),
)

@Serializable
data class WorkoutEntry(
    val startIso: String,
    val endIso: String,
    val title: String,
    val type: String,
    val distanceMeters: Double? = null,
    val caloriesKcal: Double? = null,
)

@Serializable
data class SyncResult(
    val success: Boolean,
    val statusCode: Int? = null,
    val message: String = "",
)
