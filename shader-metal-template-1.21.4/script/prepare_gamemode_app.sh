#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 JAVA_HOME OUTPUT_APP" >&2
    exit 2
fi

JAVA_HOME="$1"
OUTPUT_APP="$2"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="$SCRIPT_DIR/gamemode/ShaderMetalDev.c"
PLIST="$SCRIPT_DIR/gamemode/Info.plist"
CONTENTS="$OUTPUT_APP/Contents"
EXECUTABLE="$CONTENTS/MacOS/ShaderMetalDev"

if [[ ! -f "$JAVA_HOME/lib/libjli.dylib" ||
      ! -f "$JAVA_HOME/include/jni.h" ||
      ! -f "$SOURCE" || ! -f "$PLIST" ]]; then
    echo "ShaderMetal Game Mode launcher inputs are incomplete" >&2
    exit 2
fi

JAVA_VERSION="$(sed -n 's/^JAVA_VERSION="\(.*\)"$/\1/p' "$JAVA_HOME/release" | head -n 1)"
JAVA_VERSION="${JAVA_VERSION:-21}"

rm -rf "$OUTPUT_APP"
mkdir -p "$CONTENTS/MacOS"
install -m 0644 "$PLIST" "$CONTENTS/Info.plist"

"$(xcrun --find clang)" \
    -std=c17 -O2 -Wall -Wextra -Werror \
    -isysroot "$(xcrun --sdk macosx --show-sdk-path)" \
    -mmacosx-version-min=26.0 \
    -I"$JAVA_HOME/include" \
    -I"$JAVA_HOME/include/darwin" \
    -DSHADERMETAL_JAVA_VERSION="\"$JAVA_VERSION\"" \
    "$SOURCE" \
    -L"$JAVA_HOME/lib" -ljli \
    -Wl,-rpath,"$JAVA_HOME/lib" \
    -o "$EXECUTABLE"

/usr/bin/codesign --force --sign - --timestamp=none "$OUTPUT_APP" >/dev/null
