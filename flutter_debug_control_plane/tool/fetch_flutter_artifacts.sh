#!/bin/bash
# FF001-2: fetch io.flutter embedding artifacts for standalone JVM compilation.
#
# The plugin module must compile with io.flutter.* without a full Flutter
# host app. `fvm flutter precache --android` downloads the embedding AARs
# into the local Flutter SDK cache; we copy them next to the plugin as
# compileOnly file dependencies (kept out of git).
#
# Requires: fvm stable (the system Flutter is an OHOS fork, unusable).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
FLUTTER_BIN="${FVM_FLUTTER:-$(command -v fvm >/dev/null 2>&1 && fvm stable --version >/dev/null 2>&1 && echo stable || echo "")}"

if [ -n "${FVM_FLUTTER:-}" ]; then
    FLUTTER_ROOT="$(cd "$(dirname "$FLUTTER_BIN")/.." && pwd)"
elif command -v fvm >/dev/null 2>&1; then
    FLUTTER_ROOT="$("$HERE/fvm_root.sh")"
else
    echo "error: fvm not found; set FVM_FLUTTER=/path/to/flutter/bin/flutter" >&2
    exit 1
fi

CACHE="$FLUTTER_ROOT/bin/cache/artifacts/engine"
if [ ! -d "$CACHE/android-arm-profile" ]; then
    "$FLUTTER_ROOT/bin/flutter" precache --android >/dev/null
fi

DST="$HERE/../android/libs"
mkdir -p "$DST"

copy_artifact() {
    local src="$1" dst="$2"
    if [ -f "$src" ]; then
        cp -f "$src" "$dst"
        echo "fetched $(basename "$dst")"
    else
        echo "warning: missing $src" >&2
        return 1
    fi
}

status=0
copy_artifact "$CACHE/android-arm-debug/flutter-debug.aar"        "$DST/flutter-debug.aar"        || status=1
copy_artifact "$CACHE/android-arm-profile/flutter-profile.aar"    "$DST/flutter-profile.aar"      || status=1
copy_artifact "$CACHE/android-arm-release/flutter-release.aar"    "$DST/flutter-release.aar"      || status=1

exit $status
