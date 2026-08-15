// R025-BF004-1: root project stays a pure aggregator (spike-b §4.3) — no
// plugins applied here (the root publishes nothing itself).
//
// mavenCentral serves the :kotlin runtime deps (nanohttpd / org.json /
// kotlinx-coroutines); gradlePluginPortal serves the Kotlin JVM plugin
// resolution when JitPack builds from a tag.
allprojects {
    repositories {
        mavenCentral()
        gradlePluginPortal()
    }
}
