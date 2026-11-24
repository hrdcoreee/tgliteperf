#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${OUT_DIR:-$SCRIPT_DIR/build}"
SDK_PATH="${SDK_PATH:-}"
LDID_BIN="${LDID_BIN:-$(command -v ldid || true)}"
VERSION="${VERSION:-1.0.0}"

mkdir -p "$OUT_DIR"

OS_NAME="$(uname -s)"
if [ "$OS_NAME" = "Darwin" ]; then
    CC="xcrun -sdk iphoneos clang"
    SDK_PATH="${SDK_PATH:-$(xcrun --sdk iphoneos --show-sdk-path)}"
    LD_FLAGS=""
else
    CC="${CC:-clang}"
    LD_FLAGS="-fuse-ld=lld -Wl,-platform_version,ios,15.0,16.5"
    if [ -z "$SDK_PATH" ]; then
        echo "ERROR: Set SDK_PATH to your extracted iPhoneOS*.sdk directory."
        exit 1
    fi
fi

echo "==> Building TGLitePerf.dylib using SDK: $SDK_PATH"
$CC \
    -target arm64-apple-ios15.0 \
    -isysroot "$SDK_PATH" \
    -O2 \
    -Wall \
    -fobjc-arc \
    -dynamiclib \
    -install_name "@rpath/TGLitePerf.dylib" \
    $LD_FLAGS \
    -F"$SDK_PATH/System/Library/Frameworks" \
    -L"$SDK_PATH/usr/lib" \
    -framework Foundation \
    -framework UIKit \
    -framework QuartzCore \
    -framework AVFoundation \
    -lobjc \
    "$SCRIPT_DIR/fishhook.c" \
    "$SCRIPT_DIR/TGLitePerfSettings.m" \
    "$SCRIPT_DIR/TGLitePerfPrefsController.m" \
    "$SCRIPT_DIR/TGLitePerf.m" \
    -o "$OUT_DIR/TGLitePerf.dylib"

if [ -n "$LDID_BIN" ]; then
    echo "==> Ad-hoc signing TGLitePerf.dylib with $LDID_BIN"
    "$LDID_BIN" -S "$OUT_DIR/TGLitePerf.dylib"
elif [ "$OS_NAME" = "Darwin" ]; then
    codesign -f -s - "$OUT_DIR/TGLitePerf.dylib"
else
    echo "WARNING: ldid not found; TGLitePerf.dylib is unsigned."
fi

if command -v dpkg-deb >/dev/null 2>&1; then
    build_deb() {
        local ARCH="$1"
        local PREFIX="$2"
        local SUFFIX="$3"
        local STAGE="$OUT_DIR/pkg-$SUFFIX"
        rm -rf "$STAGE"
        mkdir -p "$STAGE/DEBIAN" "$STAGE$PREFIX/Library/MobileSubstrate/DynamicLibraries"
        cp "$OUT_DIR/TGLitePerf.dylib" "$STAGE$PREFIX/Library/MobileSubstrate/DynamicLibraries/TGLitePerf.dylib"
        cp "$SCRIPT_DIR/TGLitePerf.plist" "$STAGE$PREFIX/Library/MobileSubstrate/DynamicLibraries/TGLitePerf.plist"

        cat > "$STAGE/DEBIAN/control" <<EOF
Package: com.hrdcoreee.tgliteperf
Name: TGLitePerf
Version: $VERSION
Architecture: $ARCH
Description: Performance & battery tweak for Telegram/Swiftgram on older iPhones (disables heavy blur/glass, throttles emitters, disables live gallery camera, 30fps emoji).
Maintainer: hrdcoreee
Author: hrdcoreee
Section: Tweaks
EOF
        dpkg-deb --root-owner-group -Zgzip -b "$STAGE" "$OUT_DIR/com.hrdcoreee.tgliteperf_${VERSION}_${SUFFIX}.deb"
        rm -rf "$STAGE"
    }

    build_deb "iphoneos-arm64" "/var/jb" "rootless"
    build_deb "iphoneos-arm" "" "rootful"
fi

echo "==> Done! Artifacts in $OUT_DIR:"
ls -lh "$OUT_DIR"
