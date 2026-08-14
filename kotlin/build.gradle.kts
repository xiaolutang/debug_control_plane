plugins {
    kotlin("jvm") version "2.0.21"
    application
}

repositories {
    mavenCentral()
}

dependencies {
    // NanoHTTPD: lightweight embeddable HTTP server, no business deps.
    implementation("org.nanohttpd:nanohttpd:2.3.1")
    // org.json: JSON encoding (bundled on Android; explicit for pure JVM tests).
    implementation("org.json:json:20240303")
    // Coroutines: for cooperative broadcast / SSE lifecycle.
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.9.0")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.9.0")
}

kotlin {
    jvmToolchain(17)
}

application {
    mainClass.set("com.pantas.debug.controlplane.MainKt")
}

tasks.test {
    useJUnit()
    // Show test output for evidence capture.
    testLogging {
        events("passed", "skipped", "failed", "standardOut", "standardError")
        showStandardStreams = true
    }
}
