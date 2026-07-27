#!/bin/sh

set -eu

if [ -z "${KITROOM_SIGNING_IDENTITY:-}" ]; then
    printf '%s\n' \
        "KITROOM_SIGNING_IDENTITY must name a Developer ID Application identity." >&2
    exit 2
fi

if [ -z "${KITROOM_NOTARY_PROFILE:-}" ]; then
    printf '%s\n' \
        "KITROOM_NOTARY_PROFILE must name a notarytool Keychain profile." >&2
    exit 2
fi

case "$KITROOM_SIGNING_IDENTITY" in
    "Developer ID Application: "*)
        ;;
    *)
        printf '%s\n' \
            "The signing identity must begin with 'Developer ID Application: '." >&2
        exit 2
        ;;
esac

if ! security find-identity -v -p codesigning \
    | grep -Fq "\"$KITROOM_SIGNING_IDENTITY\""
then
    printf '%s\n' \
        "The requested Developer ID Application identity is not available." >&2
    exit 2
fi

kitroom_script_dir=$(
    CDPATH= cd -- "$(dirname -- "$0")" >/dev/null 2>&1
    pwd
)
kitroom_repo_root=$(
    CDPATH= cd -- "$kitroom_script_dir/.." >/dev/null 2>&1
    pwd
)
kitroom_build_root=$(mktemp -d "${TMPDIR:-/tmp}/kitroom-release.XXXXXX")
kitroom_app="$kitroom_build_root/Build/Products/Release/Kitroom.app"

kitroom_cleanup() {
    rm -rf "$kitroom_build_root"
}
trap kitroom_cleanup EXIT HUP INT TERM

cd "$kitroom_repo_root"

./scripts/verify.sh

xcodebuild \
    -quiet \
    -project Kitroom.xcodeproj \
    -scheme Kitroom \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -derivedDataPath "$kitroom_build_root" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGNING_REQUIRED=YES \
    CODE_SIGN_IDENTITY="$KITROOM_SIGNING_IDENTITY" \
    OTHER_CODE_SIGN_FLAGS="--timestamp"

if [ ! -d "$kitroom_app" ]; then
    printf '%s\n' "Release build did not produce Kitroom.app." >&2
    exit 1
fi

codesign --verify --deep --strict --verbose=2 "$kitroom_app"

kitroom_authority=$(
    codesign --display --verbose=4 "$kitroom_app" 2>&1 \
        | sed -n 's/^Authority=//p' \
        | head -n 1
)
if [ "$kitroom_authority" != "$KITROOM_SIGNING_IDENTITY" ]; then
    printf '%s\n' "Release app is not signed by the requested identity." >&2
    exit 1
fi

kitroom_version=$(
    /usr/libexec/PlistBuddy \
        -c "Print :CFBundleShortVersionString" \
        "$kitroom_app/Contents/Info.plist"
)
kitroom_build=$(
    /usr/libexec/PlistBuddy \
        -c "Print :CFBundleVersion" \
        "$kitroom_app/Contents/Info.plist"
)
kitroom_archive_name="Kitroom-${kitroom_version}-${kitroom_build}.zip"
kitroom_submission="$kitroom_build_root/$kitroom_archive_name"
kitroom_dist="$kitroom_repo_root/dist"
kitroom_archive="$kitroom_dist/$kitroom_archive_name"

mkdir -p "$kitroom_dist"
if [ -e "$kitroom_archive" ]; then
    printf '%s\n' \
        "Refusing to overwrite existing release archive: $kitroom_archive" >&2
    exit 2
fi

ditto -c -k --keepParent "$kitroom_app" "$kitroom_submission"

xcrun notarytool submit \
    "$kitroom_submission" \
    --keychain-profile "$KITROOM_NOTARY_PROFILE" \
    --wait

xcrun stapler staple "$kitroom_app"
xcrun stapler validate "$kitroom_app"
codesign --verify --deep --strict --verbose=2 "$kitroom_app"
spctl --assess --type execute --verbose=4 "$kitroom_app"

ditto -c -k --keepParent "$kitroom_app" "$kitroom_archive"

printf '%s\n' "Release archive:"
printf '  %s\n' "$kitroom_archive"
printf '%s\n' "SHA-256:"
shasum -a 256 "$kitroom_archive"
