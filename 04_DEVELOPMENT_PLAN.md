# Claude Session Warmer MVP 개발 작업 계획서

> 상태: 초안
>
> 개발 판단: **CONDITIONAL GO**
>
> `Claude Session Warmer`는 임시 제품명이다.

## 1. 목표

소수 내부 사용자가 첫 워밍 시각만 정하면 Claude Code의 실제 5시간 리셋 시각을 따라 하루 최대 3개 창을 준비하는 macOS 메뉴바 앱을 만든다.

기존 공개 구현의 원리는 참고하되 Claude에 필요한 기능만 새로 작성한다. 범용 스케줄러나 다중 AI 도구로 확장하지 않는다.

## 2. 기술 스택

| 영역 | 선택 |
|---|---|
| 언어·UI | Swift 6, SwiftUI |
| 지원 OS | macOS 14 이상 |
| 메뉴바 | `MenuBarExtra` |
| Claude 실행 | `Process` + `openpty()` |
| 사용량 조회 | Security.framework + `URLSession` |
| 예약 | one-shot `Timer` |
| 설정 | `UserDefaults` |
| 로그인 실행 | `SMAppService` |
| 알림 | `UserNotifications` |
| 테스트 | XCTest |
| 배포 | Developer ID 서명·공증 DMG |

서버, 데이터베이스, 외부 런타임 의존성은 사용하지 않는다.

## 3. 최소 코드 구조

```text
ClaudeSessionWarmer/
├── ClaudeSessionWarmerApp.swift
├── AppState.swift
├── ScheduleEngine.swift
├── ClaudeService.swift
├── MenuContent.swift
├── Resources/kr-holidays.json
└── Tests/
```

- `AppState`: 화면 상태, 사용자 설정, 오늘 처리 횟수 관리
- `ScheduleEngine`: 다음 실행일, 첫 시각, 실제 `resets_at`, 3분 재시도 범위 계산
- `ClaudeService`: CLI·인증 확인, Keychain 사용량 조회, PTY 워밍
- `MenuContent`: 메뉴바 표시와 사용자 제어

추가 계층은 실제 중복이 확인되기 전에는 만들지 않는다. 테스트에서는 시간·사용량·CLI 결과를 간단한 클로저 또는 작은 프로토콜로 교체한다.

## 4. 확정 실행 규칙

1. 사용자가 첫 워밍 시각 하나와 실행 요일을 설정한다.
2. 앱에 포함한 2026~2027년 대한민국 공휴일에는 실행하지 않는다.
3. 첫 시각 T 전에는 아무 동작도 하지 않고, T에 CLI·인증·네트워크와 활성 창을 확인한다.
4. 활성 창이 없으면 PTY 최소 호출을 한 번 보내고, 이미 있으면 호출 없이 첫 창을 충족 처리한다.
5. 실제 `five_hour.resets_at`을 다음 실행 기준으로 우선 저장하고, 없으면 실패·놓침·건너뛴 `targetAt + 5시간`을 fallback으로 쓴다.
6. 후속 예정 시각 T에 다시 확인하여 필요할 때만 워밍한다.
7. 정시 시도 이력이 있는 오류만 T부터 +3분까지 재확인하며, 메시지 전송 가능성이 있으면 모델을 재호출하지 않는다.
8. 첫 창과 후속 두 창, 총 3개를 처리하면 그날 종료한다.
9. 다음 실행일의 첫 시각에 새 일일 주기를 시작한다.

`다음 워밍 건너뛰기`는 한 창만 `skipped`로 기록하고 `targetAt + 5시간` fallback으로 후속 창을 잇는다. 놓친 예약은 소급 실행하지 않는다.

## 5. PTY 워밍 후보

앱은 API 과금으로 경로를 바꿀 수 있는 환경변수를 제거하고, 격리된 임시 디렉터리에서 Claude Code를 실행한다.

후보 설정:

- `CLAUDE_CODE_SKIP_PROMPT_HISTORY=1`
- `--safe-mode`
- `--tools ""`
- `--model haiku`
- `--effort low`
- 짧고 고정된 응답을 요구하는 프롬프트

`claude -p`와 `--bare`는 사용하지 않는다. 성공 표식을 확인하면 대화형 세션을 정상 종료하고, 정해진 시간 안에 끝나지 않으면 실패 처리한다.

현재 로컬에서 확인한 사실:

- Claude Code 2.1.258 설치
- `claude.ai` / first-party / Max 구독 인증
- `--safe-mode`, 도구 비활성화, low effort, 기록 비저장 상태에서 `Claude Max`로 기동
- `--bare`는 `API Usage Billing`으로 표시되어 후보에서 제외
- 비활성 창에서 실제 5시간 창을 여는 라이브 검증은 아직 미실시

