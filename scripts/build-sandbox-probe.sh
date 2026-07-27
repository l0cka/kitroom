#!/bin/sh

set -eu

kitroom_probe_root=".build/sandbox-probe"
kitroom_probe_app="$kitroom_probe_root/KitroomSandboxProbe.app"
kitroom_probe_contents="$kitroom_probe_app/Contents"
kitroom_probe_macos="$kitroom_probe_contents/MacOS"
kitroom_probe_arch="$(uname -m)"

rm -rf "$kitroom_probe_app"
mkdir -p "$kitroom_probe_macos"

xcrun swiftc \
    -parse-as-library \
    -target "${kitroom_probe_arch}-apple-macos14.0" \
    Tests/SandboxProbe/SandboxProbeApp.swift \
    -o "$kitroom_probe_macos/KitroomSandboxProbe"

cp Tests/SandboxProbe/Info.plist "$kitroom_probe_contents/Info.plist"

codesign \
    --force \
    --sign - \
    --entitlements Tests/SandboxProbe/KitroomSandboxProbe.entitlements \
    "$kitroom_probe_app"

codesign --verify --deep --strict "$kitroom_probe_app"
codesign --display --entitlements - "$kitroom_probe_app"

printf '%s\n' "$kitroom_probe_app"
