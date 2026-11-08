pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
        // swift-java's SwiftKitCore, published from swift-java's checkout and not to Maven Central (README.md).
        mavenLocal()
    }
}

rootProject.name = "recbridge-android"
include(":app", ":core")
