#!/bin/bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
readonly DIST_DIR="$PROJECT_DIR/dist"
readonly APP_NAME="ClaudeSessionWarmer"
readonly APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
readonly APP_EXECUTABLE="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
readonly INFO_PLIST_SOURCE="$PROJECT_DIR/packaging/Info.plist"
readonly RELEASE_BUILD="${RELEASE_BUILD:-0}"
if [[ "$RELEASE_BUILD" == "1" ]]; then
    : "${CODESIGN_IDENTITY:?RELEASE_BUILD=1에는 CODESIGN_IDENTITY가 필요합니다.}"
    : "${NOTARY_PROFILE:?RELEASE_BUILD=1에는 NOTARY_PROFILE이 필요합니다.}"
    readonly DMG_PATH="$DIST_DIR/$APP_NAME-0.1.0.dmg"
else
    readonly DMG_PATH="$DIST_DIR/$APP_NAME-0.1.0-dev.dmg"
fi
readonly VOLUME_NAME="Claude Session Warmer 0.1.0"

if [[ ! -f "$PROJECT_DIR/Package.swift" || ! -f "$INFO_PLIST_SOURCE" ]]; then
    echo "오류: 프로젝트 루트 또는 packaging/Info.plist를 찾을 수 없습니다." >&2
    exit 1
fi

mkdir -p "$DIST_DIR"

# Only remove this script's exact, reproducible outputs.
rm -rf -- "$APP_BUNDLE"
rm -f -- "$DMG_PATH"

echo "[1/5] SwiftPM release 빌드"
swift build --package-path "$PROJECT_DIR" --configuration release
readonly BIN_DIR="$(swift build --package-path "$PROJECT_DIR" --configuration release --show-bin-path)"
readonly BUILT_EXECUTABLE="$BIN_DIR/$APP_NAME"

if [[ ! -x "$BUILT_EXECUTABLE" ]]; then
    echo "오류: 릴리스 실행 파일을 찾을 수 없습니다: $BUILT_EXECUTABLE" >&2
    exit 1
fi

echo "[2/5] 앱 번들 생성"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$INFO_PLIST_SOURCE" "$APP_BUNDLE/Contents/Info.plist"
cp "$BUILT_EXECUTABLE" "$APP_EXECUTABLE"
chmod 755 "$APP_EXECUTABLE"

if [[ "$RELEASE_BUILD" == "1" ]]; then
    echo "[3/5] Developer ID 서명: $CODESIGN_IDENTITY"
    codesign \
        --force \
        --options runtime \
        --timestamp \
        --sign "$CODESIGN_IDENTITY" \
        "$APP_BUNDLE"
else
    echo "[3/5] CODESIGN_IDENTITY 없음: 로컬 검증용 ad-hoc 서명"
    codesign --force --sign - "$APP_BUNDLE"
fi

codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

echo "[4/5] DMG 생성"
hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$APP_BUNDLE" \
    -format UDZO \
    -ov \
    "$DMG_PATH"

if [[ "$RELEASE_BUILD" == "1" ]]; then
    codesign --force --timestamp --sign "$CODESIGN_IDENTITY" "$DMG_PATH"
    codesign --verify --strict --verbose=2 "$DMG_PATH"
fi

if [[ "$RELEASE_BUILD" == "1" ]]; then
    echo "[5/5] 공증 제출 및 stapling: $NOTARY_PROFILE"
    xcrun notarytool submit "$DMG_PATH" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"
else
    echo "[5/5] 개발용 DMG: 공증 생략"
fi

if [[ "$RELEASE_BUILD" == "1" ]]; then
    echo "배포용 서명·공증 DMG 완료: $DMG_PATH"
else
    echo "로컬 검증용 ad-hoc DMG 완료: $DMG_PATH"
fi
