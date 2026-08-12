#!/bin/bash
# Hermeneus local launcher. It only manages processes started through this script
# and never force-kills unrelated Python, Ollama, or port-owning processes.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OLLAMA_BIN="${OLLAMA_BIN:-/opt/homebrew/bin/ollama}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
ASR_PORT="${ASR_HTTP_PORT:-8080}"
WS_PORT="${ASR_WS_PORT:-8081}"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"
START_TIMEOUT="${HERMENEUS_START_TIMEOUT:-120}"
RUNTIME_DIR="${TMPDIR:-/tmp}/hermeneus-runtime"
ASR_PID_FILE="$RUNTIME_DIR/asr_server.pid"
ASR_LOG_FILE="$RUNTIME_DIR/asr_server.log"
OLLAMA_LOG_FILE="$RUNTIME_DIR/ollama.log"
EXTERNAL_MODEL_DIR="/Volumes/untitled/APP/ollama models"

mkdir -p "$RUNTIME_DIR"

port_is_listening() {
    lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
}

wait_for_port() {
    local port="$1"
    local service_name="$2"
    local deadline=$((SECONDS + START_TIMEOUT))
    until port_is_listening "$port"; do
        if (( SECONDS >= deadline )); then
            echo "❌ ${service_name} 未能在 ${START_TIMEOUT}s 内监听端口 ${port}。"
            return 1
        fi
        sleep 1
    done
}

if [[ -d "$EXTERNAL_MODEL_DIR" && -z "${OLLAMA_MODELS:-}" ]]; then
    export OLLAMA_MODELS="$EXTERNAL_MODEL_DIR"
    echo "📦 使用外置 Ollama 模型目录：$OLLAMA_MODELS"
elif [[ -n "${OLLAMA_MODELS:-}" ]]; then
    echo "📦 使用已有 OLLAMA_MODELS：$OLLAMA_MODELS"
else
    echo "⚠️ 未找到外置模型目录，将使用 Ollama 默认模型目录。"
fi

if [[ ! -x "$OLLAMA_BIN" ]]; then
    OLLAMA_BIN="$(command -v ollama || true)"
fi
if [[ -z "$OLLAMA_BIN" || ! -x "$OLLAMA_BIN" ]]; then
    echo "❌ 未找到 ollama。请安装后重试，或通过 OLLAMA_BIN 指定可执行文件。"
    exit 1
fi
if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
    echo "❌ 未找到 Python：$PYTHON_BIN"
    exit 1
fi

echo "1/3 检查 Ollama 服务…"
if ! port_is_listening "$OLLAMA_PORT"; then
    nohup "$OLLAMA_BIN" serve >"$OLLAMA_LOG_FILE" 2>&1 &
    echo "   正在启动 Ollama；日志：$OLLAMA_LOG_FILE"
fi
wait_for_port "$OLLAMA_PORT" "Ollama"

if ! "$OLLAMA_BIN" list >/dev/null 2>&1; then
    echo "❌ Ollama API 已监听，但模型列表不可用。请检查：$OLLAMA_LOG_FILE"
    exit 1
fi

echo "2/3 检查本项目 ASR 服务…"
if port_is_listening "$ASR_PORT" || port_is_listening "$WS_PORT"; then
    echo "❌ ASR 端口 ${ASR_PORT}/${WS_PORT} 已被占用。为避免误杀其他进程，启动器不会清理它们。"
    echo "   请确认现有服务属于 Hermeneus，或手动停止后重试。"
    exit 1
fi

if [[ -f "$ASR_PID_FILE" ]]; then
    previous_pid="$(cat "$ASR_PID_FILE" 2>/dev/null || true)"
    if [[ -n "$previous_pid" ]] && kill -0 "$previous_pid" 2>/dev/null; then
        echo "❌ 检测到先前由 Hermeneus 启动的 ASR 进程（PID ${previous_pid}）仍在运行，但端口未就绪。"
        echo "   请先检查日志：$ASR_LOG_FILE"
        exit 1
    fi
    rm -f "$ASR_PID_FILE"
fi

nohup "$PYTHON_BIN" "$PROJECT_ROOT/asr_server/server.py" >"$ASR_LOG_FILE" 2>&1 &
echo $! >"$ASR_PID_FILE"
echo "   正在启动 ASR；日志：$ASR_LOG_FILE"
wait_for_port "$ASR_PORT" "ASR HTTP 服务"
wait_for_port "$WS_PORT" "ASR WebSocket 服务"

echo "3/3 启动 Hermeneus App…"
cd "$PROJECT_ROOT/HermeneusApp/App"
exec swift run
