# Suppress warnings for missing AutoValue classes caused by OpenTelemetry
-dontwarn com.google.auto.value.**
-dontwarn io.grpc.**
-dontwarn org.osgi.**
-dontwarn io.opentelemetry.**

# Optionally keep OpenTelemetry just in case, though the above is usually enough
-keep class io.opentelemetry.** { *; }
