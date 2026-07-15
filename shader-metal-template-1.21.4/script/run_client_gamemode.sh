#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${SHADERMETAL_GAME_MODE_APP:-$ROOT_DIR/build/gamemode/ShaderMetal Dev.app}"
EXECUTABLE="$APP/Contents/MacOS/ShaderMetalDev"
PID_FILE="$ROOT_DIR/build/gamemode/client.pid"
STDOUT_LOG="$ROOT_DIR/build/gamemode/client.stdout.log"
STDERR_LOG="$ROOT_DIR/build/gamemode/client.stderr.log"
RUN_DIRECTORY="$(pwd)"
TAIL_PID=""

pid_is_running() {
    local state
    state="$(ps -p "$1" -o state= 2>/dev/null || true)"
    [[ -n "$state" && "$state" != Z* ]]
}

launcher_pid() {
    local pid command
    [[ -f "$PID_FILE" ]] || return 0
    pid="$(sed -n '1p' "$PID_FILE" 2>/dev/null || true)"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 0
    command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    [[ "$command" == "$EXECUTABLE"* ]] && printf '%s\n' "$pid"
}

stop_launcher() {
    local pid
    pid="$(launcher_pid)"
    if [[ -n "$pid" ]]; then
        kill -TERM "$pid" 2>/dev/null || true
        for _ in {1..50}; do
            pid_is_running "$pid" || break
            sleep 0.1
        done
        pid_is_running "$pid" && kill -KILL "$pid" 2>/dev/null || true
    fi
    rm -f "$PID_FILE"
}

cleanup() {
    local status=$?
    trap - EXIT INT TERM HUP
    if [[ -n "$TAIL_PID" ]]; then
        kill -TERM "$TAIL_PID" 2>/dev/null || true
        wait "$TAIL_PID" 2>/dev/null || true
    fi
    stop_launcher
    rm -f "$STDOUT_LOG" "$STDERR_LOG"
    exit "$status"
}

trap cleanup EXIT INT TERM HUP
stop_launcher

if [[ ! -x "$EXECUTABLE" ]]; then
    echo "ShaderMetal Game Mode app is not prepared: $EXECUTABLE" >&2
    exit 2
fi

rm -f "$STDOUT_LOG" "$STDERR_LOG"
touch "$STDOUT_LOG" "$STDERR_LOG"
/usr/bin/tail -q -n +1 -f "$STDOUT_LOG" "$STDERR_LOG" &
TAIL_PID=$!

/usr/bin/open -n -W \
    --stdout "$STDOUT_LOG" \
    --stderr "$STDERR_LOG" \
    --env "JAVA_HOME=$JAVA_HOME" \
    --env "PATH=$PATH" \
    --env "HOME=${HOME:-}" \
    --env "TMPDIR=${TMPDIR:-/tmp}" \
    --env "MTL_HUD_ENABLED=${MTL_HUD_ENABLED:-1}" \
    --env "SHADERMETAL_RUN_DIR=$RUN_DIRECTORY" \
    --env "SHADERMETAL_PID_FILE=$PID_FILE" \
    "$APP" --args "$@"
