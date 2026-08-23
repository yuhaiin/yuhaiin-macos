#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BUILD_DIR="$ROOT_DIR/build"
APP="$BUILD_DIR/Yuhaiin.app"

swift build --configuration release
ARM_BIN_DIR=$(swift build --configuration release --show-bin-path)
swift build --configuration release --triple x86_64-apple-macosx13.0
X86_BIN_DIR=$(swift build --configuration release --triple x86_64-apple-macosx13.0 --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Library/LaunchDaemons" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

lipo -create "$ARM_BIN_DIR/YuhaiinMacOS" "$X86_BIN_DIR/YuhaiinMacOS" -output "$APP/Contents/MacOS/YuhaiinMacOS"
lipo -create "$ARM_BIN_DIR/YuhaiinSupervisor" "$X86_BIN_DIR/YuhaiinSupervisor" -output "$APP/Contents/MacOS/YuhaiinSupervisor"
cp "$ROOT_DIR/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
for localization in en ja ko; do
    cp -R "$ROOT_DIR/Resources/$localization.lproj" "$APP/Contents/Resources/"
done

if [ -n "${YUHAIIN_APPCAST_URL:-}" ]; then
    plutil -replace SUFeedURL -string "$YUHAIIN_APPCAST_URL" "$APP/Contents/Info.plist"
fi

if [ -n "${YUHAIIN_SPARKLE_PUBLIC_KEY:-}" ]; then
    plutil -replace SUPublicEDKey -string "$YUHAIIN_SPARKLE_PUBLIC_KEY" "$APP/Contents/Info.plist"
fi

if [ -n "${YUHAIIN_APPCAST_URL:-}" ] && [ -n "${YUHAIIN_SPARKLE_PUBLIC_KEY:-}" ]; then
    plutil -replace SUEnableAutomaticChecks -bool true "$APP/Contents/Info.plist"
fi

SUPERVISOR_PLIST="$APP/Contents/Library/LaunchDaemons/com.asutorufa.yuhaiin.supervisor.plist"
cp "$ROOT_DIR/Resources/com.asutorufa.yuhaiin.supervisor.plist" "$SUPERVISOR_PLIST"

if [ -n "${YUHAIIN_TEAM_ID:-}" ]; then
    requirement="identifier \"com.asutorufa.yuhaiin.macos\" and certificate leaf[subject.OU] = \"$YUHAIIN_TEAM_ID\""
    binary_requirement="anchor apple generic and certificate leaf[subject.OU] = \"$YUHAIIN_TEAM_ID\""
    if plutil -type EnvironmentVariables "$SUPERVISOR_PLIST" >/dev/null 2>&1; then
        plutil -replace EnvironmentVariables.YUHAIIN_CLIENT_CODE_REQUIREMENT -string "$requirement" "$SUPERVISOR_PLIST"
        plutil -replace EnvironmentVariables.YUHAIIN_BINARY_CODE_REQUIREMENT -string "$binary_requirement" "$SUPERVISOR_PLIST"
    else
        plutil -insert EnvironmentVariables -dictionary "$SUPERVISOR_PLIST"
        plutil -insert EnvironmentVariables.YUHAIIN_CLIENT_CODE_REQUIREMENT -string "$requirement" "$SUPERVISOR_PLIST"
        plutil -insert EnvironmentVariables.YUHAIIN_BINARY_CODE_REQUIREMENT -string "$binary_requirement" "$SUPERVISOR_PLIST"
    fi
fi

SPARKLE_FRAMEWORK="$ARM_BIN_DIR/Sparkle.framework"
if [ -d "$SPARKLE_FRAMEWORK" ]; then
    cp -R "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/YuhaiinMacOS"
else
    echo "error: Sparkle.framework was not produced by SwiftPM" >&2
    exit 1
fi

if [ "${YUHAIIN_ARM64+x}" = x ]; then
    YUHAIIN_ARM64_EXPLICIT=1
else
    YUHAIIN_ARM64_EXPLICIT=0
    YUHAIIN_ARM64="$ROOT_DIR/../yuhaiin/yuhaiin_darwin_arm64"
fi
if [ "${YUHAIIN_AMD64+x}" = x ]; then
    YUHAIIN_AMD64_EXPLICIT=1
else
    YUHAIIN_AMD64_EXPLICIT=0
    YUHAIIN_AMD64="$ROOT_DIR/../yuhaiin/yuhaiin_darwin_amd64"
fi
YUHAIIN_SOURCE_DIR=${YUHAIIN_SOURCE_DIR:-"$ROOT_DIR/../yuhaiin"}
YUHAIIN_GO_BUILD_TAGS=${YUHAIIN_GO_BUILD_TAGS:-"untested_go_version"}
YUHAIIN_BUILD_FROM_SOURCE=${YUHAIIN_BUILD_FROM_SOURCE:-1}

build_missing_yuhaiin() {
    architecture=$1
    output=$2
    explicit=0
    if [ "$architecture" = "arm64" ]; then
        explicit=$YUHAIIN_ARM64_EXPLICIT
    else
        explicit=$YUHAIIN_AMD64_EXPLICIT
    fi
    if [ "$explicit" = "1" ] || [ "$YUHAIIN_BUILD_FROM_SOURCE" != "1" ] || [ ! -f "$YUHAIIN_SOURCE_DIR/go.mod" ] || ! command -v go >/dev/null 2>&1; then
        return 0
    fi
    generated="$BUILD_DIR/yuhaiin-darwin-$architecture"
    echo "building missing yuhaiin $architecture binary"
    if (cd "$YUHAIIN_SOURCE_DIR" && GOOS=darwin GOARCH="$architecture" CGO_ENABLED=0 go build -tags="$YUHAIIN_GO_BUILD_TAGS" -o "$generated" ./cmd/yuhaiin); then
        if [ "$architecture" = "arm64" ]; then
            YUHAIIN_ARM64="$generated"
        else
            YUHAIIN_AMD64="$generated"
        fi
    else
        rm -f "$generated"
        echo "warning: unable to build yuhaiin $architecture binary" >&2
    fi
}

build_missing_yuhaiin arm64 "$YUHAIIN_ARM64"
build_missing_yuhaiin amd64 "$YUHAIIN_AMD64"

if [ -f "$YUHAIIN_ARM64" ]; then
    cp "$YUHAIIN_ARM64" "$APP/Contents/Resources/yuhaiin-darwin-arm64"
    chmod 755 "$APP/Contents/Resources/yuhaiin-darwin-arm64"
else
    echo "warning: arm64 yuhaiin binary not found; set YUHAIIN_ARM64 to embed it" >&2
fi

if [ -f "$YUHAIIN_AMD64" ]; then
    cp "$YUHAIIN_AMD64" "$APP/Contents/Resources/yuhaiin-darwin-amd64"
    chmod 755 "$APP/Contents/Resources/yuhaiin-darwin-amd64"
else
    echo "warning: x86_64 yuhaiin binary not found; set YUHAIIN_AMD64 to embed it" >&2
fi

if command -v codesign >/dev/null 2>&1; then
    CODESIGN_IDENTITY=${CODESIGN_IDENTITY:--}
    for yuhaiin_binary in "$APP/Contents/Resources/yuhaiin-darwin-arm64" "$APP/Contents/Resources/yuhaiin-darwin-amd64"; do
        if [ -f "$yuhaiin_binary" ]; then
            codesign --force --sign "$CODESIGN_IDENTITY" "$yuhaiin_binary"
        fi
    done
    codesign --force --deep --sign "$CODESIGN_IDENTITY" "$APP"
fi

echo "built $APP"
