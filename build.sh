#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/Kingfisher-PhotoSelector.app"
mkdir -p "$APP/Contents/MacOS"
cp "$ROOT/App/Info.plist" "$APP/Contents/Info.plist"

# 把精简版 exiftool 打进 App 资源（读取 RAW MakerNote 对焦点用）
RES="$APP/Contents/Resources"
mkdir -p "$RES"
# 把 App 图标打进 App 资源（Info.plist 的 CFBundleIconFile=AppIcon 指向它）
if [ -f "$ROOT/App/AppIcon.icns" ]; then
    cp "$ROOT/App/AppIcon.icns" "$RES/AppIcon.icns"
fi
if [ -f "$ROOT/Tools/exiftool/exiftool" ]; then
    mkdir -p "$RES/exiftool_lib"
    cp "$ROOT/Tools/exiftool/exiftool" "$RES/exiftool"
    cp -R "$ROOT/Tools/exiftool/lib/." "$RES/exiftool_lib/"
    chmod +x "$RES/exiftool"
fi

# 鸟种识别：BioCLIP 2 图像塔 Core ML + 预计算文本特征（2026-11-23 换回）。
# 资源已随项目放在 Resources/，构建时覆盖 App 包内的旧副本，保证可重复构建。
if [ -d "$ROOT/Resources/BioCLIPImage.mlmodelc" ]; then
    rm -rf "$RES/BioCLIPImage.mlmodelc"
    cp -R "$ROOT/Resources/BioCLIPImage.mlmodelc" "$RES/"
fi
if [ -f "$ROOT/Resources/bioclip_text_features.bin" ]; then
    cp "$ROOT/Resources/bioclip_text_features.bin" "$RES/bioclip_text_features.bin"
fi
if [ -f "$ROOT/Resources/bioclip_labels.txt" ]; then
    cp "$ROOT/Resources/bioclip_labels.txt" "$RES/bioclip_labels.txt"
fi

SRC=(
    "$ROOT/Sources/Metadata.swift"
    "$ROOT/Sources/Analyze.swift"
    "$ROOT/Sources/Subject.swift"
    "$ROOT/Sources/Report.swift"
    "$ROOT/Sources/SessionCache.swift"
    "$ROOT/Sources/WhiteBalance.swift"
    "$ROOT/Sources/AFPoints.swift"
    "$ROOT/Sources/ExifInfo.swift"
    "$ROOT/Sources/FocusSemantics.swift"
    "$ROOT/Sources/HumanPresence.swift"
    "$ROOT/Sources/AISubject.swift"
    "$ROOT/Sources/GenreMemory.swift"
    "$ROOT/Sources/Score.swift"
)
# 鸟种模块只有 GUI 用：Core ML 依赖不进命令行工具，
# 命令行继续只做判定复核，保持轻量。纯离线，不含任何网络/钥匙串代码。
GUI_EXTRA=(
    "$ROOT/Sources/BirdSpecies.swift"
    "$ROOT/Sources/BirdLog.swift"
    "$ROOT/App/Comparison/BurstIndex.swift"
    "$ROOT/App/Comparison/ComparisonWorkspace.swift"
    "$ROOT/App/Comparison/ComparisonKeys.swift"
)
FLAGS=(-O -swift-version 5 -target arm64-apple-macosx13.0)

# GUI App
swiftc "${FLAGS[@]}" "${SRC[@]}" "${GUI_EXTRA[@]}" "$ROOT/App/App.swift" \
    -o "$APP/Contents/MacOS/Kingfisher-PhotoSelector"
# 清掉更名前（FocusScreener / PhotoSelector 时代）可能残留的旧可执行文件
rm -f "$APP/Contents/MacOS/FocusScreener" "$APP/Contents/MacOS/PhotoSelector"
# 稳定的指定要求（identifier 固定）：这样 TCC 对「下载」文件夹的授权在
# 重新编译后依然有效（否则 ad-hoc 签名每次都变，授权会失效）。
# 注意：2026-11-19 从 local.workbuddy.focusscreener 更名为 local.workbuddy.photoselector，
# 更名后首次运行需要重新授权一次「下载」文件夹访问。
# 之后软件显示名改为 Kingfisher-PhotoSelector，但 Bundle ID 保持不动：它只是内部标识，
# 副名仍含 PhotoSelector，且再改一次会让 TCC 授权再次失效，得不偿失。
codesign --force --deep --sign - \
    --requirements '=designated => identifier "local.workbuddy.photoselector"' \
    "$APP" >/dev/null 2>&1 || codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
echo "BUILT: $APP"

# 命令行工具（与 App 共用同一套判定与报告格式，供离线复核 / 自动化验证）
swiftc "${FLAGS[@]}" "${SRC[@]}" "$ROOT/Tools/main.swift" -o "$ROOT/kingfisher-photoselector"
echo "BUILT: $ROOT/kingfisher-photoselector"
