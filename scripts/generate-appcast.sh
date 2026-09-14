#!/bin/bash
set -euo pipefail
APPCAST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
APPCAST_TOOLS="$APPCAST_ROOT/.build/artifacts/sparkle/Sparkle/bin"
APPCAST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APPCAST_ROOT/packaging/Info.plist")"
APPCAST_ARCHIVE="${1:-$APPCAST_ROOT/dist/ClaudeSessionWarmer-$APPCAST_VERSION.dmg}"
APPCAST_DOWNLOAD_PREFIX="${2:-https://github.com/Sharknia/claude-session/releases/download/v$APPCAST_VERSION/}"
APPCAST_OUTPUT="${3:-$APPCAST_ROOT/dist/appcast.xml}"
APPCAST_ACCOUNT="com.sharknia.ClaudeSessionWarmer.sparkle"

if [[ ! -f "$APPCAST_ARCHIVE" || ! -x "$APPCAST_TOOLS/generate_appcast" ]]; then
    echo "오류: 배포 아카이브와 Sparkle 도구를 먼저 빌드해 주세요." >&2
    exit 1
fi
APPCAST_PUBLIC_KEY="$("$APPCAST_TOOLS/generate_keys" --account "$APPCAST_ACCOUNT" -p)"
APPCAST_EXPECTED_KEY="$(/usr/libexec/PlistBuddy -c 'Print SUPublicEDKey' "$APPCAST_ROOT/packaging/Info.plist")"
if [[ "$APPCAST_PUBLIC_KEY" != "$APPCAST_EXPECTED_KEY" ]]; then
    echo "오류: 업데이트 서명 키와 앱에 포함된 공개키가 다릅니다." >&2
    exit 1
fi

APPCAST_STAGE="$(mktemp -d "$APPCAST_ROOT/.build/appcast.XXXXXX")"
cp "$APPCAST_ARCHIVE" "$APPCAST_STAGE/"
"$APPCAST_TOOLS/generate_appcast" --account "$APPCAST_ACCOUNT" \
    --maximum-deltas 0 --maximum-versions 1 \
    --download-url-prefix "$APPCAST_DOWNLOAD_PREFIX" "$APPCAST_STAGE"
# 이전 버전의 앱에는 SURequireSignedFeed가 없어도 피드 자체는 항상 서명한다.
"$APPCAST_TOOLS/sign_update" --account "$APPCAST_ACCOUNT" "$APPCAST_STAGE/appcast.xml"
"$APPCAST_TOOLS/sign_update" --account "$APPCAST_ACCOUNT" --verify "$APPCAST_STAGE/appcast.xml"
cp "$APPCAST_STAGE/appcast.xml" "$APPCAST_OUTPUT"
echo "서명된 업데이트 목록: $APPCAST_OUTPUT"
