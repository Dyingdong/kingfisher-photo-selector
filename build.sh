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

SRC=(
    "$ROOT/Sources/Metadata.swift"
    "$ROOT/Sources/Analyze.swift"
    "$ROOT/Sources/Subject.swift"
    "$ROOT/Sources/Report.swift"
    "$ROOT/Sources/WhiteBalance.swift"
    "$ROOT/Sources/AFPoints.swift"
    "$ROOT/Sources/ExifInfo.swift"
    "$ROOT/Sources/FocusSemantics.swift"
    "$ROOT/Sources/HumanPresence.swift"
    "$ROOT/Sources/AISubject.swift"
    "$ROOT/Sources/GenreMemory.swift"
    "$ROOT/Sources/Score.swift"
)
FLAGS=(-O -swift-version 5 -target arm64-apple-macosx13.0)

# GUI App
swiftc "${FLAGS[@]}" "${SRC[@]}" "$ROOT/App/App.swift" \
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
