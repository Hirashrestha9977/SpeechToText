#!/bin/bash
# Builds VoiceToText.xcframework (device + simulator) into ./build.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
BUILD="$ROOT/build"
SCHEME="VoiceToTextDynamic"
NAME="VoiceToText"

rm -rf "$BUILD"
mkdir -p "$BUILD"

archive() {
    local destination="$1" archive_path="$2"
    xcodebuild archive \
        -scheme "$SCHEME" \
        -destination "$destination" \
        -archivePath "$archive_path" \
        -derivedDataPath "$BUILD/DerivedData" \
        SKIP_INSTALL=NO \
        BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
        | xcpretty 2>/dev/null || true

    # SwiftPM archives omit the Swift module; copy it in from the build products.
    local sdk="$3"
    local framework
    framework="$(find "$archive_path/Products" -name "$SCHEME.framework" -maxdepth 5 | head -1)"
    if [ -z "$framework" ]; then
        echo "error: $SCHEME.framework not found in $archive_path" >&2
        exit 1
    fi
    local modules="$framework/Modules"
    mkdir -p "$modules"
    local swiftmodule
    swiftmodule="$(find "$BUILD/DerivedData/Build/Intermediates.noindex/ArchiveIntermediates/$SCHEME/BuildProductsPath/Release-$sdk" \
        -name "$NAME.swiftmodule" -maxdepth 1 | head -1)"
    cp -R "$swiftmodule" "$modules/"
}

archive "generic/platform=iOS" "$BUILD/ios.xcarchive" "iphoneos"
archive "generic/platform=iOS Simulator" "$BUILD/ios-simulator.xcarchive" "iphonesimulator"

# Rename VoiceToTextDynamic.framework to VoiceToText.framework so apps `import VoiceToText`.
for archive_path in "$BUILD/ios.xcarchive" "$BUILD/ios-simulator.xcarchive"; do
    src="$(find "$archive_path/Products" -name "$SCHEME.framework" -maxdepth 5 | head -1)"
    dst="$BUILD/$(basename "$archive_path" .xcarchive)/$NAME.framework"
    mkdir -p "$(dirname "$dst")"
    cp -R "$src" "$dst"
    mv "$dst/$SCHEME" "$dst/$NAME"
    install_name_tool -id "@rpath/$NAME.framework/$NAME" "$dst/$NAME"
    plutil -replace CFBundleExecutable -string "$NAME" "$dst/Info.plist"
    plutil -replace CFBundleName -string "$NAME" "$dst/Info.plist"
    plutil -replace CFBundleIdentifier -string "com.voicetotext.$NAME" "$dst/Info.plist"
    codesign --force --sign - "$dst" >/dev/null 2>&1 || true
done

xcodebuild -create-xcframework \
    -framework "$BUILD/ios/$NAME.framework" \
    -framework "$BUILD/ios-simulator/$NAME.framework" \
    -output "$BUILD/$NAME.xcframework"

echo "Built $BUILD/$NAME.xcframework"
