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

    buildTypes {
        release {
            isMinifyEnabled = false
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
