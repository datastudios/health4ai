#!/bin/sh
set -eu

BUILD_NUMBER="${1:?Usage: stamp_build_number.sh <numeric-build-number>}"

case "$BUILD_NUMBER" in
  *[!0-9]*|'')
    echo "Build number must contain digits only." >&2
    exit 64
    ;;
esac

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
PBXPROJ="$PROJECT_DIR/Health4AI.xcodeproj/project.pbxproj"

if ! grep -q 'CURRENT_PROJECT_VERSION = [0-9]' "$PBXPROJ"; then
  echo "Could not find a numeric CURRENT_PROJECT_VERSION in $PBXPROJ" >&2
  exit 65
fi

echo "Stamping Health4AI build number: $BUILD_NUMBER"
sed -i '' "s/CURRENT_PROJECT_VERSION = [0-9]*/CURRENT_PROJECT_VERSION = $BUILD_NUMBER/g" "$PBXPROJ"
