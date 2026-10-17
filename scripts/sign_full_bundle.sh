#!/bin/bash
# Nested runtime code under Resources is not reliably discovered by --deep.
set -euo pipefail
APP_PATH="${1:?usage: sign_full_bundle.sh /path/to/Hermeneus.app}"
while IFS= read -r -d '' path; do
  case "$(file -b "$path")" in
    *Mach-O*) codesign --force --sign - "$path" ;;
  esac
done < <(find "$APP_PATH/Contents/Resources" -type f -print0)
# Signing changes Mach-O bytes. Preserve the original compiled CLI hash and
# record the packaged hash separately before sealing runtime.json in the app.
python3 - "$APP_PATH/Contents/Resources/ollama-runtime" <<'CHECK'
import hashlib, json, sys
from pathlib import Path
runtime = Path(sys.argv[1])
record = runtime / 'runtime.json'
if record.is_file():
    data = json.loads(record.read_text())
    data['packaged_cli_sha256'] = hashlib.sha256((runtime / 'ollama').read_bytes()).hexdigest()
    data['packaged_cli_signature'] = 'ad-hoc'
    data['packaged_runner_sha256'] = hashlib.sha256((runtime / 'llama-server').read_bytes()).hexdigest()
    record.write_text(json.dumps(data, indent=2) + '\n')
CHECK
python3 - "$APP_PATH/Contents/Resources" <<'CHECK'
import hashlib, json, sys
from pathlib import Path
resources = Path(sys.argv[1])
record = resources / 'diarization-build.json'
if record.is_file():
    data = json.loads(record.read_text())
    data['packaged_binary_sha256'] = hashlib.sha256((resources / 'offline_diarizer').read_bytes()).hexdigest()
    record.write_text(json.dumps(data, indent=2) + '\n')
CHECK
codesign --force --deep --sign - "$APP_PATH"
