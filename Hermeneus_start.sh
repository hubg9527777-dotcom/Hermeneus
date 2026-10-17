#!/bin/bash
# Compatibility entry point. The app owns setup, model choice and service startup.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "$ROOT" == *.app/Contents/Resources ]]; then
    exec open "${ROOT%/Contents/Resources}"
fi
for app in "$ROOT/HermeneusApp/App/.build/release/Hermeneus.app" "/Applications/Hermeneus.app" "$HOME/Applications/Hermeneus.app"; do
    if [[ -d "$app" ]]; then exec open "$app"; fi
done
osascript -e 'display alert "请先安装 Hermeneus Full 完整版" message "打开 Full.dmg，把 Hermeneus 拖入应用程序，再双击 Hermeneus。首次打开会显示安装向导，无需终端命令。"' >/dev/null
exit 1
