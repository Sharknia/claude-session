#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFY_DIR="$ROOT_DIR/.build/warmup-verification"
VERIFY_APP="$VERIFY_DIR/VerifyWarmup.app"
VERIFY_EXECUTABLE="$VERIFY_APP/Contents/MacOS/ClaudeSessionWarmerTests-VerifyWarmup"
KEYCHAIN_PROFILE="$ROOT_DIR/.build/signing/embedded.provisionprofile"
KEYCHAIN_ENTITLEMENTS="$ROOT_DIR/.build/signing/keychain.entitlements"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application: HakKyeol Lee (V9SQZ6B7RP)}"
python3 "$ROOT_DIR/scripts/prepare-keychain-signing.py" "${PROVISIONING_PROFILE:-auto}" "$KEYCHAIN_ENTITLEMENTS" --identity "$CODESIGN_IDENTITY" --embed "$KEYCHAIN_PROFILE"
rm -rf -- "$VERIFY_APP"
mkdir -p "$VERIFY_APP/Contents/MacOS"
cp "$ROOT_DIR/packaging/Info.plist" "$VERIFY_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set CFBundleExecutable ClaudeSessionWarmerTests-VerifyWarmup' "$VERIFY_APP/Contents/Info.plist"
cp "$KEYCHAIN_PROFILE" "$VERIFY_APP/Contents/embedded.provisionprofile"
swiftc -parse-as-library -swift-version 6 \
  "$ROOT_DIR/Sources/ClaudeSessionWarmer/Models.swift" \
  "$ROOT_DIR/Sources/ClaudeSessionWarmer/DiagnosticLogger.swift" \
  "$ROOT_DIR/Sources/ClaudeSessionWarmer/ClaudeOAuthLoopback.swift" \
  "$ROOT_DIR/Sources/ClaudeSessionWarmer/ClaudeService.swift" \
  "$ROOT_DIR/Sources/ClaudeSessionWarmer/ManagedCredentialStore.swift" \
  "$ROOT_DIR/scripts/VerifyWarmup.swift" \
  -o "$VERIFY_EXECUTABLE"
codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" \
  --identifier com.sharknia.ClaudeSessionWarmer \
  --requirements "$ROOT_DIR/packaging/designated-requirement.txt" \
  --entitlements "$KEYCHAIN_ENTITLEMENTS" "$VERIFY_APP"
"$VERIFY_EXECUTABLE" "$@"
