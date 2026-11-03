import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "jp.hiroaki.bdbridge.helper"
    compileSdk = 34

    defaultConfig {
        applicationId = "jp.hiroaki.bdbridge.helper"
        minSdk = 28
        targetSdk = 33
        versionCode = 1
        versionName = "0.1.0"
    }

    buildFeatures {
        buildConfig = true
    }

    // The release key lives outside the repository (README.md, リリース): a properties file named by
    // RECBRIDGE_HELPER_KEYS, or ~/.config/recbridge-helper/key.properties, with storeFile, storePassword,
    // keyAlias and keyPassword. Without one the release build comes out unsigned, for anyone to sign with
    // a key of their own.
    val keys = (System.getenv("RECBRIDGE_HELPER_KEYS")
        ?: "${System.getProperty("user.home")}/.config/recbridge-helper/key.properties").let { file(it) }
    if (keys.isFile) {
        val properties = Properties().also { loaded -> keys.inputStream().use(loaded::load) }
        signingConfigs {
            create("release") {
                storeFile = keys.parentFile.resolve(properties.getProperty("storeFile"))
                storePassword = properties.getProperty("storePassword")
                keyAlias = properties.getProperty("keyAlias")
                keyPassword = properties.getProperty("keyPassword")
                enableV2Signing = true
                enableV3Signing = true
            }
        }
    }

    buildTypes {
        release {
            // Not shrunk: the APK is to read as the source does, and there is nothing to shrink away.
            isMinifyEnabled = false
            signingConfig = signingConfigs.findByName("release")
        }
    }

    // One name for the file whatever the version: what the release is published as, so that the address of
    // the latest release (README.md, 入れ方) stays the same from one version to the next.
    applicationVariants.all {
        outputs.all {
            (this as com.android.build.gradle.internal.api.BaseVariantOutputImpl).outputFileName =
                if (buildType.name == "debug") "recbridge-helper-debug.apk" else "recbridge-helper.apk"
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }
}

// No dependencies on purpose: the platform's own HTTP, JSON and content APIs are enough, and a helper
// that a reader can audit in one sitting is part of what it promises (see README.md).
dependencies {
}
