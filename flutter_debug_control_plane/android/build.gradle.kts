// FF001-2: Android Flutter plugin module (AGP library).
//
// Depends on the Kotlin core via composite build (includeBuild ../../kotlin)
// - local example builds may substitute the JitPack coordinate with sources.
// Zero business deps beyond io.flutter embedding + the Kotlin core.
group = "com.pantas.debug.controlplane.flutter"
version = "0.4.0"

plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

allprojects {
    repositories {
            maven { url = uri("https://jitpack.io") }
        google()
        mavenCentral()
    }
}

val flutterDebugJar = projectDir.resolve("libs/flutter-debug.jar")
val flutterProfileJar = projectDir.resolve("libs/flutter-profile.jar")
val flutterReleaseJar = projectDir.resolve("libs/flutter-release.jar")

android {
    namespace = "com.pantas.debug.controlplane.flutter"
    compileSdk = 35

    defaultConfig {
        minSdk = 21
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    sourceSets["main"].java.srcDirs("src/main/kotlin")
    sourceSets["test"].java.srcDirs("src/test/kotlin")

    testOptions {
        unitTests.isReturnDefaultValues = true
    }
}

// AGP 9 host apps compile this script with KGP 2.1+, where the old
// android.kotlinOptions DSL is a script-compilation ERROR — set the JVM
// target via the Kotlin extension instead (works on KGP 2.0+).
kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

dependencies {
    // io.flutter is allowed (the plugin itself needs it).
    // Newer Flutter SDKs (3.44+) dropped the per-abi embedding AARs from the
    // artifact cache and ship a unified `flutter.jar` per build mode instead —
    // fetched into libs/ by ./tool/fetch_flutter_artifacts.sh (jar fallback).
    if (flutterDebugJar.exists()) {
        compileOnly(files(flutterDebugJar))
    }

    // Kotlin core. Local development/test hosts may substitute this JitPack
    // coordinate with the sibling kotlin project via includeBuild.
    implementation("com.github.xiaolutang:debug_control_plane:0.4.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.9.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.9.0")
    // org.json: bundled on Android; explicit for pure JVM tests (the Kotlin
    // core parses POST bodies with it, so RouteContext.body can carry
    // JSONObject/JSONArray — R026 e2e defect #2).
    testImplementation("org.json:json:20240303")
    testImplementation(files(flutterDebugJar))
}
