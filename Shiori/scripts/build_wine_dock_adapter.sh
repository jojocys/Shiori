#!/bin/zsh
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="$1"
mkdir -p "$(dirname "$OUTPUT")"
clang -dynamiclib -fobjc-arc -framework AppKit -arch arm64 -arch x86_64 \
  -mmacosx-version-min=13.0 "$ROOT_DIR/Native/WineDock.m" -o "$OUTPUT"
codesign --force --sign - --timestamp=none "$OUTPUT"
