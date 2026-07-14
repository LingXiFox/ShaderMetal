#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GRADLE_TASK="$ROOT_DIR/script/gradle_task.sh"
MODE="${1:-run}"
RUNNER_PID=""

cleanup_runner() {
    if [[ -n "$RUNNER_PID" ]] && kill -0 "$RUNNER_PID" 2>/dev/null; then
        kill -TERM "$RUNNER_PID" 2>/dev/null || true
        wait "$RUNNER_PID" 2>/dev/null || true
    fi
}

trap cleanup_runner EXIT INT TERM HUP

cd "$ROOT_DIR"

case "$MODE" in
    run)
        "$GRADLE_TASK" clean build
        "$GRADLE_TASK" runClient
        ;;
    build)
        "$GRADLE_TASK" clean build
        ;;
    --verify|verify)
        "$GRADLE_TASK" clean build
        mkdir -p build/verification
        "$GRADLE_TASK" runClient >build/verification/run-client.log 2>&1 &
        RUNNER_PID=$!
        sleep "${SHADERMETAL_VERIFY_SECONDS:-30}"
        if ! kill -0 "$RUNNER_PID" 2>/dev/null; then
            tail -n 80 build/verification/run-client.log >&2
            exit 1
        fi
        echo "ShaderMetal runClient remained alive for the verification window."
        ;;
    --debug|debug)
        "$GRADLE_TASK" runClient --debug-jvm
        ;;
    --logs|logs|--telemetry|telemetry)
        "$GRADLE_TASK" runClient
        ;;
    headers)
        "$GRADLE_TASK" generateJniHeaders
        ;;
    *)
        echo "usage: $0 [run|build|headers|--verify|--debug|--logs|--telemetry]" >&2
        exit 2
        ;;
esac
