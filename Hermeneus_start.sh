#!/bin/bash
#
# Hermeneus_start.sh
# ---------------------------------------------------------------------------
# Hermeneus 实时语音同传应用启动器
#
# 设计原则：
# 1. 可重复执行：已经健康运行的本项目 ASR/Ollama 会被复用。
# 2. 只管理 Hermeneus：绝不根据端口号、进程名或 pkill 误杀其他程序。
# 3. 需要重启时仅向已确认属于本项目的 ASR 发送 SIGTERM；不使用 SIGKILL。
#
# 用法：
#   ./Hermeneus_start.sh                # 保持当前 Ollama 模型
#   ./Hermeneus_start.sh qwen2.5:7b     # 启动前预热指定本地模型
# ---------------------------------------------------------------------------
set -uo pipefail

readonly APP_NAME="Hermeneus"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly APP_PATH="/Applications/${APP_NAME}.app"
readonly ASR_BIN="${APP_PATH}/Contents/Resources/asr_server"
readonly ASR_SOURCE="${SCRIPT_DIR}/asr_server/server.py"
readonly ASR_LOG="${TMPDIR:-/tmp}/hermeneus-app-asr.log"
readonly ASR_PID_FILE="${TMPDIR:-/tmp}/hermeneus-app-asr.pid"
readonly OLLAMA_LOG="${TMPDIR:-/tmp}/hermeneus-ollama.log"
readonly ASR_PORTS=(8080 8081)
readonly OLLAMA_PORT=11434
readonly ASR_HEALTH_TIMEOUT_SEC="${HERMENEUS_ASR_TIMEOUT_SEC:-30}"
readonly OLLAMA_HEALTH_TIMEOUT_SEC="${HERMENEUS_OLLAMA_TIMEOUT_SEC:-10}"
readonly OLLAMA_API_URL="http://127.0.0.1:${OLLAMA_PORT}/api/tags"
readonly OLLAMA_GENERATE_URL="http://127.0.0.1:${OLLAMA_PORT}/api/generate"
readonly CUSTOM_MODEL_CANDIDATES=(
    "/Volumes/untitled/APP/ollama models"
    "/Volumes/Hermeneus/ollama models"
)
readonly TARGET_MODEL="${1:-}"

log()  { printf '%s\n' "$1"; }
ok()   { printf '✅ %s\n' "$1"; }
warn() { printf '⚠️  %s\n' "$1" >&2; }
fail() { printf '❌ %s\n' "$1" >&2; }
step() { printf '\n%s\n' "$1"; }

port_is_listening() {
    local port="$1"
    lsof -nP -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1
}

listener_pids() {
    local port="$1"
    lsof -tiTCP:"${port}" -sTCP:LISTEN 2>/dev/null | sort -u
}

command_for_pid() {
    local pid="$1"
    ps -ww -p "$pid" -o command= 2>/dev/null || true
}

is_hermeneus_asr_pid() {
    local pid="$1"
    local command
    command="$(command_for_pid "$pid")"
    [[ "$command" == *"${ASR_SOURCE}"* || "$command" == *"${ASR_BIN}"* ]]
}

asr_listener_pid_set() {
    { listener_pids "${ASR_PORTS[0]}"; listener_pids "${ASR_PORTS[1]}"; } | sort -u
}

asr_ports_ready() {
    port_is_listening "${ASR_PORTS[0]}" && port_is_listening "${ASR_PORTS[1]}"
}

show_asr_conflicts() {
    local pid
    for pid in $(asr_listener_pid_set); do
        warn "端口占用 PID ${pid}: $(command_for_pid "$pid")"
    done
}

stop_confirmed_hermeneus_asr() {
    local pids="$1"
    local pid
    for pid in $pids; do
        if ! is_hermeneus_asr_pid "$pid"; then
            fail "拒绝停止未确认属于 Hermeneus 的 PID ${pid}。"
            return 1
        fi
    done
    for pid in $pids; do
        log "   正在温和停止本项目 ASR（PID ${pid}）..."
        kill -TERM "$pid" 2>/dev/null || true
    done
    for _ in 1 2 3 4 5; do
        local remaining=""
        for pid in $pids; do
            if kill -0 "$pid" 2>/dev/null; then remaining="${remaining} ${pid}"; fi
        done
        [[ -z "$remaining" ]] && return 0
        sleep 1
    done
    fail "本项目 ASR 未在 5 秒内停止；为避免数据/模型损坏，启动器不会强制 kill -9。"
    return 1
}

wait_for_port() {
    local port="$1"
    local service_name="$2"
    local timeout="$3"
    local deadline=$((SECONDS + timeout))
    until port_is_listening "$port"; do
        if (( SECONDS >= deadline )); then
            fail "${service_name} 未能在 ${timeout}s 内监听端口 ${port}。"
            return 1
        fi
        sleep 1
    done
}

start_or_reuse_ollama() {
    local ollama_bin="$1"
    if port_is_listening "$OLLAMA_PORT"; then
        ok "复用已有 Ollama 服务（127.0.0.1:${OLLAMA_PORT}）"
    else
        log "   正在启动 Ollama；日志：${OLLAMA_LOG}"
        nohup "$ollama_bin" serve >"$OLLAMA_LOG" 2>&1 &
    fi
    wait_for_port "$OLLAMA_PORT" "Ollama" "$OLLAMA_HEALTH_TIMEOUT_SEC"
}

