import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.juanchosky.bumpcomba"
    compileSdk = 36
    buildToolsVersion = "35.0.0"
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    aaptOptions {
        noCompress += listOf("tflite", "lite")
    }

    defaultConfig {
        applicationId = "com.juanchosky.bumpcomba"
        minSdk = flutter.minSdkVersion
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        
        ndk {
            abiFilters += listOf("arm64-v8a", "armeabi-v7a", "x86_64")
        }
    }

    val keystoreProperties = Properties()
    val keystorePropertiesFile = rootProject.file("key.properties")
    if (keystorePropertiesFile.exists()) {
        keystoreProperties.load(FileInputStream(keystorePropertiesFile))
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            proguardFiles(getDefaultProguardFile("proguard-android.txt"), "proguard-rules.pro")
            if (keystorePropertiesFile.exists()) {
                signingConfig = signingConfigs.getByName("release")
            } else {
                signingConfig = signingConfigs.getByName("debug")
            }
        }
    }

    lint {
        disable += "NullSafeMutableLiveData"
        checkReleaseBuilds = false
        abortOnError = false
    }
}

configurations.all {
    resolutionStrategy.eachDependency {
        if (requested.group == "androidx.appcompat") {
            useVersion("1.7.0")
            because("Use 1.7.0 with system color attribute workaround")
        }
        if (requested.group == "androidx.core" && (requested.name == "core" || requested.name == "core-ktx")) {
            useVersion("1.15.0")
            because("AGP 8.7.0 is incompatible with 1.17.0+")
        }
        if (requested.group == "androidx.browser" && requested.name == "browser") {
            useVersion("1.8.0")
            because("AGP 8.7.0 is incompatible with 1.9.0+")
        }
    }
}

dependencies {
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("androidx.activity:activity-ktx:1.9.0")
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

flutter {
    source = "../.."
}
