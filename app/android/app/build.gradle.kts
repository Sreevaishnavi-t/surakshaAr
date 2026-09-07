plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "org.suraksha.surakshaar"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // ML Kit's barcode scanner pulls in APIs that need desugaring on minSdk 29.
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        applicationId = "org.suraksha.surakshaar"
        // Android 10. Set by the problem statement, and it is also the floor at which
        // GAME_ROTATION_VECTOR is dependably present on budget hardware.
        minSdk = 29
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // Demo builds are signed with the debug key so `flutter run --release` and
            // sideloading both work. A real deployment needs its own upload key; see
            // docs/threat-model.md.
            signingConfig = signingConfigs.getByName("debug")
            // Minification is off while a device-specific crash is being
            // isolated. R8 strips reflectively-reached classes (CameraX in
            // particular relies on them heavily), which produces release-only
            // failures that never appear in debug. Re-enable with verified keep
            // rules once the crash is confirmed fixed.
            isMinifyEnabled = false
            isShrinkResources = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    packaging {
        resources {
            excludes += setOf("META-INF/DEPENDENCIES", "META-INF/LICENSE*", "META-INF/NOTICE*")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
}

flutter {
    source = "../.."
}