## 6. 개발 작업

| ID | 작업 | 관련 요구사항 | 완료 조건 |
|---|---|---|---|
| TASK-001 | Xcode 메뉴바 앱과 테스트 타깃 생성 | REQ-001, REQ-013 | 메뉴바에서 실행되고 `xcodebuild test` 가능 |
| TASK-002 | 첫 시각·요일·한국 공휴일·하루 3창 계산 | REQ-002, REQ-003, REQ-004, REQ-005, REQ-006 | 가짜 시간으로 정상일·휴일·실패 fallback 포함 3창 테스트 통과 |
| TASK-003 | CLI 탐지, 구독 인증 확인, Keychain 사용량 조회 | REQ-008, REQ-009 | 설치·인증·active/idle·401/429 판정 가능 |
| TASK-004 | PTY 최소 워밍 실행 | REQ-007, REQ-010 | 가짜 CLI에서 1회 입력·성공·timeout·종료 검증 |
| TASK-005 | 예약과 중복 방지 연결 | REQ-004, REQ-005, REQ-006, REQ-007, REQ-011 | 정시 이력 기반 +3분, missed fallback, 하루 3창 동작 |
| TASK-006 | 메뉴바 설정·상태·수동 제어·알림 | REQ-002, REQ-012 | 핵심 상태와 제어를 한 화면에서 사용 가능 |
| TASK-007 | 로그인 실행과 최근 결과 저장 | REQ-011~REQ-013 | 재실행 후 설정·처리 횟수 복원, 민감정보 미저장 |
| TASK-008 | 통합 테스트, 라이브 검증, DMG 배포 | REQ-001~REQ-013 | P0 테스트와 라이브 게이트 통과 후 공증 DMG 설치 |

## 7. 구현 순서

```text
TASK-001
→ TASK-002와 TASK-003 병행
→ TASK-004
→ TASK-005
→ TASK-006과 TASK-007
→ TASK-008
```

UI 시안, 자동 업데이트, 다중 제공자 구조, 복잡한 재시도 프레임워크는 만들지 않는다.

## 8. 테스트 범위

자동화 테스트는 다음에 한정한다.

- 선택 요일과 한국 공휴일 제외
- 첫 창 + 후속 2개 후 종료
- 실제 `resets_at` 우선, `targetAt + 5시간` fallback 다음 예약
- 활성 창이면 Claude 호출 0회
- 동일 창 중복 호출 방지
- +3분 이후 재시도 금지
- 앱 재시작 후 처리 횟수 복원
- 잠자기로 놓친 실행의 no-catch-up
- CLI·인증·Keychain·네트워크·PTY 실패 분류

수동 검증은 다음에 한정한다.

- 화면 잠금 상태 예약 실행
- 로그인 실행
- DMG 설치 및 제거
- 비활성 창 라이브 워밍

## 9. 배포 전 필수 게이트

비활성 5시간 창이 생긴 자연스러운 시점에 다음을 한 번 검증한다.

1. 호출 전 활성 창이 없음을 확인한다.
2. PTY 워밍을 정확히 한 번 실행한다.
3. 일반 Claude 구독 사용량에 활성 창이 생겼는지 확인한다.
4. 실제 `resets_at`이 호출 시각에서 약 5시간 뒤인지 확인한다.
5. API 과금이나 별도 Agent SDK 사용량으로 처리되지 않았는지 확인한다.

이 게이트 전까지 구현 판단은 `CONDITIONAL GO`다. 실패하면 PTY 인자와 모델만 재검토하며 웹 UI 자동화나 별도 서버를 우회책으로 추가하지 않는다.

## 10. MVP 완료 정의

- 지정한 실행일과 첫 시각에 일일 주기를 시작한다.
- 실제 리셋 시각을 따라 하루 최대 3개 창만 관리한다.
- 필요한 경우에만 창당 한 번의 PTY 호출을 수행한다.
- 공휴일, 오늘 정지, 다음 건너뛰기, 수동 워밍이 확정 정책대로 동작한다.
- 화면 잠금 상태에서 동작하며 실제 잠자기로 놓친 실행은 따라잡지 않는다.
- 실패 이유와 다음 실행 시각을 메뉴바에서 확인할 수 있다.
- 라이브 게이트와 핵심 자동화 테스트가 통과한다.
- 서명·공증된 DMG를 내부 Mac에 설치할 수 있다.
