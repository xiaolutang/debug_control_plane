pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.0.1" apply false
    id("org.jetbrains.kotlin.android") version "2.3.20" apply false
}

include(":app")

// Kotlin core as a composite build — mirrors the plugin's standalone
// android/settings.gradle.kts substitution so the example app resolves
// com.github.xiaolutang:debug_control_plane from local sources (the
// published 0.2.0 jar predates the R001/R002 auth API).
includeBuild("../../../kotlin") {
    dependencySubstitution {
        substitute(module("com.pantas.debug.controlplane:core")).using(project(":"))
        substitute(module("com.github.xiaolutang:debug_control_plane")).using(project(":"))
        substitute(module("com.github.xiaolutang.debug_control_plane:kotlin")).using(project(":"))
    }
}
