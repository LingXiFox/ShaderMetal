#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GRADLEW="$ROOT_DIR/gradlew"
JAVA_HOME="$(/usr/libexec/java_home -v 21)"
export JAVA_HOME
export PATH="$JAVA_HOME/bin:$PATH"

project_java_pids() {
    local pid cwd command
    while IFS= read -r pid; do
        [[ -n "$pid" ]] || continue
        cwd="$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1)"
        command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
        if [[ "$cwd" == "$ROOT_DIR"* || "$command" == *"$ROOT_DIR"* ]]; then
            printf '%s\n' "$pid"
        fi
    done < <(pgrep -x java 2>/dev/null || true)
}

stop_project_java() {
    local pid
    while IFS= read -r pid; do
        [[ -n "$pid" ]] || continue
        kill -TERM "$pid" 2>/dev/null || true
    done < <(project_java_pids)

    for _ in {1..20}; do
        [[ -z "$(project_java_pids)" ]] && return 0
        sleep 0.1
    done

    while IFS= read -r pid; do
        [[ -n "$pid" ]] || continue
        kill -KILL "$pid" 2>/dev/null || true
    done < <(project_java_pids)
}

cleanup() {
    local status=$?
    trap - EXIT INT TERM HUP
    stop_project_java
    "$GRADLEW" --stop >/dev/null 2>&1 || true
    stop_project_java

    local remaining
    remaining="$(project_java_pids)"
    if [[ -n "$remaining" ]]; then
        echo "ShaderMetal Java processes remain after cleanup: $remaining" >&2
        status=1
    fi
    exit "$status"
}

trap cleanup EXIT INT TERM HUP

stop_project_java
"$GRADLEW" --stop >/dev/null 2>&1 || true
"$GRADLEW" --no-daemon "$@"
