#!/bin/bash
# 导入 XCFramework 或其 ZIP；无参数时校验已导入的本地 SDK。
set -euo pipefail
demo_root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
[ "$#" -le 1 ] || { echo "用法：$0 [XCFramework目录或ZIP]" >&2; exit 1; }
mkdir -p "$demo_root/build" "$demo_root/Frameworks"
staging="$(mktemp -d "$demo_root/build/import.XXXXXX")"
if [ "$#" = 0 ]; then
    source_path="$demo_root/Frameworks/WaveNoteSDK.xcframework"
    [ -d "$source_path" ] || { echo '缺少 SDK。请先单独取得 SDK，再运行 bash scripts/prepare-sdk.sh /absolute/path/WaveNoteSDK.xcframework.zip' >&2; exit 1; }
    /usr/libexec/PlistBuddy -c 'Print :AvailableLibraries' "$source_path/Info.plist" >/dev/null
    echo '已使用本地 WaveNoteSDK.xcframework'; exit 0
else
    source_path="$1"
fi
if [ -d "$source_path" ]; then
    ditto "$source_path" "$staging/WaveNoteSDK.xcframework"
else
    unzip -tq "$source_path" >/dev/null
    ditto -x -k "$source_path" "$staging"
fi
/usr/libexec/PlistBuddy -c 'Print :AvailableLibraries' "$staging/WaveNoteSDK.xcframework/Info.plist" >/dev/null
# 仅替换 Demo 自己的固定依赖目录，不移动或修改传入的交付包。
rm -rf "$demo_root/Frameworks/WaveNoteSDK.xcframework"
mv "$staging/WaveNoteSDK.xcframework" "$demo_root/Frameworks/"
echo "已准备：$demo_root/Frameworks/WaveNoteSDK.xcframework"
