#!/bin/bash
set -euo pipefail
MENU_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
MENU_FRAMEWORKS="$MENU_ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"
MENU_TEMP_ROOT="${TMPDIR:-/tmp}"
MENU_OUTPUT="$(mktemp -d "${MENU_TEMP_ROOT%/}/ClaudeSessionWarmerTests-Menu.XXXXXX")"
MENU_OUTPUT="$(cd -- "$MENU_OUTPUT" && pwd -P)"
MENU_APP="$MENU_OUTPUT/RecoveryMenuPreview.app"
cleanup() {
  python3 - "$MENU_OUTPUT" <<'PY'
from pathlib import Path
import sys
root=Path(sys.argv[1])
if not root.name.startswith('ClaudeSessionWarmerTests-Menu.'):
    raise RuntimeError('검증 임시 경로가 아님')
app=root/'RecoveryMenuPreview.app'
for path in [app/'Contents/MacOS/ClaudeSessionWarmerTests-MenuProbe', app/'Contents/Info.plist']:
    path.unlink(missing_ok=True)
for path in [app/'Contents/MacOS', app/'Contents', app, root]:
    if path.exists():
        path.rmdir()
PY
  # 번들이 남아 있으면 Launch Services가 다시 등록할 수 있으므로 파일 정리 뒤 해제한다.
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -u "$MENU_APP"
}
trap cleanup EXIT
mkdir -p "$MENU_APP/Contents/MacOS"
python3 - "$MENU_APP/Contents/Info.plist" <<'PY'
import pathlib,plistlib,sys
pathlib.Path(sys.argv[1]).write_bytes(plistlib.dumps({
    'CFBundleIdentifier':'com.sharknia.ClaudeSessionWarmer.MenuPreview',
    'CFBundleName':'Claude Session Warmer 복구 검증',
    'CFBundleExecutable':'ClaudeSessionWarmerTests-MenuProbe',
    'CFBundlePackageType':'APPL','CFBundleVersion':'1','CFBundleShortVersionString':'0.0.0'
}))
PY
MENU_SOURCES=()
for source in "$MENU_ROOT"/Sources/ClaudeSessionWarmer/*.swift; do
  [[ "$(basename "$source")" == "ClaudeSessionWarmerApp.swift" ]] || MENU_SOURCES+=("$source")
done
swiftc -parse-as-library -swift-version 6 -target arm64-apple-macos14.0 -F "$MENU_FRAMEWORKS" -framework Sparkle \
  -Xlinker -rpath -Xlinker "$MENU_FRAMEWORKS" \
  "${MENU_SOURCES[@]}" "$MENU_ROOT/Tests/ClaudeSessionWarmerTests/MemoryDefaults.swift" \
  "$MENU_ROOT/scripts/PreviewRecoveryMenu.swift" -o "$MENU_APP/Contents/MacOS/ClaudeSessionWarmerTests-MenuProbe"
echo "preview_app=$MENU_APP"
"$MENU_APP/Contents/MacOS/ClaudeSessionWarmerTests-MenuProbe" "${1:-settings}"
