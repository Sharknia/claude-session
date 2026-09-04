# Claude Session Warmer MVP 테스트 계획

## 1. 목적과 범위

이 문서는 `REQ-001`~`REQ-013`과 `FLOW-001`~`FLOW-013`을 기준으로, MVP가 필요한 창만 안전하게 워밍하고 결과를 설명할 수 있는지 검증한다. 대상은 macOS 14+ SwiftUI 메뉴바 앱, Claude CLI·claude.ai 인증·Keychain, 실행 요일과 한국 공휴일, 일일 자동 3개 창, `five_hour.resets_at` 기반 후속 실행, PTY 최소 호출, 상태·수동 제어·알림·로그인 실행, 서명·공증 DMG다.

실제 절전·덮개 닫힘·종료·로그아웃 중 실행과 놓친 작업의 catch-up은 지원하지 않는다. Claude 서비스 자체의 가용성·과금 정책과 Mac 깨우기는 테스트 범위 밖이다.

## 2. 원칙과 레벨

- **P0**: 중복/불필요 호출, 일일 자동 3창 초과, 인증정보 노출, 실제 5시간 창 불일치, 설치 불가를 막는다. 하나라도 실패 또는 미실행이면 내부 배포를 차단한다.
- **P1**: 상태 표시와 수동 제어의 사용성을 확인한다. 알려진 실패는 영향과 후속 조치가 승인된 경우에만 허용한다.
- **Unit**: 실행일·공휴일·다음 창·T/T+3분 경계와 상태 전이를 순수 계산으로 검증한다.
- **Integration**: fake CLI, fake quota provider, injected Clock으로 호출 횟수와 오케스트레이션을 검증한다.
- **macOS Integration**: Release 빌드로 Keychain, PTY, 잠금/화면 꺼짐, 로그인 실행, 알림을 검증한다.
- **Manual Live Acceptance**: 실제 전용 계정에서 PTY 호출과 `resets_at`의 의미를 한 건으로 검증한다.

자동 시간 테스트는 실제 5시간을 기다리지 않는다. injected `Clock`과 5분짜리 가상 window로 첫 창과 후속 두 창을 재현한다. 실제 약 5시간 확인은 `TC-LIVE-001`에서만 수행한다.

## 3. 환경과 Fixtures

- 내부 검증용 macOS 14+ Apple Silicon Mac, `Asia/Seoul`
- 실제 배포 설정으로 서명한 Release 빌드와 내부 사용 중인 Claude CLI 버전
- `FakeClock`: wall clock 이동, timer 발화, 앱 재시작을 독립 제어
- `FakeCLI`: 정상, non-zero exit, hang, 미설치, 미인증을 반환하고 PTY/argv/stdin/호출 시각을 기록
- `FakeQuotaProvider`: active/idle 창, `resets_at`, 반영 지연, 인증 오류, 429/오프라인, 잘못된 응답을 반환
- 공휴일 fixture: 평일 공휴일, 대체공휴일, 주말 중첩 공휴일. 데이터 출처 버전을 고정
- 자연스럽게 비활성 창이 생긴 내부 Claude 계정. 실제 비밀 값은 증거에 포함하지 않음

표준 자동 시나리오는 첫 T=`09:00`, 재시도 마감=`09:03`, 가상 window=`5분`, 선택 요일=월~금이다.

## 4. 핵심 테스트 케이스

### TC-CORE-001 — 정상 실행일의 자동 3개 창 (P0, Unit+Integration)

- 참조: `REQ-002`, `REQ-004`~`REQ-007`; `FLOW-002`~`FLOW-004`
- 실행: 첫 T와 확인된 `resets_at` 두 번까지 가상 시간을 이동한다.
- 기대: 첫 1회와 후속 2회만 대상이 된다. 각 창은 T 정시 확인 후 필요 시 호출하며, 첫·두 번째 창이 +3분 뒤 실패해도 각각 `targetAt + 5시간` fallback으로 2·3번째 창을 진행한다. 실제 `resets_at`은 항상 fallback보다 우선하고 네 번째 예약/호출은 없다.
- 증거: 날짜·창별 상태, quota 전후 값, CLI 호출 3회의 타임라인과 네 번째 예약 부재.

