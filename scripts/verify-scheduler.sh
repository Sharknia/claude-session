#!/bin/bash
set -euo pipefail
SCHEDULER_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEDULER_VERIFY_DIR="$SCHEDULER_ROOT/.build/scheduler-verification"
mkdir -p "$SCHEDULER_VERIFY_DIR"
swiftc -parse-as-library -swift-version 6 \
  "$SCHEDULER_ROOT/Sources/ClaudeSessionWarmer/ExecutionOwnership.swift" \
  "$SCHEDULER_ROOT/Sources/ClaudeSessionWarmer/Models.swift" \
  "$SCHEDULER_ROOT/Sources/ClaudeSessionWarmer/SettingsStore.swift" \
  "$SCHEDULER_ROOT/Sources/ClaudeSessionWarmer/ScheduleEngine.swift" \
  "$SCHEDULER_ROOT/Sources/ClaudeSessionWarmer/WallClockTimer.swift" \
  "$SCHEDULER_ROOT/Sources/ClaudeSessionWarmer/DiagnosticLogger.swift" \
  "$SCHEDULER_ROOT/Sources/ClaudeSessionWarmer/ClaudeOAuthLoopback.swift" \
  "$SCHEDULER_ROOT/Sources/ClaudeSessionWarmer/ClaudeService.swift" \
  "$SCHEDULER_ROOT/Sources/ClaudeSessionWarmer/ManagedCredentialStore.swift" \
  "$SCHEDULER_ROOT/Sources/ClaudeSessionWarmer/AppState.swift" \
  "$SCHEDULER_ROOT/Tests/ClaudeSessionWarmerTests/MemoryDefaults.swift" \
  "$SCHEDULER_ROOT/scripts/VerifyScheduler.swift" \
  -o "$SCHEDULER_VERIFY_DIR/ClaudeSessionWarmerTests-SleepProbe"
if [[ "${1:-}" == "--build-only" ]]; then
  echo "$SCHEDULER_VERIFY_DIR/ClaudeSessionWarmerTests-SleepProbe"
  exit 0
fi
exec "$SCHEDULER_VERIFY_DIR/ClaudeSessionWarmerTests-SleepProbe" "$@"
