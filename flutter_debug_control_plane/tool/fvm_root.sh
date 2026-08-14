#!/bin/bash
# Resolve the fvm-managed stable Flutter SDK root.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_FVM="$DIR/.fvm"
if [ -f "$PROJECT_FVM/fvm_config.json" ] || [ -L "$PROJECT_FVM/flutter_sdk" ]; then
    ROOT="$(cd "$PROJECT_FVM/flutter_sdk" && pwd)"
else
    ROOT="$(cd "$HOME/fvm/versions/stable" && pwd)"
fi
if [ ! -x "$ROOT/bin/flutter" ]; then
    echo "error: flutter not found under $ROOT" >&2
    exit 1
fi
echo "$ROOT"
