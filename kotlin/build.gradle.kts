plugins {
    kotlin("jvm") version "2.0.21"
    application
    // R025-BF004-1 (spike-b §1.4 hard constraint): maven-publish MUST be
    // explicitly enabled with a publication declared below — otherwise the
    // publishToMavenLocal task does not exist and the online JitPack build
    // fails ("Projects using Gradle need to have either the maven or
    // maven-publish plugin enabled").
    `maven-publish`
}

// JitPack multi-module GAV (spike-b §2.4):
//   com.github.xiaolutang.debug_control_plane:kotlin:<tag>
// Local dev path consumers (plugin includeBuild, pantas_launcher composite
// build) keep substituting via the com.pantas.debug.controlplane:core
// coordinate declared in their settings.gradle.kts — see
// publishing.publications below which keeps artifactId = "kotlin".
group = "com.github.xiaolutang.debug_control_plane"
version = "0.2.0" // future tag version (R025-C: no tag pushed in this RC)

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

// R025-BF004-1: explicit publication (spike-b §4.4) — JitPack copies these
// artifacts (jar + pom + .module) into its local Maven repository.
// artifactId defaults to the project name ("kotlin" — matches the
// settings.gradle.kts include leaf AND the directory name).
publishing {
    publications {
        create<MavenPublication>("maven") {
            from(components["java"])
        }
    }
}
