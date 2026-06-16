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

