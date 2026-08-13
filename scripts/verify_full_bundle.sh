#!/bin/bash
# Full-DMG content gate: keep this check independent of release upload.
set -euo pipefail
APP_PATH="${1:?usage: verify_full_bundle.sh /path/to/Hermeneus.app}"
for name in asr_server offline_diarizer Hermeneus_start.sh; do
  path="$APP_PATH/Contents/Resources/$name"
  if [[ ! -x "$path" ]]; then
    echo "missing executable Full-DMG resource: $path" >&2
    exit 1
  fi
done
"$APP_PATH/Contents/Resources/asr_server" --offline-batch --help >/dev/null
"$APP_PATH/Contents/Resources/offline_diarizer" --help >/dev/null
echo "Full-DMG offline resource gate passed"
