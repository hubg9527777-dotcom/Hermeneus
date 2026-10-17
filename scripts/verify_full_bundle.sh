#!/bin/bash
# Full-DMG content gate: keep this check independent of release upload.
set -euo pipefail
APP_PATH="${1:?usage: verify_full_bundle.sh /path/to/Hermeneus.app}"
export PATH="$APP_PATH/Contents/Resources/ffmpeg:$PATH"
for name in asr_server offline_diarizer Hermeneus_start.sh ollama-runtime/ollama ollama-runtime/llama-server ffmpeg/ffmpeg; do
  path="$APP_PATH/Contents/Resources/$name"
  if [[ ! -x "$path" ]]; then
    echo "missing executable Full-DMG resource: $path" >&2
    exit 1
  fi
done
"$APP_PATH/Contents/Resources/asr_server" --offline-batch --help >/dev/null
"$APP_PATH/Contents/Resources/offline_diarizer" --help >/dev/null
SETUP_PROTOCOL="$("$APP_PATH/Contents/Resources/asr_server" --setup-check)"
if [[ "$SETUP_PROTOCOL" != *'"setup_protocol":2'* ]]; then
  echo "ASR binary does not support the desktop setup assistant" >&2
  exit 1
fi

test -s "$APP_PATH/Contents/Resources/diarization-build.json"
python3 - "$APP_PATH/Contents/Resources/diarization-build.json" <<'CHECK'
import hashlib, json, sys
from pathlib import Path
record = json.load(open(sys.argv[1]))
assert record.get('version') == '1.13.8+hermeneus.1', 'Unpatched diarization runtime'
assert record.get('source_commit') == '11afbd009a7f8c08f4bcf2fc1b265d0df4670fbf', 'Unexpected diarization source'
assert record.get('patch_sha256') == '833d73f98b8d8c652cab7c1df9d5cc7d1821e2f104eb34172ba63eb6578a5c5d', 'Unreviewed decoder patch'
actual = hashlib.sha256(Path(sys.argv[1]).with_name('offline_diarizer').read_bytes()).hexdigest()
assert actual == record.get('packaged_binary_sha256', record.get('frozen_binary_sha256')), 'Diarizer hash mismatch'
CHECK
test -s "$APP_PATH/Contents/Resources/ollama-runtime/runtime.json"
python3 - "$APP_PATH/Contents/Resources/ollama-runtime/runtime.json" <<'CHECK'
import hashlib, json, sys
from pathlib import Path
record = json.load(open(sys.argv[1]))
metadata = record.get('security_build', {})
if 'packaged_cli_sha256' in record:
    assert hashlib.sha256(Path(sys.argv[1]).with_name('ollama').read_bytes()).hexdigest() == record['packaged_cli_sha256'], 'Packaged CLI hash mismatch' 
assert metadata.get('revision') == '0.40.6-hermeneus.3', 'Unpatched Ollama runtime'
native = record.get('native_build', {})
assert native.get('llama_commit') == '620d2225cc436ab0b001e3200e590e3b286ef9ab', 'Unreviewed native payload'
assert native.get('rpc_enabled') is False, 'Native RPC must be disabled'
assert native.get('gif_disabled') is True, 'Native GIF decoding must be disabled'
if 'packaged_runner_sha256' in record:
    assert hashlib.sha256(Path(sys.argv[1]).with_name('llama-server').read_bytes()).hexdigest() == record['packaged_runner_sha256'], 'Packaged native runner hash mismatch'
assert metadata.get('go_version') == 'go1.27.2', 'Unexpected Go runtime'
CHECK
test -s "$APP_PATH/Contents/Resources/ollama-runtime/OLLAMA_LICENSE"
"$APP_PATH/Contents/Resources/ollama-runtime/ollama" --version
libraries=("$APP_PATH/Contents/Resources/ollama-runtime/"*.dylib)
test -f "${libraries[0]}"
"$APP_PATH/Contents/Resources/asr_server" --runtime-check
env DYLD_FALLBACK_LIBRARY_PATH="$APP_PATH/Contents/Resources/ffmpeg/lib" "$APP_PATH/Contents/Resources/offline_diarizer" --runtime-check
"$APP_PATH/Contents/Resources/ffmpeg/ffmpeg" -version >/dev/null
echo "Full-DMG offline, setup and headless runtime resource gates passed"
