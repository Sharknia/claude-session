# 지연 워밍 복구 구현·검증 결과

작성일: 2026-09-17 (Asia/Seoul)

상태: 구현, 자동 검증, 서명·공증, 설치와 예약 복원 확인 완료. 실제 DarkWake 워밍 관찰은 사용자 담당으로 이번 작업 범위에서 제외한다.

## 1. 코드와 구현 범위

- 시작 기준: `origin/dev`의 `61037b30d93c8761755caf2a7dd5ebf47db140f5`
- 브랜치: `codex/fix-late-warmup-recovery`
- 계획 커밋: `1d17d22`
- 앱 구현 커밋: `a6b4359` (이후 커밋은 테스트·검증 도구·문서 및 빌드 번호 갱신)
- 단일 에이전트 수행. 새 의존성·서버·helper·전원 설정 변경 없음.

`ScheduleEngine`은 오늘 필요한 대상 하나를 선택하고, `AppState`는 지연된 대상도 현재 상태에 맞춰 처리한다. 첫 실행 5초·예약 3분 만료와 실패 후 가상 5시간 fallback을 제거했다. wall time 타이머, OAuth, Keychain, PTY 실행 코드는 재사용했다.

기존 저장 구조에 마지막 확인 리셋 시각, 실제 전송 시각, 실패 횟수와 재시도 시각만 선택적 필드로 보완했다. 구버전 JSON도 읽으며 당일 혼합 집계는 상한으로 보수적으로 유지한다. 새 집계는 다음 실행일부터 적용된다. 미확인 전송은 날짜 변경·재시작으로 해제하지 않고, 별도 재전송 확인을 제공한다.

## 2. 자동 검증

| 검증 | 결과 | 증거 |
| --- | --- | --- |
| 전체 XCTest | 87개, 실패 0 | `swift test`, 2026-09-17 13:45:01 완료 |
| Release 빌드 | 성공 | `swift build -c release` |
| 실제 타이머 기본 동작 | 조회 1회, 지연 약 7ms | `bash scripts/verify-scheduler.sh awake 5` |
| 실제 타이머의 147초 지난 예약 | 조회 2회, 가짜 워밍 1회, 성공 저장·실제 응답 리셋 반영 | `bash scripts/verify-scheduler.sh late 147` |
| 변경 파일 검사 | 공백·충돌 표식·로컬 문서 링크 확인 | `git diff --check` 및 문서 링크 검사 |

`late 147`의 출력:

```text
result=passed inspections=2 fake_warmups=1 sleeps=0 wakes=0 drift_s=147.0277580022812 status=succeeded
```

이 검증은 실제 `WallClockTimer`와 `AppState`를 사용하되 서비스만 가짜로 주입한다. 실제 Claude 호출이나 잠자기 조작은 수행하지 않았다.

| 동작 계약 | 주요 회귀 테스트 |
| --- | --- |
| 147초·3시간·10시간 지연, 시작·콜백 경로 | `testIncidentDelayAndManyMissedHoursWarmOnlyOnceUsingActualReset`, `testDelayedCallbacksExecuteWithoutGraceDeadline` |
| 예정 시각 전 대기, 복귀 후 같은 목표 | `testEarlyFirstAndRetryCallbacksWaitUntilTheirOwnDate`, `testWeekendAndRepeatedWakeKeepMondayTarget` |
| 실제 리셋 연결과 하루 3개 상한 | `testScheduledActivationPersistsAcrossRestartAndRunsNextWindowOnce` |
| 실패는 미완료 유지, 재시작 후 횟수·간격 보존 | `testFailuresRemainPendingAndRetriesAreBoundedAcrossRestart`, `testWakeBeforeRetryAndRestartPreserveBackoff` |
| 전송 후 타임아웃·재시작·다음 날·수동 요청의 중복 방지 | `testWarmupTimeoutThenActiveQuotaNeverResendsPrompt`, `testUnconfirmedTransmissionSurvivesNextDayAndManualRequests` |
| 명시적 재전송도 활성 상태부터 확인 | `testExplicitResendRechecksQuotaAndAllowsOnlyOneNewWarmup` |
| 같은 창의 리셋 시각 보정은 중복 집계하지 않음 | `testSameActiveWindowWithFractionalResetCorrectionIsNotCountedTwice` |
| 조회 도중 잠자기·날짜 변경·설정 교체 | `testSleepDuringInactiveInspectionRefreshesBeforeSending`, `testDateChangeDuringInspectionDefersToTodaysFirstWithoutSendingOldWork`, `testSettingsReplacementDuringWorkDiscardsOldCallbackAfterFailure` |
| 워밍 중 복귀와 수동·자동 요청, 취소된 콜백 | `testWakeDuringScheduledAndManualWorkDefersReconciliationUntilResult`, `testReplacedCallbacksNeverExecuteIncludingSameDate` |
| 일정 밖 수동 실행은 자동 연쇄를 시작하지 않음 | `testOutsideScheduleManualWarmupDoesNotStartAutomaticChain` |
| 구버전 혼합 집계·새 미확인 표식 보존 | `testLegacyCyclePreservesCountAndOnlyClearsConfirmedTransmission`, `testNewPendingTransmissionIsNotErasedByOlderSuccessRecord` |
| 응답이 불명확하면 전송하지 않음 | `testExpiredActiveResponseAndMissingResetDoNotTriggerWarmup` |