### TC-CORE-002 — 요일·한국 공휴일·날짜 경계 (P0, Unit)

- 참조: `REQ-002`, `REQ-003`; `FLOW-002`, `FLOW-005`
- 실행: 선택/비선택 요일, 평일 공휴일, 대체공휴일, 자정 전후를 table-driven으로 평가한다.
- 기대: 선택 요일이면서 한국 공휴일이 아닌 현지 날짜만 실행일이다. 비실행일을 지나도 catch-up하지 않고 다음 유효 실행일을 표시한다.
- 증거: 고정 공휴일 dataset 버전과 입력별 next-run 결과.

### TC-CORE-003 — active window는 no-call satisfied (P0, Integration)

- 참조: `REQ-006`, `REQ-007`; `FLOW-003`, `FLOW-006`, `FLOW-013`
- 실행: T 정시/수동 워밍에서 quota provider가 이미 새 창을 반환하게 한다.
- 기대: `충족(사용자 창)`으로 기록하고 CLI 호출은 0회다. timer·수동 요청·앱 재시작이 겹쳐도 같은 창을 다시 처리하지 않는다.
- 증거: 명시적인 spawn-count=0, 창 식별자와 충족 상태.

### TC-CORE-004 — +3분 bounded retry와 dedupe (P0, Integration)

- 참조: `REQ-006`, `REQ-007`; `FLOW-003`, `FLOW-004`, `FLOW-008`, `FLOW-010`
- 실행: quota 반영 지연, CLI 실패/hang, timer·수동 이벤트 동시 도착, T 이후 앱 시작을 주입한다.
- 기대: 재확인은 정시 시도 이력이 있는 경우에만 T~+3분 안에서 끝난다. 메시지 전송 가능 이력의 수동 요청은 quota 확인만 하고, 정시 이력 없는 과거 창은 PTY 없이 `missed`와 fallback으로 처리한다.
- 증거: retry 종료 이유, 최대 동시 프로세스=1, 호출/조회 횟수와 메시지 전송 뒤 호출 0회, +3분 이후 호출 0회, orphan process 없음.

### TC-OS-001 — 잠금 지원과 sleep no-catch-up (P0, Integration+macOS)

- 참조: `REQ-011`; `FLOW-009`, `FLOW-010`
- 실행: (a) system sleep을 막고 화면만 잠근 상태에서 예약을 확인한다. (b) 정시 시도 없이 T+3분 이후 복귀를 재현한다.
- 기대: (a)는 예약과 결과 기록이 정상 동작한다. (b)는 `놓침`과 fallback을 기록하고 PTY를 실행하지 않는다.
- 증거: 잠금 상태 최근 결과와 (b)의 복귀 후 spawn-count=0. 실제 sleep·덮개·종료·로그아웃 동작 보장은 테스트하지 않는다.

### TC-AUTH-001 — CLI·claude.ai 인증·Keychain (P0, Integration+macOS)

- 참조: `REQ-008`; `FLOW-001`, `FLOW-007`
- 실행: 저장 시 Keychain 승인, 자동 no-UI source→cache fallback, 401·만료·cache 부재를 확인한다.
- 기대: access token만 `AfterFirstUnlockThisDeviceOnly` cache에 저장하고 refresh token·UserDefaults·로그에는 남기지 않는다. 401·잠금은 잠금 해제 후 새로고침을 안내한다.
- 증거: 상태 화면, 준비 전 spawn-count=0, Keychain 승인·거부 결과.

### TC-PTY-001 — 최소 대화형 PTY와 실패 정리 (P0, Integration+macOS)

- 참조: `REQ-010`; `FLOW-001`, `FLOW-003`, `FLOW-008`, `FLOW-013`
- 실행: fake와 실제 CLI에서 정상 종료, non-zero exit, hang/취소를 수행한다.
- 기대: pseudo-terminal을 쓰고 `-p`를 쓰지 않는다. 도구 호출, 프로젝트 파일/문맥, 이전 대화, session persistence를 전달하지 않는다. timeout/취소 뒤 프로세스가 남지 않는다.
- 보안 증거: redacted PTY/argv/stdin trace, 종료 후 process scan. argv·env·로그·알림에 토큰, cookie, 프로젝트 내용, 대화 전문이 없어야 한다.

