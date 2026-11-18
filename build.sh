#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/摄影照片筛选工具.app"
mkdir -p "$APP/Contents/MacOS"
cp "$ROOT/App/Info.plist" "$APP/Contents/Info.plist"

# 把精简版 exiftool 打进 App 资源（读取 RAW MakerNote 对焦点用）
RES="$APP/Contents/Resources"
mkdir -p "$RES"
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
    "$ROOT/Sources/Score.swift"
)
FLAGS=(-O -swift-version 5 -target arm64-apple-macosx13.0)

# GUI App
swiftc "${FLAGS[@]}" "${SRC[@]}" "$ROOT/App/App.swift" \
    -o "$APP/Contents/MacOS/FocusScreener"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
echo "BUILT: $APP"

# 命令行工具（与 App 共用同一套判定与报告格式，供离线复核 / 自动化验证）
swiftc "${FLAGS[@]}" "${SRC[@]}" "$ROOT/Tools/main.swift" -o "$ROOT/focuscli"
echo "BUILT: $ROOT/focuscli"
