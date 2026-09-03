// FF001-2: standalone verification build for the plugin Android module.
//
// `gradlew :assembleDebug :testDebugUnitTest` from this directory compiles
// the plugin + runs JVM unit tests WITHOUT a Flutter host app (the android/
// dir itself is the plugin module in Flutter's federated layout — in a host
// app it is included as a subproject; here the root project plays that role).
// io.flutter embedding artifacts are fetched into libs/ by
// ../tool/fetch_flutter_artifacts.sh (jar fallback: libs/flutter-*.jar).
pluginManagement {
    repositories {
        mavenCentral()
        gradlePluginPortal()
        google()
    }
}

plugins {
    id("com.android.library") version "8.11.1" apply false
    id("org.jetbrains.kotlin.android") version "2.0.21" apply false
}

rootProject.name = "flutter_debug_control_plane_android"

// Kotlin core as a composite build — substitutes the
// com.pantas.debug.controlplane:core coordinate with locally built outputs
// (path-first, no JitPack release yet).