### TC-QUOTA-001 — 비공개 quota 어댑터 격리와 실패 (P0, Unit+Integration)

- 참조: `REQ-005`, `REQ-006`, `REQ-009`; `FLOW-003`, `FLOW-004`, `FLOW-007`, `FLOW-008`
- 실행: 정상 active/idle 응답 외에 인증 오류, 429/오프라인, 필드 누락을 입력한다.
- 기대: raw `/api/oauth/usage` 형식은 어댑터 밖으로 새지 않는다. 새 창을 확정할 수 없으면 충족으로 기록하거나 후속 시각을 추정하지 않고, 오류를 redact해 표시한다.
- 증거: provider contract 결과, scheduler/UI의 raw endpoint 의존성 없음, redacted 오류 로그.

### TC-UI-001 — 상태·수동 제어·알림·로그인 실행 (P1, Integration+macOS)

- 참조: `REQ-001`, `REQ-012`, `REQ-013`; `FLOW-011`, `FLOW-012`, `FLOW-013`
- 실행: draft 변경 후 저장/미저장, 오늘 정지, 다음 한 건 건너뛰기, 수동 워밍, 알림 허용/거부, 로그인 실행 on/off를 확인한다.
- 기대: 오늘 정지는 오늘 남은 미시작 자동 창을 막는다. 다음 건너뛰기는 한 건만 `skipped`로 기록하고 `targetAt + 5시간` fallback으로 후속 창을 이어간다. 활성 주기 중 실제 새 창을 여는 수동 워밍은 다음 창 충족으로 계산한다. 메뉴에 다음 실행·최근 결과·오류가 보이고 로그인 시 단일 인스턴스로 시작한다.
- 증거: 제어 전후 next-run/상태, 호출 ledger, 알림과 process list.

### TC-DIST-001 — 서명·공증 DMG smoke (P0, Deployment)

- 참조: `REQ-001`, `REQ-013`; `FLOW-001`
- 실행: 깨끗한 macOS 14+ 환경에서 DMG를 Gatekeeper로 검증하고 설치·최초 실행·로그인 재실행·제거를 수행한다.
- 기대: Developer ID 서명과 notarization/stapling 검증이 통과하고 경고 우회 없이 메뉴바 앱이 실행된다. 변조한 앱은 검증에 실패한다.
- 증거: 빌드 hash, `codesign`/`spctl`/stapler 검증 결과, 설치·로그인 실행 smoke 기록.

### TC-LIVE-001 — 비활성 창에서 실제 PTY warm과 약 5시간 reset 확인 (P0, Manual Live Acceptance)

- 참조: `REQ-004`~`REQ-010`; `FLOW-003`, `FLOW-004`, `FLOW-006`, `FLOW-008`
- 게이트: **내부 배포 전 blocking gate**다.
- 오늘 실행 불가: 전용 계정에 활성 창이 남아 있거나 비활성 상태를 안전하게 판별할 수 없으면 `Blocked: 오늘 실행 불가`로 기록한다. 이는 통과가 아니며 적합한 조건이 생길 때까지 배포도 blocked다. 계정 상태를 억지로 소모·조작하지 않는다.
- 절차: 호출 전 quota를 기록하고, 최소 대화형 PTY warm 1회 후 bounded retry로 새 창을 확인한다. 같은 대상에 다시 실행해 no-call/dedupe를 확인한다.
- 통과: PTY 호출 정확히 1회, 새 창 확인, `resets_at ≈ call time + 5h`, 중복 시도 추가 호출 0회. 전파·분 단위 반올림 오차는 사전에 ±5분으로 고정한다.
- 실패: 새 창 미확인, 오차 초과, `-p`/도구/문맥 사용, 중복 호출, 증거 누락은 모두 Fail이다. endpoint 문제로 판정 불가해도 Pass가 아니다.
- 증거: redacted 전후 quota, call/확인 타임라인, PTY·argv assertion, CLI exit, 중복 spawn-count.

