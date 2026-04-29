#!/bin/bash
set -e

OUTPUT_DIR=${1:-"$(pwd)"}
SOURCE_REPO="https://github.com/xiph/opus.git"
SOURCE_VERSION="v1.6.1"
SOURCE_DIR="$(pwd)/opus-source"
BUILD_ROOT="$(pwd)/build_opus_framework"

DEPLOYMENT_IOS=${DEPLOYMENT_IOS:-"12.0"}
DEPLOYMENT_TVOS=${DEPLOYMENT_TVOS:-"12.0"}
DEPLOYMENT_WATCHOS=${DEPLOYMENT_WATCHOS:-"6.0"}
DEPLOYMENT_MACOS=${DEPLOYMENT_MACOS:-"10.11"}
DEPLOYMENT_VISIONOS=${DEPLOYMENT_VISIONOS:-"1.0"}

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

for tool in git autoconf automake libtool lipo xcodebuild xcrun; do
    command -v $tool &>/dev/null || error "缺少工具: $tool"
done

# 准备源码
if [ -d "$SOURCE_DIR" ]; then
    cd "$SOURCE_DIR"
    git fetch --all
    git reset --hard origin/main 2>/dev/null || git reset --hard origin/master
    cd - >/dev/null
else
    git clone -b "$SOURCE_VERSION" "$SOURCE_REPO" "$SOURCE_DIR"
fi

cd "$SOURCE_DIR"
if [ ! -f "configure" ]; then
    ./autogen.sh
fi
cd - >/dev/null

rm -rf "$BUILD_ROOT"
mkdir -p "$BUILD_ROOT"

CONFIG_COMMON="--disable-shared --enable-static --disable-asm"

# 任务列表: 子目录|SDK|架构|最低版本|版本标志
declare -a TASKS=(
    "ios_device|iphoneos|arm64|$DEPLOYMENT_IOS|-miphoneos-version-min="
    "ios_simulator_x86_64|iphonesimulator|x86_64|$DEPLOYMENT_IOS|-mios-simulator-version-min="
    "ios_simulator_arm64|iphonesimulator|arm64|$DEPLOYMENT_IOS|-mios-simulator-version-min="
    "macos_x86_64|macosx|x86_64|$DEPLOYMENT_MACOS|-mmacosx-version-min="
    "macos_arm64|macosx|arm64|$DEPLOYMENT_MACOS|-mmacosx-version-min="
    "tvos_device|appletvos|arm64|$DEPLOYMENT_TVOS|-mtvos-version-min="
    "tvos_simulator_x86_64|appletvsimulator|x86_64|$DEPLOYMENT_TVOS|-mtvos-simulator-version-min="
    "tvos_simulator_arm64|appletvsimulator|arm64|$DEPLOYMENT_TVOS|-mtvos-simulator-version-min="
    "watchos_device|watchos|arm64_32|$DEPLOYMENT_WATCHOS|-mwatchos-version-min="
    "watchos_simulator_x86_64|watchsimulator|x86_64|$DEPLOYMENT_WATCHOS|-mwatchos-simulator-version-min="
    "watchos_simulator_arm64|watchsimulator|arm64|$DEPLOYMENT_WATCHOS|-mwatchos-simulator-version-min="
)

if xcrun --sdk xros --show-sdk-path &>/dev/null; then
    TASKS+=(
        "visionos_device|xros|arm64|$DEPLOYMENT_VISIONOS|-mxros-version-min="
        "visionos_simulator_x86_64|xrsimulator|x86_64|$DEPLOYMENT_VISIONOS|-mxros-simulator-version-min="
        "visionos_simulator_arm64|xrsimulator|arm64|$DEPLOYMENT_VISIONOS|-mxros-simulator-version-min="
    )
fi

