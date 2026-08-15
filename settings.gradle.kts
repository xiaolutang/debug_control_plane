// R025-BF004-1: repo root aggregator (spike-b §4.2).
//
// JitPack builds from THIS settings file when a tag is pushed: the root
// project is the build entry, `:kotlin` is the publishable sub-module
// (maven-publish enabled in its own build.gradle.kts — spike-b §1.4 hard
// constraint: without the explicit plugin the publishToMavenLocal task
// does not exist and the online JitPack build fails).
//
// dart/, python/, fixtures/, flutter_debug_control_plane/{lib,test} are NOT
// gradle modules — they are Dart/Python trees living beside the build.
// Only the plugin's android/ dir is a gradle module, and it keeps its OWN
// standalone settings (android/settings.gradle.kts, includeBuild ../../kotlin
// for path-first dev) — it is consumed as a pub plugin's android module by
// the Flutter toolchain, not built from this root.
rootProject.name = "debug_control_plane"

include(":kotlin")
// Future gradle sub-modules: include(":xxx") here.
