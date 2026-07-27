#!/bin/sh

set -eu

swift build
swift test
./scripts/build-sandbox-probe.sh

kitroom_derived_data="$(mktemp -d "${TMPDIR:-/tmp}/kitroom-verify.XXXXXX")"
trap 'rm -rf "$kitroom_derived_data"' EXIT HUP INT TERM

for kitroom_configuration in Debug Test
do
    xcodebuild \
        -quiet \
        -project Kitroom.xcodeproj \
        -scheme Kitroom \
        -configuration "$kitroom_configuration" \
        -destination "generic/platform=macOS" \
        -derivedDataPath "$kitroom_derived_data" \
        CODE_SIGNING_ALLOWED=NO \
        build
done