build_one() {
    local SUBDIR="$1" SDK="$2" ARCH="$3" MIN_VERSION="$4" VERSION_FLAG="$5"
    info "编译: $SUBDIR ($SDK, $ARCH)"
    local DEST_DIR="$BUILD_ROOT/$SUBDIR"
    mkdir -p "$DEST_DIR"

    pushd "$SOURCE_DIR" >/dev/null
    make distclean 2>/dev/null || true

    local SYSROOT=$(xcrun --sdk $SDK --show-sdk-path)
    local CLANG=$(xcrun --sdk $SDK --find clang)

    local TARGET=""
    case "$SDK" in
        iphoneos)            TARGET="${ARCH}-apple-ios${MIN_VERSION}" ;;
        iphonesimulator)     TARGET="${ARCH}-apple-ios${MIN_VERSION}-simulator" ;;
        macosx)              TARGET="${ARCH}-apple-macos${MIN_VERSION}" ;;
        appletvos)           TARGET="${ARCH}-apple-tvos${MIN_VERSION}" ;;
        appletvsimulator)    TARGET="${ARCH}-apple-tvos${MIN_VERSION}-simulator" ;;
        watchos)             TARGET="${ARCH}-apple-watchos${MIN_VERSION}" ;;
        watchsimulator)      TARGET="${ARCH}-apple-watchos${MIN_VERSION}-simulator" ;;
        xros)                TARGET="${ARCH}-apple-xros${MIN_VERSION}" ;;
        xrsimulator)         TARGET="${ARCH}-apple-xros${MIN_VERSION}-simulator" ;;
        *) error "未知 SDK: $SDK" ;;
    esac

    CFLAGS="-target $TARGET -isysroot $SYSROOT"
    LDFLAGS="-isysroot $SYSROOT"

    ./configure $CONFIG_COMMON \
        --prefix="$DEST_DIR" \
        CC="$CLANG" \
        CFLAGS="$CFLAGS" \
        LDFLAGS="$LDFLAGS" \
        ac_cv_exeext= \
        ac_cv_prog_cc_cross=yes \
        cross_compiling=yes

    make -j$(sysctl -n hw.ncpu)
    make install
    popd >/dev/null
}

for TASK in "${TASKS[@]}"; do
    IFS='|' read -r SUBDIR SDK ARCH MIN_VERSION VERSION_FLAG <<< "$TASK"
    build_one "$SUBDIR" "$SDK" "$ARCH" "$MIN_VERSION" "$VERSION_FLAG"
done

