#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GRADLEW="$ROOT_DIR/gradlew"
JAVA_HOME="$(/usr/libexec/java_home -v 21)"
export JAVA_HOME
export PATH="$JAVA_HOME/bin:$PATH"

ROOT_KEY="$(printf '%s' "$ROOT_DIR" | shasum -a 256 | cut -c 1-16)"
STATE_FILE="${TMPDIR:-/tmp}"
STATE_FILE="${STATE_FILE%/}/shadermetal-gradle-task-${UID}-${ROOT_KEY}.pid"
GAMEMODE_PID_FILE="$ROOT_DIR/build/gamemode/client.pid"
GAMEMODE_EXECUTABLE="$ROOT_DIR/build/gamemode/ShaderMetal Dev.app/Contents/MacOS/ShaderMetalDev"
GAMEMODE_STDOUT_LOG="$ROOT_DIR/build/gamemode/client.stdout.log"
GAMEMODE_STDERR_LOG="$ROOT_DIR/build/gamemode/client.stderr.log"
GRADLE_PID=""
GRADLE_ARGUMENTS=("$@")

USE_GAMEMODE_TASK=false
for argument in "${GRADLE_ARGUMENTS[@]}"; do
    if [[ "$argument" == "runClient" || "$argument" == ":runClient" ||
          "$argument" == "runClientGameMode" ||
          "$argument" == ":runClientGameMode" ]]; then
        USE_GAMEMODE_TASK=true
        break
    fi
done

if [[ "$USE_GAMEMODE_TASK" == true ]]; then
    for index in "${!GRADLE_ARGUMENTS[@]}"; do
        argument="${GRADLE_ARGUMENTS[$index]}"
        case "$argument" in
            runClient)
                GRADLE_ARGUMENTS[$index]="runClientGameMode"
                ;;
            :runClient)
                GRADLE_ARGUMENTS[$index]=":runClientGameMode"
                ;;
            --args=*)
                GRADLE_ARGUMENTS[$index]="-PshadermetalGameArgs=${argument#--args=}"
                ;;
            --debug-jvm)
                GRADLE_ARGUMENTS[$index]="-PshadermetalDebug=true"
                ;;
        esac
    done
fi

command_for_pid() {
    ps -p "$1" -o command= 2>/dev/null || true
}

pid_is_running() {
    local state
    state="$(ps -p "$1" -o state= 2>/dev/null || true)"
    [[ -n "$state" && "$state" != Z* ]]
}

collect_process_tree() {
    local root_pid="$1"
    local child_pid

    while IFS= read -r child_pid; do
        [[ -n "$child_pid" ]] || continue
        collect_process_tree "$child_pid"
    done < <(pgrep -P "$root_pid" 2>/dev/null || true)

    pid_is_running "$root_pid" && printf '%s\n' "$root_pid"
}

terminate_pids() {
    local pids="$1"
    local pid remaining

    for pid in $pids; do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        kill -TERM "$pid" 2>/dev/null || true
    done

    for _ in {1..50}; do
        remaining=""
        for pid in $pids; do
            if pid_is_running "$pid"; then
                remaining="$remaining $pid"
            fi
        done
        [[ -z "$remaining" ]] && return 0
        sleep 0.1
    done

    for pid in $remaining; do
        kill -KILL "$pid" 2>/dev/null || true
    done

    for _ in {1..20}; do
        remaining=""
        for pid in $pids; do
            if pid_is_running "$pid"; then
                remaining="$remaining $pid"
            fi
        done
        [[ -z "$remaining" ]] && return 0
        sleep 0.1
    done

    return 1
}

stop_process_tree() {
    local root_pid="$1"
    local pids

    pids="$(collect_process_tree "$root_pid")"
    [[ -z "$pids" ]] || terminate_pids "$pids"
}

project_runtime_pids() {
    local pid command

    while IFS= read -r pid; do
        [[ -n "$pid" ]] || continue
        command="$(command_for_pid "$pid")"
        if [[ "$command" == *"-Dfabric.dli.config=$ROOT_DIR/"* ||
              "$command" == *"$ROOT_DIR/build/loom-cache/argFiles/runClient"* ]]; then
            printf '%s\n' "$pid"
        fi
    done < <(pgrep -x java 2>/dev/null || true)

    if [[ -f "$GAMEMODE_PID_FILE" ]]; then
        pid="$(sed -n '1p' "$GAMEMODE_PID_FILE" 2>/dev/null || true)"
        if [[ "$pid" =~ ^[0-9]+$ ]]; then
            command="$(command_for_pid "$pid")"
            if [[ "$command" == "$GAMEMODE_EXECUTABLE"* ]]; then
                printf '%s\n' "$pid"
            fi
        fi
    fi
}

stop_project_runtime() {
    local pids
    pids="$(project_runtime_pids | sort -u)"
    [[ -z "$pids" ]] || terminate_pids "$pids"
    rm -f "$GAMEMODE_PID_FILE" "$GAMEMODE_STDOUT_LOG" "$GAMEMODE_STDERR_LOG"
}

recover_previous_invocation() {
    local previous_pid command

    [[ -f "$STATE_FILE" ]] || return 0
    previous_pid="$(sed -n '1p' "$STATE_FILE" 2>/dev/null || true)"
    if [[ "$previous_pid" =~ ^[0-9]+$ ]]; then
        command="$(command_for_pid "$previous_pid")"
        if [[ "$command" == *"$GRADLEW"* ||
              "$command" == *"$ROOT_DIR/gradle/wrapper/gradle-wrapper.jar"* ]]; then
            stop_process_tree "$previous_pid" || true
        fi
    fi
    rm -f "$STATE_FILE"
}

cleanup() {
    local status=$?
    local remaining state_pid
    trap - EXIT INT TERM HUP

    if [[ -n "$GRADLE_PID" ]]; then
        stop_process_tree "$GRADLE_PID" || status=1
    fi
    stop_project_runtime || status=1

    if [[ -f "$STATE_FILE" ]]; then
        state_pid="$(sed -n '1p' "$STATE_FILE" 2>/dev/null || true)"
        [[ "$state_pid" != "$GRADLE_PID" ]] || rm -f "$STATE_FILE"
    fi

    remaining="$(project_runtime_pids | sort -u)"
    if [[ -n "$remaining" ]]; then
        echo "ShaderMetal runtime processes remain after cleanup: $remaining" >&2
        status=1
    fi
    exit "$status"
}

trap cleanup EXIT INT TERM HUP

recover_previous_invocation
stop_project_runtime

"$GRADLEW" --no-daemon "${GRADLE_ARGUMENTS[@]}" &
GRADLE_PID=$!
printf '%s\n' "$GRADLE_PID" > "$STATE_FILE"
wait "$GRADLE_PID"
