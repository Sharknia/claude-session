#!/bin/bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
readonly DIST_DIR="$PROJECT_DIR/dist"
readonly APP_NAME="ClaudeSessionWarmer"
readonly APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
readonly APP_EXECUTABLE="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
readonly INFO_PLIST_SOURCE="$PROJECT_DIR/packaging/Info.plist"
readonly APP_ICON_SOURCE="$PROJECT_DIR/packaging/AppIcon.icns"
readonly MENU_BAR_ICON_SOURCE="$PROJECT_DIR/packaging/MenuBarTemplate.pdf"
readonly REQUIREMENTS_FILE="$PROJECT_DIR/packaging/designated-requirement.txt"
readonly CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application: HakKyeol Lee (V9SQZ6B7RP)}"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$INFO_PLIST_SOURCE")"
readonly APP_VERSION
readonly RELEASE_BUILD="${RELEASE_BUILD:-0}"
if [[ "$RELEASE_BUILD" == "1" ]]; then
    : "${NOTARY_PROFILE:?RELEASE_BUILD=1에는 NOTARY_PROFILE이 필요합니다.}"
    readonly DMG_PATH="$DIST_DIR/$APP_NAME-$APP_VERSION.dmg"
else
    readonly DMG_PATH="$DIST_DIR/$APP_NAME-$APP_VERSION-dev.dmg"
fi
readonly VOLUME_NAME="Claude Session Warmer $APP_VERSION"

if [[ ! -f "$PROJECT_DIR/Package.swift" || ! -f "$INFO_PLIST_SOURCE" || ! -f "$APP_ICON_SOURCE" || ! -f "$MENU_BAR_ICON_SOURCE" || ! -f "$REQUIREMENTS_FILE" ]]; then
    echo "오류: 프로젝트 루트 또는 필수 packaging 파일을 찾을 수 없습니다." >&2
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
cp "$APP_ICON_SOURCE" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
cp "$MENU_BAR_ICON_SOURCE" "$APP_BUNDLE/Contents/Resources/MenuBarTemplate.pdf"
chmod 755 "$APP_EXECUTABLE"

echo "[3/5] Developer ID 서명: $CODESIGN_IDENTITY"
# 같은 Bundle ID·Team ID·Developer ID 인증서 종류를 업데이트 간 유지한다.
for target in "$APP_EXECUTABLE" "$APP_BUNDLE"; do
    codesign --force --options runtime --timestamp \
        --identifier com.sharknia.ClaudeSessionWarmer \
        --requirements "$REQUIREMENTS_FILE" \
        --sign "$CODESIGN_IDENTITY" "$target"
done
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
codesign --verify --strict --verbose=2 "$APP_EXECUTABLE"
# 다른 팀 또는 개발용/ad-hoc 인증서로 잘못 빌드되는 것을 거부한다.
codesign --verify --strict --test-requirement "=$(sed 's/^designated => //' "$REQUIREMENTS_FILE")" "$APP_BUNDLE"

if [[ "$RELEASE_BUILD" == "1" ]]; then
    readonly APP_ARCHIVE="$DIST_DIR/$APP_NAME-notarization.zip"
    ditto -c -k --keepParent "$APP_BUNDLE" "$APP_ARCHIVE"
    xcrun notarytool submit "$APP_ARCHIVE" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$DIST_DIR/app-notarization.json"
    [[ "$(/usr/bin/plutil -extract status raw "$DIST_DIR/app-notarization.json")" == "Accepted" ]] || { echo "앱 공증 실패" >&2; exit 1; }
    xcrun stapler staple "$APP_BUNDLE"
    xcrun stapler validate "$APP_BUNDLE"
    spctl --assess --type execute --verbose=2 "$APP_BUNDLE"
    rm -f -- "$APP_ARCHIVE"
fi

echo "[4/5] DMG 생성"
hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$APP_BUNDLE" \
    -format UDZO \
    -ov \
    "$DMG_PATH"

codesign --force --timestamp --identifier com.sharknia.ClaudeSessionWarmer.dmg --sign "$CODESIGN_IDENTITY" "$DMG_PATH"
codesign --verify --strict --verbose=2 "$DMG_PATH"

if [[ "$RELEASE_BUILD" == "1" ]]; then
    echo "[5/5] 공증 제출 및 stapling: $NOTARY_PROFILE"
    xcrun notarytool submit "$DMG_PATH" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait --output-format json > "$DIST_DIR/dmg-notarization.json"
    [[ "$(/usr/bin/plutil -extract status raw "$DIST_DIR/dmg-notarization.json")" == "Accepted" ]] || { echo "DMG 공증 실패" >&2; exit 1; }
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"
else
    echo "[5/5] Developer ID 서명 완료, 공증·stapling 미완료: 공개 배포 금지"
fi

if [[ "$RELEASE_BUILD" == "1" ]]; then
    echo "배포용 서명·공증 DMG 완료: $DMG_PATH"
else
    echo "내부 검증용 Developer ID 서명 DMG 완료: $DMG_PATH"
fi