# 转换为 framework，并修正头文件目录层级
convert_to_framework() {
    local SLICE_DIR="$1"
    local FRAMEWORK_NAME="opus.framework"
    local FRAMEWORK_DIR="$SLICE_DIR/$FRAMEWORK_NAME"
    local HEADERS_SRC="$SLICE_DIR/include"
    local HEADERS_DST="$FRAMEWORK_DIR/Headers"
    local MODULES_DIR="$FRAMEWORK_DIR/Modules"

    if [ ! -d "$HEADERS_SRC" ]; then
        info "警告: $HEADERS_SRC 不存在，跳过 $SLICE_DIR"
        return
    fi

    mkdir -p "$HEADERS_DST" "$MODULES_DIR"

    # 复制头文件：如果存在 include/opus/ 子目录，则将其内容提升到 Headers 根目录
    if [ -d "$HEADERS_SRC/opus" ]; then
        cp -r "$HEADERS_SRC/opus"/* "$HEADERS_DST/"
    else
        cp -r "$HEADERS_SRC"/* "$HEADERS_DST/"
    fi

    # 创建 module.modulemap
    cat > "$MODULES_DIR/module.modulemap" <<EOF
framework module opus {
    umbrella header "opus.h"
    export *
    module * { export * }
}
EOF

    # 移动静态库
    if [ -f "$SLICE_DIR/lib/libopus.a" ]; then
        mv "$SLICE_DIR/lib/libopus.a" "$FRAMEWORK_DIR/opus"
    elif [ -f "$SLICE_DIR/libopus.a" ]; then
        mv "$SLICE_DIR/libopus.a" "$FRAMEWORK_DIR/opus"
    else
        error "未找到 libopus.a 在 $SLICE_DIR"
    fi

    # 生成 Info.plist
    cat > "$FRAMEWORK_DIR/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>opus</string>
    <key>CFBundleIdentifier</key>
    <string>org.xiph.opus</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>opus</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
</dict>
</plist>
EOF

    rm -rf "$SLICE_DIR/include" "$SLICE_DIR/lib" 2>/dev/null || true
    info "已创建 framework: $FRAMEWORK_DIR"
}

for sub in ios_device ios_simulator_x86_64 ios_simulator_arm64 \
           macos_x86_64 macos_arm64 \
           tvos_device tvos_simulator_x86_64 tvos_simulator_arm64 \
           watchos_device watchos_simulator_x86_64 watchos_simulator_arm64; do
    [ -d "$BUILD_ROOT/$sub" ] && convert_to_framework "$BUILD_ROOT/$sub"
done

if xcrun --sdk xros --show-sdk-path &>/dev/null; then
    for sub in visionos_device visionos_simulator_x86_64 visionos_simulator_arm64; do
        [ -d "$BUILD_ROOT/$sub" ] && convert_to_framework "$BUILD_ROOT/$sub"
    done
fi

# 合并模拟器 fat framework
merge_simulator_fat() {
    local platform=$1
    local dir_x86="$BUILD_ROOT/${platform}_simulator_x86_64/opus.framework"
    local dir_arm="$BUILD_ROOT/${platform}_simulator_arm64/opus.framework"
    local dir_fat="$BUILD_ROOT/${platform}_simulator_fat"
    local fat_framework="$dir_fat/opus.framework"

    if [ ! -d "$dir_x86" ] || [ ! -d "$dir_arm" ]; then
        return
    fi

    mkdir -p "$fat_framework"
    lipo -create "$dir_x86/opus" "$dir_arm/opus" -output "$fat_framework/opus"
    cp -r "$dir_x86/Headers" "$fat_framework/"
    cp -r "$dir_x86/Modules" "$fat_framework/"
    cp "$dir_x86/Info.plist" "$fat_framework/"
    info "合并模拟器 fat framework: $platform"
}

merge_simulator_fat "ios"
merge_simulator_fat "tvos"
merge_simulator_fat "watchos"
if xcrun --sdk xros --show-sdk-path &>/dev/null; then
    merge_simulator_fat "visionos"
fi

# 合并 macOS fat framework
if [ -d "$BUILD_ROOT/macos_x86_64/opus.framework" ] && [ -d "$BUILD_ROOT/macos_arm64/opus.framework" ]; then
    MACOS_COMBINED="$BUILD_ROOT/macos_combined"
    FAT_FRAMEWORK="$MACOS_COMBINED/opus.framework"
    mkdir -p "$FAT_FRAMEWORK"
    lipo -create "$BUILD_ROOT/macos_x86_64/opus.framework/opus" \
                 "$BUILD_ROOT/macos_arm64/opus.framework/opus" \
         -output "$FAT_FRAMEWORK/opus"
    cp -r "$BUILD_ROOT/macos_x86_64/opus.framework/Headers" "$FAT_FRAMEWORK/"
    cp -r "$BUILD_ROOT/macos_x86_64/opus.framework/Modules" "$FAT_FRAMEWORK/"
    cp "$BUILD_ROOT/macos_x86_64/opus.framework/Info.plist" "$FAT_FRAMEWORK/"
    info "合并 macOS fat framework"
fi

# 生成 XCFramework
XCFRAMEWORK_PATH="$OUTPUT_DIR/opus.xcframework"
rm -rf "$XCFRAMEWORK_PATH"
XCF_ARGS=()

add_slice() {
    local framework_dir="$1"
    if [ -d "$framework_dir" ]; then
        XCF_ARGS+=(-framework "$framework_dir")
    else
        info "警告: 跳过缺失切片 $framework_dir"
    fi
}

add_slice "$BUILD_ROOT/ios_device/opus.framework"
add_slice "$BUILD_ROOT/ios_simulator_fat/opus.framework"

if [ -d "$BUILD_ROOT/macos_combined/opus.framework" ]; then
    add_slice "$BUILD_ROOT/macos_combined/opus.framework"
fi

add_slice "$BUILD_ROOT/tvos_device/opus.framework"
add_slice "$BUILD_ROOT/tvos_simulator_fat/opus.framework"
add_slice "$BUILD_ROOT/watchos_device/opus.framework"
add_slice "$BUILD_ROOT/watchos_simulator_fat/opus.framework"

if xcrun --sdk xros --show-sdk-path &>/dev/null; then
    add_slice "$BUILD_ROOT/visionos_device/opus.framework"
    add_slice "$BUILD_ROOT/visionos_simulator_fat/opus.framework"
fi

xcodebuild -create-xcframework ${XCF_ARGS[@]} -output "$XCFRAMEWORK_PATH"

read -p "是否删除临时构建目录 $BUILD_ROOT ? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    rm -rf "$BUILD_ROOT"
    info "已删除临时目录"
else
    info "临时目录保留: $BUILD_ROOT"
fi

info "✅ 已生成正确层级的 opus.xcframework: $XCFRAMEWORK_PATH"