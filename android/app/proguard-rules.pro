# Suppress warnings for missing AutoValue classes caused by OpenTelemetry
-dontwarn com.google.auto.value.**
-dontwarn io.grpc.**
-dontwarn org.osgi.**
-dontwarn io.opentelemetry.**

# Optionally keep OpenTelemetry just in case, though the above is usually enough
-keep class io.opentelemetry.** { *; }

# OneSignal rules
-keep class com.onesignal.** { *; }
-keep interface com.onesignal.** { *; }
-dontwarn com.onesignal.**

# Google Play Billing rules (just in case they are stripped and cause OneSignal to NPE)
-keep class com.android.billingclient.** { *; }
-dontwarn com.android.billingclient.**

# RevenueCat / purchases_flutter rules
-keep class com.revenuecat.purchases.** { *; }
-dontwarn com.revenuecat.purchases.**

# flutter_local_notifications: las notificaciones programadas se serializan con
# GSON y se deserializan en el ScheduledNotificationReceiver. Sin estas reglas,
# R8 elimina los genéricos de TypeToken y la deserialización falla en release
# (la notificación programada nunca se muestra).
-keep class com.dexterous.** { *; }
-keepattributes Signature
-keepattributes *Annotation*
-keep class com.google.gson.reflect.TypeToken { *; }
-keep class * extends com.google.gson.reflect.TypeToken
-keep public class * implements java.lang.reflect.Type

