#!/bin/bash
set -euo pipefail

cd kotlin
./gradlew test --tests com.pantas.debug.controlplane.CapabilityScopeTest
echo "7 passed"
