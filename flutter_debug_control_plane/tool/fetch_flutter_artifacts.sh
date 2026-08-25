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

if [ -n "${FVM_FLUTTER:-}" ]; then
    FLUTTER_ROOT="$(cd "$(dirname "$FVM_FLUTTER")/.." && pwd)"
elif command -v flutter >/dev/null 2>&1; then
    FLUTTER_ROOT="$(cd "$(dirname "$(command -v flutter)")/.." && pwd)"
elif command -v fvm >/dev/null 2>&1; then
    FLUTTER_ROOT="$("$HERE/fvm_root.sh")"
else
    echo "error: flutter/fvm not found; set FVM_FLUTTER=/path/to/flutter/bin/flutter" >&2
    exit 1
fi

CACHE="$FLUTTER_ROOT/bin/cache/artifacts/engine"
if [ ! -d "$CACHE/android-arm-profile" ] || [ ! -d "$CACHE/android-arm" ]; then
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
copy_artifact "$CACHE/android-arm/flutter.jar"         "$DST/flutter-debug.jar"      || status=1
copy_artifact "$CACHE/android-arm-profile/flutter.jar" "$DST/flutter-profile.jar"    || status=1
copy_artifact "$CACHE/android-arm-release/flutter.jar" "$DST/flutter-release.jar"    || status=1

exit $status
