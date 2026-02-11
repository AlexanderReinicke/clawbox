#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)/ClawMarket"
ARCHIVE_PATH="${1:-$PWD/build/ClawMarket.xcarchive}"

mkdir -p "$(dirname "$ARCHIVE_PATH")"

xcodebuild \
  -project "$PROJECT_DIR/ClawMarket.xcodeproj" \
  -scheme ClawMarket \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  archive

echo "Archive created: $ARCHIVE_PATH"