start_or_reuse_asr() {
    local pids pid_count first_pid
    pids="$(asr_listener_pid_set || true)"
    pid_count="$(printf '%s\n' "$pids" | sed '/^$/d' | wc -l | tr -d ' ')"

    if asr_ports_ready && [[ "$pid_count" == "1" ]]; then
        first_pid="$(printf '%s\n' "$pids" | head -n 1)"
        if is_hermeneus_asr_pid "$first_pid"; then
            printf '%s\n' "$first_pid" >"$ASR_PID_FILE"
            ok "复用健康的本项目 ASR（PID ${first_pid}，端口 ${ASR_PORTS[0]}/${ASR_PORTS[1]}）"
            return 0
        fi
        fail "ASR 端口已被非 Hermeneus 进程占用；不会停止它们。"
        show_asr_conflicts
        return 1
    fi

    if [[ -n "$pids" ]]; then
        local all_confirmed=1
        for pid in $pids; do
            if ! is_hermeneus_asr_pid "$pid"; then all_confirmed=0; fi
        done
        if [[ "$all_confirmed" == "1" ]]; then
            warn "检测到本项目 ASR 端口状态不完整，正在进行受控重启。"
            stop_confirmed_hermeneus_asr "$pids" || return 1
        else
            fail "ASR 端口被其他进程或多个不同进程占用；不会停止它们。"
            show_asr_conflicts
            return 1
        fi
    fi

    if [[ -f "$ASR_PID_FILE" ]]; then
        local stale_pid
        stale_pid="$(cat "$ASR_PID_FILE" 2>/dev/null || true)"
        if [[ -n "$stale_pid" ]] && kill -0 "$stale_pid" 2>/dev/null; then
            if is_hermeneus_asr_pid "$stale_pid"; then
                warn "检测到未监听端口的本项目 ASR（PID ${stale_pid}），进行受控重启。"
                stop_confirmed_hermeneus_asr "$stale_pid" || return 1
            else
                fail "PID 文件指向非 Hermeneus 进程；拒绝停止。"
                return 1
            fi
        fi
        rm -f "$ASR_PID_FILE"
    fi

    [[ -f "$ASR_BIN" ]] || { fail "未在 App 包内找到 asr_server: ${ASR_BIN}"; return 1; }
    chmod +x "$ASR_BIN"
    log "   正在启动 Hermeneus ASR；日志：${ASR_LOG}"
    nohup "$ASR_BIN" >"$ASR_LOG" 2>&1 &
    local asr_pid=$!
    printf '%s\n' "$asr_pid" >"$ASR_PID_FILE"
    wait_for_port "${ASR_PORTS[0]}" "ASR HTTP 服务" "$ASR_HEALTH_TIMEOUT_SEC" || return 1
    wait_for_port "${ASR_PORTS[1]}" "ASR WebSocket 服务" "$ASR_HEALTH_TIMEOUT_SEC" || return 1
    ok "ASR 已启动（PID ${asr_pid}，端口 ${ASR_PORTS[0]}/${ASR_PORTS[1]}）"
}

step "1/5 检查 Ollama 服务…"
OLLAMA_BIN="$(command -v ollama 2>/dev/null || true)"
if [[ -z "$OLLAMA_BIN" ]]; then
    for candidate in /opt/homebrew/bin/ollama /usr/local/bin/ollama /usr/bin/ollama; do
        [[ -x "$candidate" ]] && { OLLAMA_BIN="$candidate"; break; }
    done
fi
[[ -n "$OLLAMA_BIN" && -x "$OLLAMA_BIN" ]] || { fail "未检测到 Ollama 可执行文件。"; exit 1; }

OLLAMA_MODELS_PATH=""
for candidate in "${CUSTOM_MODEL_CANDIDATES[@]}"; do
    if [[ -d "$candidate" ]]; then OLLAMA_MODELS_PATH="$candidate"; break; fi
done
if [[ -n "$OLLAMA_MODELS_PATH" ]]; then
    export OLLAMA_MODELS="$OLLAMA_MODELS_PATH"
    log "📦 使用外置 Ollama 模型目录：${OLLAMA_MODELS}"
else
    warn "未检测到外置模型盘，使用 Ollama 默认模型目录。"
fi
start_or_reuse_ollama "$OLLAMA_BIN" || exit 1
if ! curl -sS -o /dev/null --max-time 2 "$OLLAMA_API_URL"; then
    fail "Ollama 服务未通过 API 探测；请检查日志：${OLLAMA_LOG}"
    exit 1
fi

if [[ -n "$TARGET_MODEL" ]]; then
    if [[ ! "$TARGET_MODEL" =~ ^[A-Za-z0-9._:-]+$ ]]; then
        fail "模型名仅允许字母、数字、点、下划线、冒号和连字符。"
        exit 1
    fi
    step "2/5 预热指定本地模型：${TARGET_MODEL}…"
    curl -sS -X POST "$OLLAMA_GENERATE_URL" \
        -H 'Content-Type: application/json' \
        -d "{\"model\":\"${TARGET_MODEL}\",\"prompt\":\"\",\"keep_alive\":\"30m\"}" \
        -o /dev/null || warn "模型预热请求未完成；请确认模型已通过 ollama list 安装。"
else
    step "2/5 保持当前 Ollama 模型状态…"
fi

step "3/5 检查 Hermeneus ASR 服务…"
start_or_reuse_asr || exit 1

step "4/5 清理应用隔离标记…"
if [[ -d "$APP_PATH" ]]; then
    xattr -cr "$APP_PATH" 2>/dev/null || true
else
    fail "未找到 ${APP_PATH}"
    exit 1
fi

step "5/5 启动 Hermeneus App…"
if open -a "$APP_NAME"; then
    ok "启动流程完成。"
else
    fail "无法启动 ${APP_PATH}"
    exit 1
fi
