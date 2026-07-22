import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing is resolved at build time from, in order of preference:
//   1. CI-injected env vars (Codemagic sets CM_KEYSTORE_PATH / CM_KEY_ALIAS /
//      CM_KEYSTORE_PASSWORD / CM_KEY_PASSWORD).
//   2. A local android/key.properties file (gitignored — see key.properties.example).
// If neither is present the release build falls back to the debug key so
// `flutter run --release` still works during development. No secret is ever
// committed to the repo.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

val ciKeystorePath: String? = System.getenv("CM_KEYSTORE_PATH")
val releaseStorePath: String? = ciKeystorePath ?: keystoreProperties.getProperty("storeFile")
val hasReleaseSigning = releaseStorePath != null

android {
    namespace = "com.okaymessaging"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.okaymessaging"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // flutter_webrtc requires Android 6.0 (API 23) or newer.
        minSdk = maxOf(23, flutter.minSdkVersion)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = releaseStorePath?.let { file(it) }
                storePassword = System.getenv("CM_KEYSTORE_PASSWORD")
                    ?: keystoreProperties.getProperty("storePassword")
                keyAlias = System.getenv("CM_KEY_ALIAS")
                    ?: keystoreProperties.getProperty("keyAlias")
                keyPassword = System.getenv("CM_KEY_PASSWORD")
                    ?: keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // Use the real upload key when one is available (CI or key.properties),
            // otherwise sign with the debug key so `flutter run --release` works.
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
