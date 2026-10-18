#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hermeneus-ipc-test.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -module-cache-path "$TEST_DIR/module-cache" -parse-as-library "$ROOT/HermeneusApp/Packages/AudioCore/Sources/AudioCore/LocalServiceAccess.swift" "$ROOT/tests/ipc_socket_smoke.swift" -o "$TEST_DIR/ipc-test"
"$TEST_DIR/ipc-test" "${HERMENEUS_TEST_PYTHON:-$(command -v python3)}" "$ROOT/tests/ipc_socket_fixture.py"