## 5. 요구사항-흐름-테스트 추적성

| 요구사항 | 관련 흐름 | 검증 테스트 |
|---|---|---|
| `REQ-001` macOS 메뉴바 | `FLOW-001`, `FLOW-011` | TC-UI-001, TC-DIST-001 |
| `REQ-002` 시각·요일 | `FLOW-002`, `FLOW-003` | TC-CORE-001, TC-CORE-002 |
| `REQ-003` 한국 공휴일 | `FLOW-002`, `FLOW-005` | TC-CORE-002 |
| `REQ-004` 자동 최대 3창 | `FLOW-003`, `FLOW-004`, `FLOW-010`, `FLOW-012`, `FLOW-013` | TC-CORE-001, TC-UI-001, TC-LIVE-001 |
| `REQ-005` 실제 `resets_at` | `FLOW-003`, `FLOW-004`, `FLOW-006`, `FLOW-010`, `FLOW-011` | TC-CORE-001, TC-QUOTA-001, TC-LIVE-001 |
| `REQ-006` T 정시 확인 | `FLOW-003`, `FLOW-004`, `FLOW-006` | TC-CORE-001, TC-CORE-003, TC-CORE-004, TC-LIVE-001 |
| `REQ-007` 제한 재시도·중복 방지 | `FLOW-003`, `FLOW-004`, `FLOW-006`, `FLOW-008`, `FLOW-010`, `FLOW-013` | TC-CORE-003, TC-CORE-004, TC-LIVE-001 |
| `REQ-008` CLI·인증 탐지 | `FLOW-001`, `FLOW-003`, `FLOW-007`, `FLOW-008`, `FLOW-011`, `FLOW-013` | TC-AUTH-001 |
| `REQ-009` quota 어댑터 | `FLOW-001`, `FLOW-003`, `FLOW-007`, `FLOW-008` | TC-QUOTA-001, TC-LIVE-001 |
| `REQ-010` 최소 PTY | `FLOW-001`, `FLOW-003`, `FLOW-008`, `FLOW-013` | TC-PTY-001, TC-LIVE-001 |
| `REQ-011` 잠금/화면 꺼짐 | `FLOW-009`, `FLOW-010` | TC-OS-001 |
| `REQ-012` 메뉴·제어·알림 | `FLOW-001`, `FLOW-007`, `FLOW-008`, `FLOW-010`~`FLOW-013` | TC-UI-001 |
| `REQ-013` 로그인·DMG | `FLOW-001` | TC-UI-001, TC-DIST-001 |

최종 병합 때 각 ID의 제목과 의미를 PRD/사용자 흐름 문서와 대조한다. ID만 일치하고 기대 결과가 다르면 추적 완료로 보지 않는다.

## 6. 판정·증거와 배포 게이트

- **Pass**: 기대 결과와 필수 증거가 모두 존재한다.
- **Fail**: 계약과 다르거나 안전 상한·중복 방지를 위반한다.
- **Blocked**: 환경·계정·외부 API로 실행/판정할 수 없다. Pass로 간주하지 않는다.
- 자동 증거에는 fixture/Clock 시작점, 시간대, 창별 상태, quota/CLI 호출 ledger와 spawn-count를 포함한다.
- macOS/수동 증거에는 빌드 hash, OS·CLI·앱 버전, 수행자, 시각, redacted 로그와 필요한 화면 캡처를 포함한다.
- 토큰·cookie·Keychain 값·대화 전문·프로젝트 내용은 저장하거나 증거에 첨부하지 않는다.

내부 배포는 모든 P0 자동/macOS 테스트, secret 확인, `TC-DIST-001`, `TC-LIVE-001`이 Pass일 때만 허용한다. quota/CLI/인증 방식 변경 시 TC-AUTH-001, TC-PTY-001, TC-QUOTA-001, TC-LIVE-001을 재실행하고, scheduler 변경 시 TC-CORE-001~004를 재실행한다.