실행 로그는 작업 머신의 `/tmp/claude-session-recovery-tests-final.log`, `/tmp/claude-session-recovery-release.log`, `/tmp/claude-session-recovery-probe.log`, `/tmp/claude-session-recovery-late-probe.log`에 있다. 임시 파일이므로 주요 결과를 본문에 함께 보존했다.

## 3. 패키지와 설치 확인

- 제품 버전: **0.1.4**, 빌드: **10**
- 산출물: `dist/ClaudeSessionWarmer-0.1.4.dmg`
- DMG SHA-256: `917565014485c79190c70685e1a52c4390887a5fe9dde9c40515f840ba5c918b`
- 앱·실행 파일·DMG Developer ID 서명 검증 통과.
- 앱 공증: `a93506da-cf3e-48f1-a490-c8d5be58adbb`, `Accepted`.
- DMG 공증: `ba797e2d-dd3c-4b0b-8d52-aa0d2c1a31ea`, `Accepted`.
- 앱·DMG stapling 검증 통과. 설치 앱의 `spctl` 결과는 `accepted`, `Notarized Developer ID`.
- 공개 GitHub 릴리스와 배포 feed는 갱신하지 않았다. 브랜치 코드와 로컬 검증 패키지가 결과물이다.

기존 앱과 설정은 `dist/backup/ClaudeSessionWarmer-0.1.4-build9.app`, `dist/backup/preferences-before-build10.plist`에 백업했다. 이 경로는 Git 제외 대상이다.

기존 앱을 정상 종료하고 `/Applications/ClaudeSessionWarmer.app`에 빌드 10을 설치했다. 실행 파일의 SHA-256은 패키지 앱과 동일하다.

```text
3476a88a73904bee62e5e863169ae18cbe4eb44f14f6dca1acba69ce23afbea4
```

13:43:18의 설치본 실행 기록:

- `launch_id=0030D0ED-CA8A-4ADA-99B5-25C711079B49`, PID `11972`.
- `app.started`: `app_version=0.1.4`, `app_build=10`, 당일 기존 집계 `2` 복원.
- 다음 대상: 2026-09-17 **14:40:00.405**, 세 번째 창.
- `timer.armed`: `clock=wall`, `reason=startup`, `timer_id=E431E020-8C87-4AC6-8517-9CD680B2EE13`.

실제 설치본의 시작·예약 복원은 확인했다. 이 예약이 도래하거나 DarkWake가 발생하기를 기다리지는 않는다. 실제 지연 타이머의 처리·워밍·확인·후속 예약은 위 격리 검증 도구와 회귀 테스트로 확인했다.

## 4. 사용자 실사용 확인

자연스럽게 잠자기에서 복귀하거나 지연 콜백이 전달됐을 때, 같은 실행의 `timer.callback → timer.fired → quota.decision → 필요 시 warmup.requested → window.completed → timer.armed`를 확인한다.

이미 활성인 경우에는 `already_active`와 워밍 호출 0회가 정상이다. 비활성일 때 실제 세션 생성에 성공하는지, DarkWake가 끝나기 전 네트워크·PTY가 완료되는지는 사용자 실사용 검증 대상이다. 미확인 상태이면 추가 전송 없이 복구 대기해야 한다.

네이티브 UI 자동 조회 도구는 시간 초과로 접근하지 못했다. 화면을 확인했다고 보고하지 않으며, 설치 실행·예약 복원은 프로세스와 앱 진단 로그를 근거로 삼았다.
