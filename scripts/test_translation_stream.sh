#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hermeneus-stream-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -module-cache-path "$TEST_DIR/module-cache" -parse-as-library \
  "$ROOT/HermeneusApp/Packages/TranslateKit/Sources/TranslateKit/OllamaStreamState.swift" \
  "$ROOT/tests/translation_stream_smoke.swift" -o "$TEST_DIR/stream-tests"
"$TEST_DIR/stream-tests"
