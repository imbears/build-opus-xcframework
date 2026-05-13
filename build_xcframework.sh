#!/usr/bin/env bash
# =============================================================================
# build_xcframework.sh
# 将 Opus C 库打包为支持 Apple 全平台的 XCFramework
#
# 支持平台:
#   - iOS              (arm64)
#   - iOS Simulator    (arm64 + x86_64, fat binary)
#   - macOS            (arm64 + x86_64, fat binary)
#   - tvOS             (arm64)
#   - tvOS Simulator   (arm64 + x86_64, fat binary)
#   - watchOS          (arm64_32 + armv7k)
#   - watchOS Simulator(arm64 + x86_64, fat binary)
#   - visionOS         (arm64)
#   - visionOS Simulator(arm64 + x86_64, fat binary)
#
# 用法:
#   将此文件放到opus根目录下
#   chmod +x build_xcframework.sh
#   ./build_xcframework.sh [选项]
#
# 选项:
#   --output <dir>           输出目录 (默认: ./output)
#   --build  <dir>           构建临时目录 (默认: ./build_tmp)
#   --config <Release|Debug> 构建配置 (默认: Release)
#   --no-clean               构建完成后不清理临时目录
#   --skip-visionos          跳过 visionOS 构建（Xcode < 15 时使用）
#   --help                   显示帮助信息
# =============================================================================

set -eo pipefail

# ─── 颜色输出 ────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()    {
    echo -e "\n${CYAN}══════════════════════════════════════════${NC}"
    echo -e "${CYAN}  $*${NC}"
    echo -e "${CYAN}══════════════════════════════════════════${NC}"
}

# ─── 默认参数 ────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/output"
BUILD_DIR="${SCRIPT_DIR}/build_tmp"
BUILD_CONFIG="Release"
CLEAN_BUILD=true
SKIP_VISIONOS=false
FRAMEWORK_NAME="Opus"
BUNDLE_ID="org.xiph.opus"
OPUS_VERSION="1.5.2"

# ─── 解析参数 ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output)        OUTPUT_DIR="$2";   shift 2 ;;
        --build)         BUILD_DIR="$2";    shift 2 ;;
        --config)        BUILD_CONFIG="$2"; shift 2 ;;
        --no-clean)      CLEAN_BUILD=false; shift   ;;
        --skip-visionos) SKIP_VISIONOS=true; shift  ;;
        --help)
            head -30 "$0" | grep '^#' | sed 's/^# \{0,2\}//'
            exit 0
            ;;
        *) log_error "未知参数: $1"; exit 1 ;;
    esac
done

# ─── 环境检查 ────────────────────────────────────────────────────────────────
check_requirements() {
    log_step "检查构建环境"

    if [[ "$(uname)" != "Darwin" ]]; then
        log_error "此脚本只能在 macOS 上运行"
        exit 1
    fi

    if ! command -v xcodebuild &>/dev/null; then
        log_error "未找到 xcodebuild，请安装 Xcode 或 Xcode Command Line Tools"
        exit 1
    fi

    if ! command -v cmake &>/dev/null; then
        log_error "未找到 cmake，请通过 'brew install cmake' 安装"
        exit 1
    fi

    if ! command -v lipo &>/dev/null; then
        log_error "未找到 lipo 工具"
        exit 1
    fi

    local xcode_version xcode_major
    xcode_version=$(xcodebuild -version 2>/dev/null | head -1 | awk '{print $2}')
    xcode_major=$(echo "$xcode_version" | cut -d. -f1)

    log_info "Xcode 版本: $xcode_version"
    log_info "cmake 版本: $(cmake --version | head -1)"

    # visionOS 需要 Xcode 15+
    if [[ "$SKIP_VISIONOS" == "false" ]] && [[ "$xcode_major" -lt 15 ]]; then
        log_warn "Xcode < 15，自动跳过 visionOS 构建"
        SKIP_VISIONOS=true
    fi

    log_success "环境检查通过"
}

# ─── 获取 SDK 路径 ────────────────────────────────────────────────────────────
get_sdk_path() {
    xcrun --sdk "$1" --show-sdk-path 2>/dev/null || true
}

