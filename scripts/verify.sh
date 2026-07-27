#!/bin/sh

set -eu

swift build
swift test

kitroom_derived_data="$(mktemp -d "${TMPDIR:-/tmp}/kitroom-verify.XXXXXX")"
trap 'rm -rf "$kitroom_derived_data"' EXIT HUP INT TERM

xcodebuild \
    -quiet \
    -project Kitroom.xcodeproj \
    -scheme Kitroom \
    -configuration Debug \
    -destination "generic/platform=macOS" \
    -derivedDataPath "$kitroom_derived_data" \
    CODE_SIGNING_ALLOWED=NO \
    build
