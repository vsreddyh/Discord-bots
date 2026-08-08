# kotlinx.serialization — keep serializer classes for @Serializable models
-keepattributes *Annotation*, InnerClasses
-dontnote kotlinx.serialization.AnnotationsKt
-keepclassmembers class com.vishnu.healthgateway.** {
    *** Companion;
}
-keepclasseswithmembers class com.vishnu.healthgateway.** {
    kotlinx.serialization.KSerializer serializer(...);
}
-keep,includedescriptorclasses class com.vishnu.healthgateway.**$$serializer { *; }
-keepclassmembers class com.vishnu.healthgateway.** {
    *** INSTANCE;
    kotlinx.serialization.KSerializer serializer(...);
}
-keep,includedescriptorclasses class com.vishnu.healthgateway.HealthSyncPayload,
    com.vishnu.healthgateway.SleepEntry,
    com.vishnu.healthgateway.WorkoutEntry,
    com.vishnu.healthgateway.SyncResult { *; }

# Health Connect client uses reflection on records
-keep class androidx.health.connect.client.records.** { *; }
-dontwarn androidx.health.connect.client.**

# WorkManager — entry points loaded via Class.forName
-keep class * extends androidx.work.Worker { <init>(android.content.Context, androidx.work.WorkerParameters); }
-keep class * extends androidx.work.ListenableWorker { <init>(android.content.Context, androidx.work.WorkerParameters); }
-dontwarn androidx.work.**

# OkHttp
-dontwarn okhttp3.**
-dontwarn okio.**
-dontwarn org.conscrypt.**
-dontwarn org.bouncycastle.**
-dontwarn org.openjsse.**

# Coroutines
-dontwarn kotlinx.coroutines.**