# ─── 单架构 cmake 构建 ────────────────────────────────────────────────────────
# 用法:
#   build_single_arch <platform_id> <cmake_system> <sdk_name> <arch> <c_flags_extra>
#
# c_flags_extra: 附加到 CMAKE_C_FLAGS 的字符串，例如 "-miphoneos-version-min=13.0"
#                对于 visionOS 使用 "-target arm64-apple-xros1.0"
build_single_arch() {
    local platform_id="$1"    # 例: ios-arm64
    local cmake_system="$2"   # 例: iOS
    local sdk_name="$3"       # 例: iphoneos
    local arch="$4"           # 例: arm64
    local c_flags_extra="$5"  # 例: -miphoneos-version-min=13.0

    local build_subdir="${BUILD_DIR}/${platform_id}"
    local install_dir="${BUILD_DIR}/install/${platform_id}"

    log_info "构建 ${platform_id} ..."

    local sdk_path
    sdk_path=$(get_sdk_path "$sdk_name")
    if [[ -z "$sdk_path" ]]; then
        log_warn "SDK '$sdk_name' 不存在，跳过 ${platform_id}"
        return 1
    fi

    mkdir -p "$build_subdir" "$install_dir"

    local c_flags="-arch ${arch} ${c_flags_extra}"

    cmake -S "$SCRIPT_DIR" \
          -B "$build_subdir" \
          -G "Unix Makefiles" \
          -DCMAKE_BUILD_TYPE="${BUILD_CONFIG}" \
          -DCMAKE_SYSTEM_NAME="${cmake_system}" \
          -DCMAKE_OSX_ARCHITECTURES="${arch}" \
          -DCMAKE_OSX_SYSROOT="${sdk_path}" \
          -DCMAKE_C_FLAGS="${c_flags}" \
          -DCMAKE_CXX_FLAGS="${c_flags}" \
          -DCMAKE_INSTALL_PREFIX="${install_dir}" \
          -DOPUS_BUILD_SHARED_LIBRARY=OFF \
          -DOPUS_BUILD_TESTING=OFF \
          -DOPUS_BUILD_PROGRAMS=OFF \
          -DOPUS_BUILD_FRAMEWORK=OFF \
          -DOPUS_INSTALL_PKG_CONFIG_MODULE=OFF \
          -DOPUS_INSTALL_CMAKE_CONFIG_MODULE=OFF \
          -Wno-dev \
          > "${build_subdir}/cmake_configure.log" 2>&1

    cmake --build "$build_subdir" \
          --config "${BUILD_CONFIG}" \
          --parallel "$(sysctl -n hw.logicalcpu)" \
          > "${build_subdir}/cmake_build.log" 2>&1

    cmake --install "$build_subdir" \
          > "${build_subdir}/cmake_install.log" 2>&1

    log_success "完成 ${platform_id}"
    return 0
}

# ─── 创建 Framework bundle ────────────────────────────────────────────────────
# 用法: create_framework <framework_dir> <lib_path> <headers_src> <version>
create_framework() {
    local framework_dir="$1"
    local lib_path="$2"
    local headers_src="$3"
    local version="${4:-1.0}"

    local fw_name
    fw_name=$(basename "$framework_dir" .framework)

    local headers_dst="${framework_dir}/Headers"
    local modules_dst="${framework_dir}/Modules"

    rm -rf "$framework_dir"
    mkdir -p "$headers_dst" "$modules_dst"

    # 复制静态库作为 framework 二进制
    cp "$lib_path" "${framework_dir}/${fw_name}"

    # 复制公共头文件
    for hdr in opus.h opus_defines.h opus_types.h opus_multistream.h opus_projection.h opus_custom.h; do
        if [[ -f "${headers_src}/${hdr}" ]]; then
            cp "${headers_src}/${hdr}" "$headers_dst/"
        fi
    done

    # 写入 module.modulemap（Swift 支持）
    if [[ -f "${headers_src}/module.modulemap" ]]; then
        cp "${headers_src}/module.modulemap" "$modules_dst/module.modulemap"
    else
        cat > "$modules_dst/module.modulemap" <<MODULEMAP
framework module ${fw_name} {
    umbrella header "opus.h"

    header "opus_defines.h"
    header "opus_types.h"
    header "opus_multistream.h"
    header "opus_projection.h"
    header "opus_custom.h"

    export *
    module * { export * }
}
MODULEMAP
    fi

    # 写入 Info.plist
    cat > "${framework_dir}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${fw_name}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${fw_name}</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleShortVersionString</key>
    <string>${version}</string>
    <key>CFBundleVersion</key>
    <string>${version}</string>
</dict>
</plist>
PLIST
}

