#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hermeneus-audio-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -module-cache-path "$TEST_DIR/module-cache" -parse-as-library \
  "$ROOT/HermeneusApp/Packages/TTSKit/Sources/TTSKit/AudioOutputDevice.swift" \
  "$ROOT/HermeneusApp/Packages/TTSKit/Sources/TTSKit/TTSProtocol.swift" \
  "$ROOT/HermeneusApp/Packages/TTSKit/Sources/TTSKit/BlackHoleTTSEngine.swift" \
  "$ROOT/tests/audio_route_smoke.swift" -o "$TEST_DIR/audio-route-tests"
"$TEST_DIR/audio-route-tests"
