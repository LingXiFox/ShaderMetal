#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INCLUDE_DIR="$ROOT_DIR/native/include"
DYLIB_INPUT="${1:-build/native/libshadermetal.dylib}"

if [[ $# -gt 1 ]]; then
    echo "usage: $0 [path/to/libshadermetal.dylib]" >&2
    exit 2
fi

if [[ "$DYLIB_INPUT" = /* ]]; then
    DYLIB_PATH="$DYLIB_INPUT"
else
    DYLIB_PATH="$ROOT_DIR/$DYLIB_INPUT"
fi

if [[ ! -d "$INCLUDE_DIR" ]]; then
    echo "JNI include directory not found: $INCLUDE_DIR" >&2
    exit 2
fi

HEADER_FILES=("$INCLUDE_DIR"/*.h)
if [[ ! -e "${HEADER_FILES[0]}" ]]; then
    echo "No JNI headers found in: $INCLUDE_DIR" >&2
    exit 2
fi

if [[ ! -f "$DYLIB_PATH" ]]; then
    echo "Native library not found: $DYLIB_PATH" >&2
    exit 2
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/shadermetal-jni-contract.XXXXXX")"
cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

EXPECTED="$TMP_DIR/expected"
EXPORTED="$TMP_DIR/exported"
MISSING="$TMP_DIR/missing"
UNEXPECTED="$TMP_DIR/unexpected"
NM_OUTPUT="$TMP_DIR/nm-output"

awk '
    /JNIEXPORT/ {
        if (match($0, /Java_[[:alnum:]_]+/)) {
            print substr($0, RSTART, RLENGTH)
        }
    }
' "${HEADER_FILES[@]}" | sort -u >"$EXPECTED"

if [[ ! -s "$EXPECTED" ]]; then
    echo "No JNIEXPORT Java_* declarations found in: $INCLUDE_DIR" >&2
    exit 2
fi

if ! nm -gU "$DYLIB_PATH" >"$NM_OUTPUT"; then
    echo "Failed to read exported symbols from: $DYLIB_PATH" >&2
    exit 2
fi

awk '
    {
        for (i = 1; i <= NF; i++) {
            symbol = $i
            sub(/^_/, "", symbol)
            if (symbol ~ /^Java_[[:alnum:]_]+$/) {
                print symbol
            }
        }
    }
' "$NM_OUTPUT" | sort -u >"$EXPORTED"

comm -23 "$EXPECTED" "$EXPORTED" >"$MISSING"
comm -13 "$EXPECTED" "$EXPORTED" >"$UNEXPECTED"

expected_count="$(wc -l <"$EXPECTED" | tr -d '[:space:]')"
exported_count="$(wc -l <"$EXPORTED" | tr -d '[:space:]')"
missing_count="$(wc -l <"$MISSING" | tr -d '[:space:]')"
unexpected_count="$(wc -l <"$UNEXPECTED" | tr -d '[:space:]')"

printf 'JNI contract: expected=%s exported=%s missing=%s unexpected=%s\n' \
    "$expected_count" "$exported_count" "$missing_count" "$unexpected_count"

if [[ "$missing_count" -ne 0 ]]; then
    echo "Missing JNI exports:"
    sed 's/^/  /' "$MISSING"
fi

if [[ "$unexpected_count" -ne 0 ]]; then
    echo "Unexpected JNI exports:"
    sed 's/^/  /' "$UNEXPECTED"
fi

if [[ "$missing_count" -ne 0 || "$unexpected_count" -ne 0 ]]; then
    exit 1
fi

echo "JNI contract matches."
