#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFY_DIR="$ROOT_DIR/.build/warmup-verification"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application: HakKyeol Lee (V9SQZ6B7RP)}"
mkdir -p "$VERIFY_DIR"
swiftc -parse-as-library -swift-version 6 \
  "$ROOT_DIR/Sources/ClaudeSessionWarmer/Models.swift" \
  "$ROOT_DIR/Sources/ClaudeSessionWarmer/DiagnosticLogger.swift" \
  "$ROOT_DIR/Sources/ClaudeSessionWarmer/ClaudeOAuthLoopback.swift" \
  "$ROOT_DIR/Sources/ClaudeSessionWarmer/ClaudeService.swift" \
  "$ROOT_DIR/scripts/VerifyWarmup.swift" \
  -o "$VERIFY_DIR/VerifyWarmup"
codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" \
  --identifier com.sharknia.ClaudeSessionWarmer \
  --requirements "$ROOT_DIR/packaging/designated-requirement.txt" "$VERIFY_DIR/VerifyWarmup"
"$VERIFY_DIR/VerifyWarmup" "$@"
