#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hermeneus-log-test.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -module-cache-path "$TEST_DIR/module-cache" -parse-as-library "$ROOT/HermeneusApp/Packages/AudioCore/Sources/AudioCore/PrivateLogFile.swift" "$ROOT/tests/private_log_security.swift" -o "$TEST_DIR/private-log-test"
"$TEST_DIR/private-log-test"