# ─── 合并多架构 fat binary ────────────────────────────────────────────────────
# 用法: merge_fat_library <output> <lib1> [<lib2> ...]
merge_fat_library() {
    local output="$1"
    shift
    if [[ $# -eq 1 ]]; then
        cp "$1" "$output"
    else
        lipo -create "$@" -output "$output"
    fi
}

# ─── 构建某平台的 Framework（合并多架构后打包）────────────────────────────────
# 用法: build_platform_framework <framework_out> <platform_id1> [<platform_id2> ...]
# 返回值: 0=成功, 1=失败（至少一个架构库缺失）
build_platform_framework() {
    local framework_out="$1"
    shift
    local platform_ids=("$@")

    local lib_files=()
    local pid lib_file install_dir

    for pid in "${platform_ids[@]}"; do
        install_dir="${BUILD_DIR}/install/${pid}"
        lib_file=$(find "${install_dir}" -name "libopus.a" 2>/dev/null | head -1 || true)
        if [[ -z "$lib_file" ]]; then
            log_warn "未找到 ${pid} 的静态库，跳过此平台 framework"
            return 1
        fi
        lib_files+=("$lib_file")
    done

    if [[ ${#lib_files[@]} -eq 0 ]]; then
        log_warn "没有可用的库文件，跳过 framework 创建"
        return 1
    fi

    local merged_lib="${BUILD_DIR}/merged_$(basename "$framework_out" .framework).a"
    merge_fat_library "$merged_lib" "${lib_files[@]}"

    create_framework \
        "$framework_out" \
        "$merged_lib" \
        "${SCRIPT_DIR}/include" \
        "${OPUS_VERSION}"

    log_success "Framework 创建完成: $(basename "$framework_out")"
    return 0
}

# ─── 主构建流程 ───────────────────────────────────────────────────────────────
main() {
    log_step "Opus XCFramework 构建脚本"
    log_info "源码目录: ${SCRIPT_DIR}"
    log_info "输出目录: ${OUTPUT_DIR}"
    log_info "构建目录: ${BUILD_DIR}"
    log_info "构建配置: ${BUILD_CONFIG}"
    log_info "跳过visionOS: ${SKIP_VISIONOS}"

    check_requirements

    rm -rf "${BUILD_DIR}"
    mkdir -p "${BUILD_DIR}" "${OUTPUT_DIR}"

    # 收集 xcodebuild -create-xcframework 的参数
    XCFRAMEWORK_ARGS=()

    # ═══════════════════════════════════════════════════════════════════════
    # 1. iOS (arm64)
    # ═══════════════════════════════════════════════════════════════════════
    log_step "1/9  iOS (arm64)"
    ios_fw="${BUILD_DIR}/frameworks/ios/Opus.framework"
    mkdir -p "$(dirname "$ios_fw")"
    if build_single_arch "ios-arm64" "iOS" "iphoneos" "arm64" \
        "-miphoneos-version-min=13.0"; then
        if build_platform_framework "$ios_fw" "ios-arm64"; then
            XCFRAMEWORK_ARGS+=("-framework" "$ios_fw")
        fi
    fi

    # ═══════════════════════════════════════════════════════════════════════
    # 2. iOS Simulator (arm64 + x86_64)
    # ═══════════════════════════════════════════════════════════════════════
    log_step "2/9  iOS Simulator (arm64 + x86_64)"
    build_single_arch "ios-sim-arm64" "iOS" "iphonesimulator" "arm64" \
        "-mios-simulator-version-min=13.0" || true
    build_single_arch "ios-sim-x86_64" "iOS" "iphonesimulator" "x86_64" \
        "-mios-simulator-version-min=13.0" || true
    ios_sim_fw="${BUILD_DIR}/frameworks/ios-simulator/Opus.framework"
    mkdir -p "$(dirname "$ios_sim_fw")"
    if build_platform_framework "$ios_sim_fw" "ios-sim-arm64" "ios-sim-x86_64"; then
        XCFRAMEWORK_ARGS+=("-framework" "$ios_sim_fw")
    fi

    # ═══════════════════════════════════════════════════════════════════════
    # 3. macOS (arm64 + x86_64)
    # ═══════════════════════════════════════════════════════════════════════
    log_step "3/9  macOS (arm64 + x86_64)"
    build_single_arch "macos-arm64" "Darwin" "macosx" "arm64" \
        "-mmacosx-version-min=11.0" || true
    build_single_arch "macos-x86_64" "Darwin" "macosx" "x86_64" \
        "-mmacosx-version-min=11.0" || true
    macos_fw="${BUILD_DIR}/frameworks/macos/Opus.framework"
    mkdir -p "$(dirname "$macos_fw")"
    if build_platform_framework "$macos_fw" "macos-arm64" "macos-x86_64"; then
        XCFRAMEWORK_ARGS+=("-framework" "$macos_fw")
    fi

    # ═══════════════════════════════════════════════════════════════════════
    # 4. tvOS (arm64)
    # ═══════════════════════════════════════════════════════════════════════
    log_step "4/9  tvOS (arm64)"
    tvos_fw="${BUILD_DIR}/frameworks/tvos/Opus.framework"
    mkdir -p "$(dirname "$tvos_fw")"
    if build_single_arch "tvos-arm64" "tvOS" "appletvos" "arm64" \
        "-mtvos-version-min=13.0"; then
        if build_platform_framework "$tvos_fw" "tvos-arm64"; then
            XCFRAMEWORK_ARGS+=("-framework" "$tvos_fw")
        fi
    fi

    # ═══════════════════════════════════════════════════════════════════════
    # 5. tvOS Simulator (arm64 + x86_64)
    # ═══════════════════════════════════════════════════════════════════════
    log_step "5/9  tvOS Simulator (arm64 + x86_64)"
    build_single_arch "tvos-sim-arm64" "tvOS" "appletvsimulator" "arm64" \
        "-mtvos-simulator-version-min=13.0" || true
    build_single_arch "tvos-sim-x86_64" "tvOS" "appletvsimulator" "x86_64" \
        "-mtvos-simulator-version-min=13.0" || true
    tvos_sim_fw="${BUILD_DIR}/frameworks/tvos-simulator/Opus.framework"
    mkdir -p "$(dirname "$tvos_sim_fw")"
    if build_platform_framework "$tvos_sim_fw" "tvos-sim-arm64" "tvos-sim-x86_64"; then
        XCFRAMEWORK_ARGS+=("-framework" "$tvos_sim_fw")
    fi

    # ═══════════════════════════════════════════════════════════════════════
    # 6. watchOS (arm64_32 + armv7k)
    # ═══════════════════════════════════════════════════════════════════════
    log_step "6/9  watchOS (arm64_32 + armv7k)"
    build_single_arch "watchos-arm64_32" "watchOS" "watchos" "arm64_32" \
        "-mwatchos-version-min=7.0" || true
    build_single_arch "watchos-armv7k" "watchOS" "watchos" "armv7k" \
        "-mwatchos-version-min=7.0" || true
    watchos_fw="${BUILD_DIR}/frameworks/watchos/Opus.framework"
    mkdir -p "$(dirname "$watchos_fw")"
    if build_platform_framework "$watchos_fw" "watchos-arm64_32" "watchos-armv7k"; then
        XCFRAMEWORK_ARGS+=("-framework" "$watchos_fw")
    fi

    # ═══════════════════════════════════════════════════════════════════════
    # 7. watchOS Simulator (arm64 + x86_64)
    # ═══════════════════════════════════════════════════════════════════════
    log_step "7/9  watchOS Simulator (arm64 + x86_64)"
    build_single_arch "watchos-sim-arm64" "watchOS" "watchsimulator" "arm64" \
        "-mwatchos-simulator-version-min=7.0" || true
    build_single_arch "watchos-sim-x86_64" "watchOS" "watchsimulator" "x86_64" \
        "-mwatchos-simulator-version-min=7.0" || true
    watchos_sim_fw="${BUILD_DIR}/frameworks/watchos-simulator/Opus.framework"
    mkdir -p "$(dirname "$watchos_sim_fw")"
    if build_platform_framework "$watchos_sim_fw" "watchos-sim-arm64" "watchos-sim-x86_64"; then
        XCFRAMEWORK_ARGS+=("-framework" "$watchos_sim_fw")
    fi

    # ═══════════════════════════════════════════════════════════════════════
    # 8 & 9. visionOS — 需要 Xcode 15+
    # ═══════════════════════════════════════════════════════════════════════
    if [[ "$SKIP_VISIONOS" == "false" ]]; then
        log_step "8/9  visionOS (arm64)"
        visionos_fw="${BUILD_DIR}/frameworks/visionos/Opus.framework"
        mkdir -p "$(dirname "$visionos_fw")"
        if build_single_arch "visionos-arm64" "visionOS" "xros" "arm64" \
            "-target arm64-apple-xros1.0"; then
            if build_platform_framework "$visionos_fw" "visionos-arm64"; then
                XCFRAMEWORK_ARGS+=("-framework" "$visionos_fw")
            fi
        fi

        log_step "9/9  visionOS Simulator (arm64 + x86_64)"
        build_single_arch "visionos-sim-arm64" "visionOS" "xrsimulator" "arm64" \
            "-target arm64-apple-xros1.0-simulator" || true
        build_single_arch "visionos-sim-x86_64" "visionOS" "xrsimulator" "x86_64" \
            "-target x86_64-apple-xros1.0-simulator" || true
        visionos_sim_fw="${BUILD_DIR}/frameworks/visionos-simulator/Opus.framework"
        mkdir -p "$(dirname "$visionos_sim_fw")"
        if build_platform_framework "$visionos_sim_fw" "visionos-sim-arm64" "visionos-sim-x86_64"; then
            XCFRAMEWORK_ARGS+=("-framework" "$visionos_sim_fw")
        fi
    else
        log_warn "跳过 visionOS 构建 (8/9, 9/9)"
    fi

    # ═══════════════════════════════════════════════════════════════════════
    # 合并为 XCFramework
    # ═══════════════════════════════════════════════════════════════════════
    log_step "合并 XCFramework"

    if [[ ${#XCFRAMEWORK_ARGS[@]} -eq 0 ]]; then
        log_error "没有成功构建的平台，无法创建 XCFramework"
        exit 1
    fi

    xcfw_output="${OUTPUT_DIR}/${FRAMEWORK_NAME}.xcframework"
    rm -rf "$xcfw_output"

    log_info "合并以下 Framework:"
    for arg in "${XCFRAMEWORK_ARGS[@]}"; do
        if [[ "$arg" == *.framework ]]; then
            log_info "  → $arg"
        fi
    done

    xcodebuild -create-xcframework \
        "${XCFRAMEWORK_ARGS[@]}" \
        -output "$xcfw_output"

    # 清理临时目录
    if [[ "$CLEAN_BUILD" == "true" ]]; then
        log_info "清理临时构建目录..."
        rm -rf "${BUILD_DIR}"
    fi

    # 输出结果摘要
    log_step "构建完成"
    log_success "XCFramework 已生成: ${xcfw_output}"
    echo ""
    log_info "包含的平台切片:"
    if [[ -d "$xcfw_output" ]]; then
        while IFS= read -r fw; do
            rel="${fw#${OUTPUT_DIR}/}"
            bin="${fw}/$(basename "$fw" .framework)"
            if [[ -f "$bin" ]]; then
                archs=$(lipo -info "$bin" 2>/dev/null | sed 's/.*: //' || echo "unknown")
                log_info "  ${rel}  [${archs}]"
            else
                log_info "  ${rel}"
            fi
        done < <(find "$xcfw_output" -name "*.framework" -maxdepth 3 2>/dev/null)
    fi

    echo ""
    log_info "在 Swift/Xcode 项目中使用:"
    log_info "  将 ${xcfw_output} 拖入 Xcode 项目的 Frameworks 中"
    log_info "  或在 Package.swift 中添加:"
    log_info "    .binaryTarget(name: \"Opus\","
    log_info "                  path: \"path/to/${FRAMEWORK_NAME}.xcframework\")"
}

# ─── 入口 ─────────────────────────────────────────────────────────────────────
main "$@"
