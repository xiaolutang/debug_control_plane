// FF001-2: Android Flutter plugin module (AGP library).
//
// Depends on the Kotlin core via composite build (includeBuild ../../kotlin)
// — path-first, no JitPack release yet (tasks.md C-class decision).
// Zero business deps beyond io.flutter embedding + the Kotlin core.
group = "com.pantas.debug.controlplane.flutter"
version = "0.0.1"

plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

allprojects {
    repositories {
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
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    sourceSets["main"].java.srcDirs("src/main/kotlin")
    sourceSets["test"].java.srcDirs("src/test/kotlin")

    testOptions {
        unitTests.isReturnDefaultValues = true
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

    // Kotlin core (composite build: settings includeBuild ../../kotlin).
    implementation("com.pantas.debug.controlplane:core")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.9.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.9.0")
    testImplementation(files(flutterDebugJar))
}
