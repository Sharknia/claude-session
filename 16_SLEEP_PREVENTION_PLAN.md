# 잠자기 방지 기능 설계 명세서

작성일: 2026-10-02 (Asia/Seoul)

상태: 구현 완료(브랜치 Sharknia/anti-sleep). 이 문서는 구현 계획을 바로 세울 수 있도록 결정 사항만 적는다. 선택지는 4장에서 비교하고 하나로 확정했으며 미정 항목은 없다.

기준 코드: `7730880d166334676a547a24c52feb606a4d79bb` (main, 0.1.7 / 빌드 13). 적용 배포는 다음 버전(0.1.8 / 빌드 14)이며 `packaging/Info.plist`의 버전·빌드 갱신은 배포 단계에서 수행한다.

진행 방식: 구현은 `Sharknia/anti-sleep` 브랜치에서 한다. 구현 전 10장의 사전등록 조건을 이슈 코멘트로 남기고, 구현 후 같은 조건으로 판정한다. 관리자 권한·특권 helper·`pmset` 설정 변경은 사용하지 않는다.

## 1. 목적과 범위

**예약 워밍이 실행돼야 하는 시간대에 Mac이 유휴 상태를 이유로 잠들지 않게 한다.** 그동안 [01 PRD](01_PRD.md)와 [README](README.md)는 "예약 실행을 위해 Mac이 깨어 있어야 한다"를 사용자 책임으로 두었다. 이번 기능은 그 책임의 일부를 앱이 맡되, OpenAI Codex 데스크톱 앱과 같은 방식(유휴 시스템 잠자기 방지 어서션 하나)만 사용한다.

| 구분 | 내용 |
| --- | --- |
| 되는 것 | 설정 `잠자기 방지` 하나(`끔` 기본값 / `예약 전후만` / `상시`). 유휴로 인한 시스템 잠자기(idle sleep)만 막는다. 디스플레이 꺼짐·화면 잠금은 그대로 일어난다. |
| 되는 것 | `예약 전후만`: 다음 예약 워밍 30분 전부터 워밍·활성화 확인이 끝날 때까지 유지. 전원 상태와 무관(배터리에서도 적용). |
| 되는 것 | `상시`: 전원 어댑터 연결 중에는 앱 실행 중 계속 유지하고, 배터리에서는 `예약 전후만`과 같은 구간(다음 워밍 30분 전부터 확인 완료까지)만 유지. 배터리로 바뀌면 예약 구간 밖에서 해제, 다시 연결되면 재획득. |
| 되는 것 | 어서션 획득·해제·실패를 진단 로그에 남기고, `pmset -g assertions`에서 앱 이름으로 식별할 수 있게 한다. |
| 안 되는 것 | Apple 메뉴 잠자기, 저전력, 예약된 잠자기 등 유휴 외 원인의 잠자기 차단. IOKit 헤더가 명시한 한계다(4.1). |
| 안 되는 것 | 덮개 닫힘 처리는 범위 밖이다. |
| 안 되는 것 | 잠든 Mac 깨우기(`pmset schedule`, `caffeinate -u` 포함), 디스플레이 켜 두기, 화면 잠금 방지. |
| 안 되는 것 | 관리자 권한, 특권 helper, `pmset disablesleep`, 전원 설정 변경. |
| 안 되는 것 | 배터리 잔량 감시, 저전력 자동 해제, 경고 UI, 보유 시간 상한. 사용자가 "배터리는 유저 책임"으로 확정했다. |
| 안 되는 것 | 메뉴 상태 표시·알림에 어서션 보유 여부 추가. 확인 수단은 `pmset -g assertions`와 진단 로그다. |
| 안 되는 것 | 저장 형식 버전 번호 변경, 새 저장 파일·키 추가. 기존 `ScheduleSettings` 레코드에 필드 하나만 추가한다. |

## 2. 요구사항

| ID | 요구사항 | 수용 기준 |
| --- | --- | --- |
| SP-01 | 설정 항목은 `잠자기 방지` 하나이고 값은 `끔`·`예약 전후만`·`상시`다. 기본값은 `끔`이다. | 새 설치, 구버전에서 업데이트, 저장된 값이 없는 모든 경우에 `끔`으로 읽힌다. |
| SP-02 | `예약 전후만`은 `nextEvent.date − 30분 ≤ 현재` 또는 워밍·활성화 확인 진행 중(`isWorking`)이면 어서션을 쥔다. 그 외에는 쥐지 않는다. | 3.2 판정표의 모든 행이 단위 테스트로 고정된다. |
| SP-03 | `예약 전후만`은 전원 상태를 보지 않는다. | 배터리 입력으로도 SP-02 결과가 같다. |
| SP-04 | `상시`는 전원 어댑터 연결 중(`AC Power`)이거나 SP-02의 조건이 성립하면 어서션을 쥔다. 배터리·UPS·조회 실패에서는 SP-02 조건만 적용된다. `상시`는 `예약 전후만`의 상위 집합이다. | 전원 변경 알림 뒤 다음 재평가에서 상태가 바뀌고, 배터리에서의 결과는 같은 입력의 `예약 전후만`과 같다. |
| SP-05 | 어서션은 `PreventUserIdleSystemSleep` 한 종류만 사용한다. 디스플레이·디스크·네트워크 어서션은 만들지 않는다. | `pmset -g assertions`에 앱 pid의 어서션이 이 종류 하나만 보인다. |
| SP-06 | 획득·해제는 상태에서 매번 재계산한 결과와 현재 보유 여부가 다를 때만 수행한다. 짝 맞추기 방식의 획득/해제 호출을 두지 않는다. | 어떤 공개 상태 변경 뒤에도 `isHeld == shouldHold(현재 입력)`이 성립한다(10.2 불변식 테스트). |
| SP-07 | 재시도가 이어지는 날(`retryAt` 30초·5분 간격)에는 `예약 전후만`도 재시도가 끝날 때까지 유지한다. 상한은 없다. | 재시도 이벤트의 `date`는 항상 30분 이내이므로 SP-02로 자연히 성립한다. |
| SP-08 | 획득 실패는 진단 로그에 남기고 다음 재평가 트리거에서 다시 시도한다. 별도 재시도 타이머는 두지 않는다. | `sleep_prevention.acquire_failed` 로그와 그다음 트리거의 재획득이 테스트로 고정된다. |
| SP-09 | 앱 종료·크래시·업데이트 재시작·중복 실행 차단에서 어서션이 남지 않는다. | 프로세스 종료 시 OS가 해제한다. 중복 실행·비정식 경로에서는 `AppState`가 만들어지지 않으므로 어서션 자체가 생기지 않는다. |
| SP-10 | 저장 형식 호환: 0.1.7 이하가 새 레코드를 읽고 다시 저장해도 실행이 막히지 않는다. 그 과정에서 이 설정만 `끔`으로 돌아가는 것은 수용한다. | `schemaVersion`·`minimumReaderVersion`은 1을 유지한다(7장). |
PRD에는 `REQ-014`로, 사용자 흐름에는 `FLOW-014`로, 테스트 계획에는 `TC-SLEEP-001`로 연결한다(11장).

## 3. 동작 규칙과 판정표

### 3.1 판정 함수

"지금 어서션을 쥐어야 하는가"는 순수 함수 하나가 결정한다. 입력은 다섯 개다. 차단 여부는 입력이 아니다(3.5).

| 입력 | 출처 | 비고 |
| --- | --- | --- |
| `mode` | `AppState.settings.sleepPrevention` | 손상된 설정은 초안 기본값이 쓰이므로 `끔`이다(3.5). |
| `now` | `AppState.clock()` | 테스트에서 주입하는 가짜 시계와 같은 것 |
| `nextEventDate` | `AppState.nextEvent?.date` | `targetAt`이 아니라 타이머가 실제로 발화하는 `date`를 쓴다. 재시도 시각이 여기에 들어온다. |
| `isWorking` | `AppState.isWorking` | 예약 워밍(`performScheduledWarmup`), 수동 워밍(`manualWarmup`), 로그인(`connectClaude`) 모두 이 플래그를 세운다. `isSilentRefreshRunning`(조용한 사용량 조회)은 포함하지 않는다. |
| `isOnACPower` | `PowerSource.isOnACPower()` | `AC Power`일 때만 참 |

판정표:

| `mode` | 조건 | 결과 |
| --- | --- | --- |
| `끔` | 모든 경우 | 쥐지 않음 |
| `예약 전후만` | `isWorking == true` | 쥠 |
| `예약 전후만` | `nextEventDate != nil` 이고 `nextEventDate − 30분 ≤ now` | 쥠 |
| `예약 전후만` | 그 외(`nextEventDate == nil` 또는 30분보다 멀리 있음) | 쥐지 않음 |
| `상시` | `isOnACPower == true` | 쥠 |
| `상시` | `isOnACPower == false` 이고 `예약 전후만`의 두 조건 중 하나가 성립 | 쥠 |
| `상시` | `isOnACPower == false` 이고 그 외 | 쥐지 않음 |

`상시`는 `예약 전후만`의 상위 집합이다. 전원 연결 중에는 다음 예약이 없어도, 차단 상태여도 예외 없이 쥐고, 배터리에서는 같은 입력의 `예약 전후만`과 같은 결과를 낸다. 이 결정의 근거는 4.5에 있다.

`isWorking`을 "진행 중" 신호로 쓰는 이유: 이미 일정 변경을 막는 단일 게이트이고(`scheduleNext` 369행, `reconcileSchedule` 411행), 워밍 시작부터 활성화 확인 루프(`checkSession` 619~638행)의 종료까지 정확히 참이다. 수동 워밍·로그인 중에도 참이 되지만 두 동작은 사용자가 Mac 앞에 있을 때 일어나므로 유지 시간이 1~2분 늘어나는 것 외에 영향이 없다.

### 3.2 `nextEvent`의 각 경우와 "30분 이내" 판정

`ScheduleEngine.nextEvent`(72~99행)와 `AppState.arm`·`handleTargetFailure`가 돌려주는 `date`별로 `예약 전후만`의 판정이 어떻게 되는지 정리한다. 모든 행은 `isWorking == false`를 전제로 한다.

| 경우 | 코드 근거 | `nextEvent.date` | 30분 이내 판정 |
| --- | --- | --- | --- |
| 오늘 첫 예약 전 | `ScheduleEngine` 89행 `max(now, first, target, …)` → `first` | 첫 예약 시각 | `first − 30분 ≤ now`일 때만 참. 그 전에는 거짓이고 선행 타이머가 `first − 30분`에 재평가한다. |
| 첫 예약이 지났고 미처리 | 89행의 `max`가 `now` | 현재 시각 | 참. `handle`이 시작되어 `isWorking`이 켜질 때까지 유지된다. |
| 후속 창 대기(`nextResetAt` 미래) | 83행 `target = cycle.nextResetAt` | 확인된 실제 리셋 시각 | `nextResetAt − 30분 ≤ now`일 때 참 |
| 후속 창 지남(`nextResetAt` 과거) | 89행의 `max`가 `now` | 현재 시각 | 참 |
| 재시도 대기 | `handleTargetFailure` 744행 `retryAt = now + 30초` 또는 `+ 300초`; 89행 `retryAt ?? target` | 재시도 시각 | 항상 참(최대 5분 뒤). 재시도가 이어지는 동안 끊기지 않는다(SP-07). |
| 재시도 불가로 당일 일시정지 | 85행 `paused = failure.retryAt == nil` → 94~98행 다음 실행일 | 다음 유효 실행일의 첫 예약 | 그 시각 − 30분 ≤ now일 때만 참. 보통 거짓이므로 해제된다. |
| 하루 3창 완료·비실행일·복구 중지일(`recoveryHoldDayKey`) | 81~82행 조건 불충족 → 94~98행 | 다음 유효 실행일의 첫 예약 | 위와 같음 |
| 다음 리셋이 내일 | 86행 `dayKey(for: target) == today` 거부 → 94~98행 | 다음 유효 실행일의 첫 예약 | 위와 같음 |
| 작업 중 콜백 재예약 | `handle` 504행 `arm(event, at: now + 5)` | 현재 + 5초 | 참(이때는 `isWorking`도 참) |
| 조기 콜백 재예약 | `handle` 500행 `arm(event, at: event.date)` | 원래 예약 시각 | 첫 행과 같음 |
| `nextEvent == nil` | 유효 실행일 없음(95~97행), `refreshExecutionPermission` 차단(114행), `scheduleNext` 결과 없음(378행) | 없음 | 거짓. `isWorking`만 적용된다. `상시`+전원 연결은 이 경우에도 쥔다(3.5). |

예시 타임라인(`예약 전후만`, 첫 예약 06:00, 실제 리셋 11:00):

| 시각 | 사건 | 어서션 |
| --- | --- | --- |
| 05:29 | 앱 시작. `nextEvent.date = 06:00`, 30분보다 멀다. | 미보유. 선행 타이머를 05:30에 건다. |
| 05:30 | 선행 타이머 발화 → 재평가 | 획득 |
| 06:00 | `timer.fired` → `isWorking = true` | 유지 |
| 06:01 | 활성화 확인 완료 → `complete` → `scheduleNext`(700행). `isWorking`이 참이라 `needsFreshSchedule`만 세우고 `nextEvent`는 바꾸지 않는다(369~374행) | 유지(`isWorking` 참, `nextEvent.date`는 아직 06:00) |
| 06:01 | `finishWorking` 416행 `isWorking = false` → 재평가 | 유지. `nextEvent.date`가 지난 06:00이라 30분 이내 판정이 여전히 참이다. |
| 06:01 | `finishWorking` → `reconcilePendingSchedule` → `scheduleNext` → `nextEvent.date = 11:00` | 해제(`trigger=schedule_changed`). 선행 타이머를 10:30에 건다. |
| 06:00 (실패 분기) | 조회 실패 → `retryAt 06:00:30` → `nextEvent.date = 06:00:30` | 유지 |
| 06:02 (실패 분기) | 4번째 실패 → `retryAt 06:07` | 유지 |
| 06:07 (실패 분기) | 인증 거부 등 재시도 불가 → `nextEvent` = 내일 06:00 | 해제 |

Mac이 05:30 이전에 이미 잠들어 있으면 선행 타이머는 깨어난 뒤에 발화한다(`WallClockTimer`는 실제 시각 기준이며 잠든 시간을 더하지 않는다). 이 기능은 깨어 있는 Mac이 잠들지 않게 하는 것이며 잠든 Mac을 깨우지 않는다.

### 3.3 전원 상태

| `IOPSGetProvidingPowerSourceType` 결과 | 판정 | 비고 |
| --- | --- | --- |
| `"AC Power"` (`kIOPMACPowerKey`) | AC 연결 | 배터리 없는 데스크톱 Mac도 이 값이다. `상시`는 데스크톱에서 항상 유지된다. |
| `"Battery Power"` | 배터리 | `상시`는 예약 구간(SP-02 조건)만 유지한다. |
| `"UPS Power"` | AC 아님 | 헤더가 "제한된 전원"으로 분류한다. `상시`는 배터리와 같이 예약 구간만 유지한다. |
| 조회 실패(`nil`) | AC 아님 | 드문 오류 경로. 보수적으로 배터리와 같이 취급해 `상시`는 예약 구간만 유지한다. |

전원 변경은 `kIOPSNotifyPowerSource`(`com.apple.system.powersources.source`) 알림으로 받는다. 이 키는 배터리 잔량 변화에는 오지 않고 전원 공급원이 바뀔 때만 온다.

### 3.4 재평가 트리거

재평가는 다음 여섯 지점에서 일어난다. 모두 같은 함수 `reevaluateSleepPrevention(trigger:)`를 부른다.

| 트리거 문자열 | 발생 지점 | 설명 |
| --- | --- | --- |
| `startup` | `AppState.init`의 `defer`(92행 `if startScheduler` 블록 앞에 선언) | 초기 상태 반영. 98행의 조기 `return`(차단 시)을 거쳐도 실행된다. |
| `settings_changed` | `settings`의 `didSet` | `applySettings`, `adoptStoredState`, `applyLaunchAtLogin`, `syncLaunchAtLoginStatus` 모두 포함 |
| `schedule_changed` | `nextEvent`의 `didSet` | `scheduleNext`, `arm`, `handleTargetFailure`, `refreshExecutionPermission`(nil 대입) 모두 포함 |
| `working_changed` | `isWorking`의 `didSet` | 워밍·수동·로그인의 시작과 `finishWorking` |
| `power_source_changed` | `PowerSourceObserver` 콜백 | 메인 큐로 전달 |
| `lead_time` | 선행 타이머(`WallClockTimer`) | `nextEvent.date − 30분` |

`didSet`을 쓰는 이유는 4.3에 있다. 재평가는 멱등이며 상태가 바뀔 때만 IOKit을 호출하고 로그를 남긴다.

### 3.5 특수 상태

| 상황 | 코드 근거 | 동작 |
| --- | --- | --- |
| 예약 설정 손상(복구 화면) | `SettingsStore.loadSettings` 65행이 `ScheduleSettings()` 초안을 돌려준다 | 유효 모드가 `끔`이므로 쥐지 않는다. 사용자가 초안을 저장해 복구하면 `adoptStoredState`(185행)가 `settings`를 다시 대입해 `settings_changed`로 재평가되고 저장한 값이 적용된다. |
| 차단 상태(`operationBlockReason != nil`: 실행 기록 손상·미지원 형식·구버전 실행 감지), 다음 유효 예약 없음(`nextEvent == nil`) | `refreshExecutionPermission` 113~114행 타이머 취소·`nextEvent = nil`; `ScheduleEngine` 95~97행 | 규칙에 예외를 두지 않는다. 결과는 규칙에서 자연히 따라 나온다. `예약 전후만`은 `nextEvent == nil`이라 진행 중 작업이 끝나면 쥐지 않고, `상시`+전원 연결은 쥔다. 사용자가 `상시`를 골랐다면 그대로 유지하는 것이 의도에 맞고, 다음 예약 없음·차단 상태는 극히 드문 예외라 별도 규칙과 재평가 경로를 추가할 가치가 없다. 차단 진입은 114행의 `nextEvent = nil` 대입이, 해제는 `adoptStoredState`의 `settings` 대입(185행)과 이어지는 `reconcileSchedule`이 재평가를 일으킨다. |
| `/Applications` 밖에서 실행 | `ApplicationRuntime.init` 56~57행이 차단 메시지를 만들고 96~98행이 `state = nil` | `AppState`가 없으므로 어서션 자체가 없다. |
| 중복 실행(두 번째 프로세스) | `ApplicationRuntime.init` 64~72행 `exit(0)` | `AppState` 생성 전에 종료한다. 어서션 없음. |
| 정상 종료·크래시·`kill -9` | IOKit 어서션은 프로세스 단위로 powerd가 관리한다 | 프로세스가 사라지면 OS가 해제한다. 앱 코드의 추가 처리 없음. `deinit`의 해제는 테스트 정리를 위한 것이다. |
| Sparkle 업데이트 재시작 | `AppUpdater`는 `hasActiveOperation`이 꺼진 뒤에만 설치·재시작한다 | 구 프로세스 종료로 해제, 새 프로세스가 시작하면서 재획득(정상 시작에서는 일정 계산의 `nextEvent` 대입이 먼저 쥐므로 로그의 트리거는 `schedule_changed`일 수 있다). 재시작 사이 수 초 동안 공백이 생기며 수용한다. |
| 워밍 중 설정 저장 | `applySettings` 159행 `scheduleRevision += 1` | 기존 동작과 같다. 진행 중 `checkSession`은 조회를 한 번 다시 하거나 재시도로 넘어간다. 잠자기 방지 값만 바꿔도 같은 경로를 타며, 특수 처리를 추가하지 않는다. |
| Dark Wake 중 | IOKit 헤더: "This assertion has no effect if the system is in Dark Wake." | 어서션은 전체 깨어남(full wake) 상태만 유지한다. Dark Wake에서 지연 콜백이 실행되는 기존 동작은 바뀌지 않는다. |

## 4. 기술 결정

### 4.1 어서션 API: `IOPMAssertionCreateWithName` (확정)

| 비교 항목 | `IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep)` | `ProcessInfo.processInfo.beginActivity(options: .idleSystemSleepDisabled, reason:)` |
| --- | --- | --- |
| 실패 관찰 | `IOReturn`을 돌려준다. `kIOReturnSuccess` 외는 실패로 로그에 남길 수 있다. | 반환값이 토큰 객체뿐이다. 실패를 알 수 없다. |
| `pmset -g assertions` 표시 | 이름을 직접 지정한다(128자 이내). `PreventUserIdleSystemSleep named: "<이름>"`으로 보인다. | Foundation이 reason 문자열로 이름을 만든다. 종류 매핑은 Foundation의 구현에 맡겨진다. |
| Codex와의 동일성 | 이 Mac에서 실행 중인 Electron 앱(ChatGPT)이 `pmset -g assertions`에 `NoIdleSleepAssertion named: "Electron"`으로 보인다. `kIOPMAssertionTypeNoIdleSleep`은 IOPMLib.h 1026~1030행에서 `PreventUserIdleSystemSleep`의 10.7 이전 별칭으로 명시돼 있다. 즉 Electron `powerSaveBlocker('prevent-app-suspension')`은 이 API와 이 종류를 쓴다. | 결과 종류는 같지만 호출 계층이 다르다. |
| 권한·entitlement | IOPMLib.h 757~781행(`IOPMAssertionCreateWithName` 설명): "No special privileges are necessary to make this call - any process may activate a power assertion." 앱은 샌드박스가 아니며(`scripts/prepare-keychain-signing.py` 43~47행이 만드는 entitlements는 application-identifier·team-identifier·keychain-access-groups 세 개) hardened runtime(`--options runtime`)은 전원 어서션을 제한하지 않는다. `Info.plist`·entitlements 변경 없음. | 같음 |
| Swift 접근 | `import IOKit.pwr_mgt`. 기준 SDK(MacOSX26.5)에서 타입체크 확인. | Foundation |

확정: `IOPMAssertionCreateWithName`. 이름은 `"ClaudeSessionWarmer sleep prevention"`(ASCII, 상수 하나). 모드별 이름을 나누지 않는다. 모드가 바뀌어도 어서션을 해제·재획득하지 않기 위해서이며, 모드는 진단 로그 메타데이터로 남긴다.

헤더가 명시한 이 어서션의 한계를 그대로 문서화한다(IOPMLib.h 276~292행): "The display may dim and idle sleep while PreventUserIdleSystemSleep is enabled, but the system may not idle sleep. The system may still sleep for lid close, Apple menu, low battery, or other sleep reasons. This assertion has no effect if the system is in Dark Wake."

### 4.2 전원 어댑터 감지: `IOPSGetProvidingPowerSourceType` + `kIOPSNotifyPowerSource` (확정)

| 방법 | 판단 |
| --- | --- |
| `IOPSCopyPowerSourcesInfo()` 스냅숏 → `IOPSGetProvidingPowerSourceType(snapshot)` == `kIOPMACPowerKey` | 채택. 헤더(IOPowerSources.h 307~317행)가 반환값을 세 문자열로 한정한다. 데스크톱 Mac도 `AC Power`를 돌려준다. |
| 변경 알림: `notify_register_dispatch(kIOPSNotifyPowerSource, &token, .main) { _ in … }` | 채택. IOPowerSources.h 131~147행: 전원 공급원이 바뀔 때만 오고 잔량 변화에는 오지 않는다("more efficient choice for clients only interested in differentiating AC vs Battery"). Swift에서는 `import notify`가 필요하며 기준 SDK에서 타입체크 확인. 해제는 `notify_cancel(token)`. |
| 변경 알림 대안: `IOPSNotificationCreateRunLoopSource` | 기각. 전원 소스 속성(잔량·시간 등)이 바뀔 때마다 호출된다(IOPowerSources.h 120행 주석이 `kIOPSNotifyPowerSource`를 권장). |
| `pmset -g batt` 주기 실행, `NSWorkspace` 알림 | 기각. 전원 공급원 알림이 없거나 프로세스 생성이 필요하다. |

전원 조회는 콜백 안에서 캐시하지 않고 재평가마다 다시 읽는다. 알림 누락이 있어도 다음 트리거에서 바로잡힌다.

### 4.3 재평가 트리거: `@Published` 프로퍼티의 `didSet` (제안에서 변경)

제안은 "기존 일정 재계산 지점에서 함께 재평가"였다. 코드를 보면 `nextEvent`를 바꾸는 지점이 `scheduleNext`(377행), `arm`(447행), `refreshExecutionPermission`(114행), `handleTargetFailure`(762행)로 나뉘고, `isWorking`은 네 곳(222·311·416·523행)에서 바뀐다. 지점을 하나라도 빠뜨리면 어서션이 늦게 해제된다.

대신 `settings`·`nextEvent`·`isWorking` 세 프로퍼티에 `didSet { reevaluateSleepPrevention(trigger:) }`를 붙인다. 이 세 값이 판정 입력의 전부이므로(전원·시각 제외) 호출 지점을 찾을 필요가 없고, 앞으로 일정 코드가 바뀌어도 재평가가 빠지지 않는다.

확인한 사실: Swift 6 툴체인(기준 SDK)에서 `@Published var x: T? { didSet { … } }`는 메서드 안의 대입뿐 아니라 `init` 안의 직접 대입에서도 `didSet`을 호출한다(기본값이 있는 프로퍼티는 wrapper setter를 거친다). 따라서 구현 시 다음을 지킨다.

- 새 저장 프로퍼티(`sleepAssertion`, `isOnACPower`)는 `AppState.init`의 첫 블록(현재 62~70행, `settings = …` 71행보다 앞)에서 초기화한다. `init` 80행 `syncLaunchAtLoginStatus()`가 `settings`를 대입하면 `didSet`이 바로 실행된다.
- `init`에서 `defer`로 `reevaluateSleepPrevention(trigger: "startup")`를 한 번 명시 호출한다(위치는 3.4·5.3). 차단 시 조기 `return`해도 실행되며, `didSet`이 먼저 실행됐더라도 멱등이므로 문제없다.
- 선행 타이머 생성은 `arm`(455행)과 같이 `schedulerEnabled`로 가드한다. 단위 테스트는 가짜 시계를 옮긴 뒤 `reevaluateSleepPrevention(trigger: "lead_time")`를 직접 부른다.

### 4.4 저장 형식: 비선택 프로퍼티 + 커스텀 `init(from:)` (제안에서 변경)

제안은 "선택 필드(`Optional`)로 추가, 값이 없으면 `끔`"이었다. JSON 키는 선택으로 두되 Swift 프로퍼티는 비선택으로 한다.

```swift
struct ScheduleSettings: Codable, Equatable, Sendable {
    var firstWarmupMinutes: Int
    var weekdays: Set<Int>
    var excludeKoreanHolidays: Bool
    var launchAtLogin: Bool
    var sleepPrevention: SleepPreventionMode   // 비선택. 없으면 .off

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        firstWarmupMinutes = try container.decode(Int.self, forKey: .firstWarmupMinutes)
        weekdays = try container.decode(Set<Int>.self, forKey: .weekdays)
        excludeKoreanHolidays = try container.decode(Bool.self, forKey: .excludeKoreanHolidays)
        launchAtLogin = try container.decode(Bool.self, forKey: .launchAtLogin)
        // 0.1.7 이하가 쓴 레코드와 버전 없는 구형 레코드에는 이 키가 없다. 없으면 끔.
        sleepPrevention = try container.decodeIfPresent(SleepPreventionMode.self, forKey: .sleepPrevention) ?? .off
    }
    // encode(to:)는 합성을 유지한다. 항상 키를 쓴다.
}
```

이유: "값이 없으면 끔" 규칙이 한 곳에만 있고, 판정 함수·메뉴 초안·`Equatable` 비교에서 `?? .off`가 사라진다. `encode(to:)`는 합성 그대로 두어 `.off`도 키로 기록한다(키 집합이 결정적이고 `testPersistedModelsContainOnlyExpectedFields`가 그대로 유효하다). 호환성 결론은 7장에 있다.

### 4.5 `상시`의 판정: 전원 연결 또는 예약 구간 (확정)

사용자의 최종 지시는 "Codex와 같으면 된다"이다. Codex 번들의 실제 판정은 `preventSleepWhileRunning`의 요청과 `keepRemoteControlAwakeWhilePluggedIn`의 요청(`!powerMonitor.isOnBatteryPower()` 조건)의 합집합이며, 두 설정은 서로 독립인 토글이다. 이 앱의 설정은 단일 선택이므로 `상시`가 두 토글을 모두 켠 상태에 대응해야 한다. 따라서 `상시 = isOnACPower || (예약 전후만의 조건)`으로 확정한다. 이름 그대로 `상시`는 `예약 전후만`의 상위 집합이고, 배터리에서 `예약 전후만`보다 약한 구간이 생기지 않는다. "전원 연결 중일 때만"으로 한정한 초안은 Codex의 두 토글 중 하나에만 대응해 `상시`가 `예약 전후만`보다 약해지는 구간을 만들었으므로 기각했다. 전원 연결 중에는 `isWorking`·`nextEventDate`가 결과를 바꾸지 않으며, 배터리로 바뀌어도 예약 구간 안이면 해제·재획득이 일어나지 않는다. 구현 비용은 판정 함수의 한 줄(5.2 `isWithinScheduleWindow` 공유)과 10.2의 테스트 세 행이다. `상시`에는 다음 예약 없음·차단 상태의 예외를 두지 않는다(3.5).

## 5. 구성 요소와 인터페이스

### 5.1 `Models.swift` — 모드 열거형과 설정 필드

```swift
enum SleepPreventionMode: String, Codable, CaseIterable, Sendable {
    case off            // 끔
    case aroundSchedule // 예약 전후만
    case always         // 상시
}
```

`ScheduleSettings`에 `sleepPrevention: SleepPreventionMode = .off`를 생성자 기본값으로 추가하고 4.4의 `init(from:)`을 둔다. `validate()`는 바꾸지 않는다(열거형 디코딩이 값 집합을 강제한다).

### 5.2 `SleepPrevention.swift` (새 파일) — 판정·어서션·전원

```swift
/// 입력만으로 "지금 쥐어야 하는가"를 결정한다. I/O와 상태를 갖지 않는다.
enum SleepPreventionPolicy {
    static let leadTime: TimeInterval = 30 * 60

    struct Input: Equatable, Sendable {
        var mode: SleepPreventionMode
        var now: Date
        var nextEventDate: Date?
        var isWorking: Bool
        var isOnACPower: Bool
    }

    static func shouldHold(_ input: Input) -> Bool {
        switch input.mode {
        case .off: return false
        case .aroundSchedule: return isWithinScheduleWindow(input)
        case .always: return input.isOnACPower || isWithinScheduleWindow(input)   // 상위 집합(4.5)
        }
    }

    /// 워밍·활성화 확인이 진행 중이거나 다음 예약 30분 전 이후인가.
    static func isWithinScheduleWindow(_ input: Input) -> Bool {
        if input.isWorking { return true }
        guard let next = input.nextEventDate else { return false }
        return next.addingTimeInterval(-leadTime) <= input.now
    }

    /// `끔`이 아니고 아직 쥐지 않았으며 다음 예약이 있으면 `nextEventDate - leadTime`. 그 외 nil.
    /// `상시`도 배터리에서는 이 시각에 선행 타이머가 필요하다.
    static func nextEvaluationDate(_ input: Input) -> Date? {
        guard input.mode != .off, !shouldHold(input), let next = input.nextEventDate else { return nil }
        return next.addingTimeInterval(-leadTime)
    }
}

/// 테스트에서 가짜로 바꾸는 경계. MainActor에서만 쓴다.
@MainActor
protocol IdleSleepAssertionHolding: AnyObject {
    var isHeld: Bool { get }
    /// 이미 쥐고 있으면 kIOReturnSuccess. 실패하면 IOKit 반환값을 그대로 돌려주고 isHeld는 false를 유지한다.
    func acquire() -> IOReturn
    /// 쥐고 있지 않으면 kIOReturnSuccess. 해제 결과를 그대로 돌려주며, 결과와 무관하게 isHeld는 false가 된다.
    @discardableResult func release() -> IOReturn
}

/// IOPMAssertionCreateWithName(PreventUserIdleSystemSleep) 하나만 감싼다.
@MainActor
final class IdleSleepAssertion: IdleSleepAssertionHolding {
    static let name = "ClaudeSessionWarmer sleep prevention"
    private var assertionID: IOPMAssertionID?
    var isHeld: Bool { assertionID != nil }
    func acquire() -> IOReturn   // kIOPMAssertionTypePreventUserIdleSystemSleep, kIOPMAssertionLevelOn
    func release() -> IOReturn   // IOPMAssertionRelease 후 assertionID = nil. 반환값은 호출자가 로그(io_return)에 남긴다.
    // deinit은 nonisolated라 MainActor 메서드 release()를 부를 수 없다(Swift 6: "call to main actor-isolated
    // instance method 'release()' in a synchronous nonisolated context"). 저장 프로퍼티만 직접 읽어 해제한다.
    deinit { if let id = assertionID { _ = IOPMAssertionRelease(id) } }
}

enum PowerSource {
    /// IOPSCopyPowerSourcesInfo 스냅숏의 IOPSGetProvidingPowerSourceType이 "AC Power"일 때만 true.
    /// 배터리·UPS·조회 실패는 false.
    static func isOnACPower() -> Bool
}

/// kIOPSNotifyPowerSource를 notify(3)로 구독한다. 등록 실패는 로그만 남기고 기능은 계속 동작한다(다음 재평가에서 전원을 다시 읽는다).
final class PowerSourceObserver {
    init(onChange: @escaping @Sendable () -> Void)   // 메인 큐로 전달
    deinit                                           // notify_cancel
}
```

파일 상단 import: `Foundation`, `IOKit.pwr_mgt`, `IOKit.ps`, `notify`.

### 5.3 `AppState.swift` — 배선

추가하는 저장 프로퍼티와 생성자 인자:

```swift
private let sleepAssertion: any IdleSleepAssertionHolding
private let isOnACPower: @Sendable () -> Bool
private var sleepLeadTimer: WallClockTimer?
private var powerSourceObserver: PowerSourceObserver?

init(…,
     sleepAssertion: (any IdleSleepAssertionHolding)? = nil,              // nil이면 IdleSleepAssertion()
     isOnACPower: @escaping @Sendable () -> Bool = { PowerSource.isOnACPower() },
     …)
```

호출 지점(`scripts/PreviewRecoveryMenu.swift` 28행, `scripts/VerifyConcurrentStorage.swift` 42행, `scripts/VerifyScheduler.swift` 52행, 테스트 전부)은 기본값으로 그대로 컴파일된다. 단, `scripts/verify-scheduler.sh`는 소스 파일을 명시 나열하므로(7~20행) `SleepPrevention.swift`를 목록에 추가해야 한다. 빠지면 `cannot find type 'IdleSleepAssertionHolding'`로 빌드가 실패하고, 이 빌드를 `--build-only`로 재사용하는 `scripts/verify-concurrent-storage.py`(12행)도 함께 실패한다(6장).

세 프로퍼티에 `didSet`을 붙인다.

```swift
@Published private(set) var settings: ScheduleSettings { didSet { reevaluateSleepPrevention(trigger: "settings_changed") } }
@Published private(set) var nextEvent: ScheduledEvent? { didSet { reevaluateSleepPrevention(trigger: "schedule_changed") } }
@Published private(set) var isWorking = false { didSet { reevaluateSleepPrevention(trigger: "working_changed") } }
```

재평가 함수(테스트에서 직접 호출하므로 `internal`):

```swift
func reevaluateSleepPrevention(trigger: String) {
    let input = SleepPreventionPolicy.Input(
        mode: settings.sleepPrevention, now: clock(), nextEventDate: nextEvent?.date,
        isWorking: isWorking, isOnACPower: isOnACPower())
    let shouldHold = SleepPreventionPolicy.shouldHold(input)
    var metadata = ["trigger": trigger, "mode": input.mode.rawValue,
                    "next_event_at": diagnosticDate(input.nextEventDate),
                    "is_working": input.isWorking ? "true" : "false",
                    "power_source": input.isOnACPower ? "ac" : "battery_or_unknown"]
    if shouldHold != sleepAssertion.isHeld {
        if shouldHold {
            let result = sleepAssertion.acquire()
            metadata["io_return"] = String(format: "0x%08x", UInt32(bitPattern: result))
            diagnosticLogCritical(result == kIOReturnSuccess ? "sleep_prevention.acquired"
                                                             : "sleep_prevention.acquire_failed", metadata)
        } else {
            let result = sleepAssertion.release()
            metadata["io_return"] = String(format: "0x%08x", UInt32(bitPattern: result))
            diagnosticLogCritical("sleep_prevention.released", metadata)
        }
    }
    armSleepLeadTimer(SleepPreventionPolicy.nextEvaluationDate(input))
}

private func armSleepLeadTimer(_ date: Date?) {
    sleepLeadTimer?.cancel(); sleepLeadTimer = nil
    guard let date, schedulerEnabled else { return }
    sleepLeadTimer = WallClockTimer(at: date) { [weak self] _ in
        Task { @MainActor [weak self] in self?.reevaluateSleepPrevention(trigger: "lead_time") }
    }
}
```

`init`의 `if startScheduler { … }` 블록에서 `LifecycleMonitor` 생성 직후 `powerSourceObserver`를 만들고, 콜백은 `diagnosticLog("power.source_changed", ["power_source": …])` 뒤 `reevaluateSleepPrevention(trigger: "power_source_changed")`를 부른다. `startup` 재평가는 `init` 92행 `if startScheduler` 블록 바로 앞에 `defer { reevaluateSleepPrevention(trigger: "startup") }`로 둔다. 블록 끝에 두면 98행의 조기 `return`(차단 시) 때문에 건너뛰어지고, `startScheduler: false`에서는 블록 자체가 실행되지 않기 때문이다. 전원 변경은 `reconcileSchedule`을 거치지 않는다. `reconcileSchedule`은 `scheduleRevision`을 올려 진행 중 `checkSession`을 재조회·중단시킬 수 있기 때문이다(399행, 565~573행).

`applySettings`에 `sleepPrevention: SleepPreventionMode? = nil` 인자를 추가하고 후보 생성(142~144행)에서 `sleepPrevention: sleepPrevention ?? settings.sleepPrevention`을 넘긴다. `nil`은 "바꾸지 않음"이며 기존 호출자(`ExecutionOwnershipTests` 41행, `StorageReliabilityTests` 193행, `SchedulerRecoveryTests` 239·275행, `AppStateTests` 87·110행)는 그대로 컴파일된다.

### 5.4 `MenuContent.swift` — 선택 상자

`scheduleSettings`의 "Mac 로그인 시 앱 실행" 토글(210~220행) 바로 아래, 저장 버튼 행(222행) 위에 둔다. 초안·저장 흐름은 기존 토글과 같다.

```swift
@State private var draftSleepPrevention: SleepPreventionMode   // init에서 state.settings.sleepPrevention

HStack {
    Text("잠자기 방지").frame(width: 104, alignment: .leading)
    Spacer()
    Picker("잠자기 방지", selection: Binding(
        get: { draftSleepPrevention },
        set: { draftSleepPrevention = $0; didSave = false }
    )) {
        ForEach(SleepPreventionMode.allCases, id: \.self) { mode in
            Text(MenuSleepPreventionText.title(for: mode)).tag(mode)
        }
    }
    .pickerStyle(.menu)
    .labelsHidden()
    .controlSize(.small)
    .fixedSize()
    .help(MenuSleepPreventionText.helpText(for: draftSleepPrevention))
}
```

컨트롤은 작은 크기의 표준 선택 상자(pop-up) 하나다. 처음에는 세그먼트 컨트롤과 항상 보이는 설명문으로 구현했으나, 실기 확인에서 `상시`의 설명문이 패널 폭 372에서 말줄임표로 잘렸다. 좁은 패널에 긴 문장을 상시 노출할 이유가 없어 다음 기준으로 다시 정했다.

- 상자 폭은 가장 긴 이름("예약 전후만")에 맞춰 고정된다(약 91pt). 값을 바꿔도 크기가 변하지 않는다.
- 닫힌 상태와 펼친 목록이 같은 글자를 쓴다. 목록 폭이 상자 폭과 같아(실측 90pt) 패널 밖으로 나가지 않는다.
- 상자의 오른쪽 끝은 위 행들의 체크박스와 맞추고, 높이는 요일 버튼과 같게 한다.
- 설명은 항상 노출하지 않고 선택 상자의 도움말(마우스를 올리면 보임)로 둔다.

| 값 | 화면 표시 | 도움말 |
| --- | --- | --- |
| `끔` | "끔" | "Mac의 자동 잠자기를 막지 않습니다." |
| `예약 전후만` | "예약 전후만" | "다음 워밍 30분 전부터 확인이 끝날 때까지 자동 잠자기를 막습니다. 배터리에서도 적용됩니다." |
| `상시` | "상시" | "전원 어댑터 연결 중에는 계속, 배터리에서는 다음 워밍 30분 전부터 확인이 끝날 때까지 자동 잠자기를 막습니다." |

`hasDraftChanges`(311~316행)에 `|| draftSleepPrevention != state.settings.sleepPrevention`을 추가하고, `saveDraft`(351~365행)는 `applySettings(…, sleepPrevention: draftSleepPrevention)`을 호출한 뒤 초안을 저장값으로 되돌린다. 라벨 104 + 오른쪽 정렬 컨트롤은 기존 "첫 워밍" 행과 같은 배치다.

화면 변경은 라이트·다크 두 모드에서 세 값을 모두 렌더링해 확인한다(가짜 서비스를 주입한 `MenuContent`를 화면 밖 창에 그려 PNG로 저장). 글자 잘림, 값에 따른 크기 변화, 다른 행과의 정렬을 본다.

## 6. 변경 파일 목록

| 파일 | 변경 | 규모 |
| --- | --- | --- |
| `Sources/ClaudeSessionWarmer/SleepPrevention.swift` | 새 파일. `SleepPreventionPolicy`, `IdleSleepAssertionHolding`, `IdleSleepAssertion`, `PowerSource`, `PowerSourceObserver` | 약 120행 |
| `Sources/ClaudeSessionWarmer/Models.swift` | `SleepPreventionMode` 추가. `ScheduleSettings`에 필드·생성자 기본값·`init(from:)` | 약 25행 |
| `Sources/ClaudeSessionWarmer/AppState.swift` | 저장 프로퍼티 4개, 생성자 인자 2개, `didSet` 3개(`settings`·`nextEvent`·`isWorking`), `reevaluateSleepPrevention`·`armSleepLeadTimer`, `applySettings` 인자, `init`의 `defer` 호출과 전원 관찰자 생성 | 약 60행 |
| `scripts/verify-scheduler.sh` | 7~20행의 명시 소스 목록에 `Sources/ClaudeSessionWarmer/SleepPrevention.swift` 한 줄 추가. 빠지면 `cannot find type 'IdleSleepAssertionHolding'`로 실패하고, 이 빌드를 쓰는 `scripts/verify-concurrent-storage.py`(12행 `--build-only`)도 실패한다. IOKit은 `import`로 자동 링크되므로 링크 플래그 추가는 없다. `scripts/preview-recovery-menu.sh`(39행 glob)는 자동 포함, `scripts/verify-warmup.sh`는 `Models.swift`만 포함하며 `SleepPreventionMode`가 같은 파일에 있어 영향 없음. | 1행 |
| `Sources/ClaudeSessionWarmer/MenuContent.swift` | 초안 상태, 선택 상자 행과 도움말, `hasDraftChanges`, `saveDraft` | 약 35행 |
| `Tests/ClaudeSessionWarmerTests/SleepPreventionPolicyTests.swift` | 새 파일. 판정 함수 표 기반 테스트 | 약 80행 |
| `Tests/ClaudeSessionWarmerTests/SleepPreventionTests.swift` | 새 파일. 가짜 어서션·가짜 전원으로 `AppState` 전이 테스트와 불변식 테스트 | 약 200행 |
| `Tests/ClaudeSessionWarmerTests/SettingsStoreTests.swift` | 키 집합 기대값에 `sleepPrevention` 추가, 키 없는 레코드·왕복·미지 값 테스트 | 약 40행 |
| `01_PRD.md`, `02_USER_FLOW.md`, `03_TEST_PLAN.md`, `README.md` | 11장 | 문서 |
| `packaging/Info.plist` | 배포 단계에서 0.1.8 / 14 | 배포 시 |

`DiagnosticLogger.swift`는 바꾸지 않는다. `LifecycleMonitor`(194~277행)에 전원 관찰을 넣는 대신 `PowerSourceObserver`를 따로 두는 이유는, `LifecycleMonitor`의 콜백이 `reconcileSchedule`로 이어지는 설계이고 전원 변경은 그 경로를 타면 안 되기 때문이다(5.3). `Package.swift`, entitlements, `Info.plist` 키 변경은 없다.

## 7. 저장 형식과 호환성

### 7.1 저장되는 값

`scheduleSettings.versioned` 키의 `StoredRecord<ScheduleSettings>`에 `"sleepPrevention": "off" | "aroundSchedule" | "always"` 키가 추가된다. 헤더 `schemaVersion = 1`, `minimumReaderVersion = 1`은 유지한다. `migration.json`의 `settings` 스냅숏에도 같은 키가 들어간다. `runtime-state.json`, `quotaCache`, Keychain은 변경이 없다.

### 7.2 버전 간 동작

| 상황 | 코드 근거 | 결과 |
| --- | --- | --- |
| 0.1.8이 0.1.7 레코드(키 없음)를 읽음 | 4.4 `decodeIfPresent … ?? .off` | `끔`. 다른 필드는 그대로. |
| 0.1.8이 버전 없는 구형 `scheduleSettings` 레코드를 읽음 | `SettingsStore.prepare` 232행도 같은 `ScheduleSettings` 디코더를 쓴다 | `끔`. 기존 이전 경로 변경 없음. |
| 0.1.7이 0.1.8 레코드(키 있음)를 읽음 | `decodeRecord` 348~355행은 헤더 1·1을 통과시키고, 합성 `Decodable`은 모르는 키를 무시한다 | 정상 읽기. `hasReadableSettings = true`. 0.1.7은 잠자기 방지를 하지 않는다. |
| 0.1.7이 다시 저장함(예약 시각 변경, 또는 시작 시 `syncLaunchAtLoginStatus` 361~363행이 로그인 항목 상태가 다를 때 자동 저장) | 0.1.7의 `encode(to:)`에는 키가 없다 | 키가 사라진다. 이후 0.1.8은 `끔`으로 읽는다. 실행은 막히지 않는다. 사용자는 설정을 다시 고르면 된다(SP-10, README에 적는다). |
| 0.1.7의 `validateCurrentRecords`(326~345행) | 디코드값과 메모리값 비교. 둘 다 키 없는 같은 디코더를 거친다 | 일치. 외부 변경으로 오판하지 않는다. 같은 사용자의 동시 실행은 `flock`이 막으므로 두 버전이 동시에 쓰는 경우는 없다. |
| 미래 버전이 네 번째 모드를 추가함 | 0.1.8의 열거형 디코딩은 엄격하다. 모르는 값은 `DecodingError` → `StorageIssue(.settings, .corrupt)` → 실행 차단과 "손상" 메시지 | 잘못된 안내가 되므로, **네 번째 모드를 추가하는 버전은 `minimumReaderVersion`을 2로 올려야 한다.** 그러면 0.1.8은 `decodeRecord` 350~352행에서 `unsupported`("더 새로운 앱에서 저장한 데이터입니다")로 안내한다. 이 규칙을 `Models.swift`의 열거형 주석에 적는다. |

### 7.3 버전 번호를 올리지 않는 이유

`minimumReaderVersion`을 2로 올리면 0.1.7은 모든 설정을 `unsupported`로 거부하고 실행을 멈춘다(`decodeRecord` 350~352행, `StorageIssue.message` 17행). 이 필드가 없을 때의 결과는 "잠자기 방지가 꺼진다"뿐이고, 그것은 이 기능의 기본값이며 안전한 방향이다. 구버전 실행을 막아야 할 이유가 없으므로 1·1을 유지한다. `schemaVersion`도 같은 이유로 1을 유지한다. 반대로 미지 값을 관대하게 `끔`으로 읽는 디코더는 두지 않는다. 그렇게 하면 0.1.8이 미래 버전의 값을 `끔`으로 덮어써 "더 새로운 저장 형식은 덮어쓰지 않는다"는 규칙을 깨기 때문이다.

## 8. 오류 처리

| 오류 | 처리 | 사용자 노출 |
| --- | --- | --- |
| `IOPMAssertionCreateWithName`이 `kIOReturnSuccess` 외 반환 | `isHeld`는 false 유지. `sleep_prevention.acquire_failed`에 `io_return`을 16진수로 기록. 다음 트리거(3.4)에서 재시도. 별도 재시도 타이머 없음. | 없음. 상태 메시지·알림을 바꾸지 않는다. |
| `IOPMAssertionRelease` 실패 | `assertionID = nil`로 처리하고 반환값만 `sleep_prevention.released`의 `io_return`에 기록. 프로세스 종료 시 OS가 정리한다. | 없음 |
| `notify_register_dispatch` 실패(`NOTIFY_STATUS_OK` 외) | `power.observer_failed`에 상태 코드 기록. 기능은 계속 동작하며 전원 상태는 다른 트리거의 재평가에서 다시 읽는다. | 없음 |
| `IOPSCopyPowerSourcesInfo`가 nil | `isOnACPower() == false`. `상시`는 배터리와 같이 예약 구간만 쥔다. | 없음 |
| 설정 저장 실패 | 기존 `applySettings`의 실패 경로(153행) 그대로. 초안은 유지되고 모드는 바뀌지 않는다. | 기존 저장 실패 표시 |
| 선행 타이머가 과거 시각으로 계산됨 | `nextEvaluationDate`는 `shouldHold == false`일 때만 값을 돌려주므로 항상 미래다. `WallClockTimer`가 과거를 받아도 즉시 발화해 재평가하므로 무해하다. | 없음 |
| 재평가 재진입 | `didSet` 안에서 IOKit 호출만 하고 다른 프로퍼티를 대입하지 않으므로 재귀가 없다. 선행 타이머 콜백은 `Task { @MainActor }`로 넘어온다. | 없음 |

## 9. 진단 로그

`acquired`·`released`는 보유 상태가 바뀔 때만, `acquire_failed`는 실패한 획득 시도마다, `power.source_changed`는 알림이 올 때마다 기록한다. 재평가 자체는 기록하지 않는다(`nextEvent` 대입은 하루 수십 번 일어난다).

| 이벤트 | 기록 시점 | 메타데이터 |
| --- | --- | --- |
| `sleep_prevention.acquired` | 미보유 → 보유 | `trigger`, `mode`, `next_event_at`, `is_working`, `power_source`, `io_return` |
| `sleep_prevention.acquire_failed` | 획득 시도 실패 | 같음 |
| `sleep_prevention.released` | 보유 → 미보유 | 같음(`io_return`은 해제 결과) |
| `power.source_changed` | 전원 알림 수신 | `power_source` (`ac` / `battery_or_unknown`) |
| `power.observer_failed` | 알림 등록 실패 | `status` |

`acquired`·`released`는 `diagnosticLogCritical`(동기 flush)로 남긴다. 잠자기 직전의 상태 전이가 디스크에 남아야 사후 분석이 되기 때문이며, 하루 수 회 수준이라 비용이 없다. 메타데이터 키는 `DiagnosticLogger.sensitiveKeyFragments`(29~45행)와 겹치지 않는다. 기존 `power.system_sleep`·`power.system_wake` 로그와 함께 읽으면 "어서션을 쥐고 있었는데 잠들었다"(유휴 외 원인)와 "쥐지 않아서 잠들었다"를 구별할 수 있다.

## 10. 테스트·검증 계획

### 10.1 사전등록

구현 전에 이슈 코멘트로 다음을 남기고, 구현 후 같은 기준으로 판정한다.

| 항목 | 기준 |
| --- | --- |
| 대상 지표 | 10.2의 신규 테스트 전부 통과. 불변식 테스트에서 `isHeld != shouldHold`인 지점 0건. |
| 비대상 악화 0 | 기존 테스트 120개 전부 통과(`swift test`), `swift build -c release` 통과. 기존 통합 테스트의 조회·워밍 호출 횟수 변화 0. `python3 scripts/verify-execution.py`, `python3 scripts/verify-concurrent-storage.py` 결과 변화 0. |
| 저장 호환 | 7.2 표의 네 행(0.1.7 레코드 읽기, 구형 레코드 읽기, 왕복, 미지 값 차단)이 테스트로 고정됨. |
| 실기 | 10.3 표의 여섯 항목이 모두 `pmset -g assertions`와 진단 로그로 확인됨. |

### 10.2 자동 테스트

기존 방식을 따른다. 저장소는 `MemoryDefaults`, 시계는 `clock:` 주입, `startScheduler: false`.

**테스트 안전 규칙(요구사항).** 독립 검토에서 `loginClaude`를 주입하지 않은 시험이 사용자 브라우저에 실제 Claude 로그인 페이지를 여러 번 열었다. 다음을 지킨다.

1. `AppState`를 만드는 모든 테스트는 `inspectClaude`·`loginClaude`·`warmClaude` 세 개를 전부 가짜로 주입한다. 하나라도 빠지면 기본값이 실제 Keychain·네트워크·브라우저를 쓴다(`AppState.swift` 68~70행).
2. 새 테스트 파일은 세 가짜와 `sleepAssertion`·`isOnACPower` 가짜를 항상 주입하는 공용 `makeState()` 하나로만 `AppState`를 만든다. 테스트 본문에서 `AppState(` 직접 호출을 금지한다.
3. `connectClaude()`·`manualWarmup()`·`refreshSilently()`를 반복문이나 무작위 순서로 호출하지 않는다. 불변식 테스트는 고정 순서다.
4. `startScheduler: true`는 실제 시계와만 쓴다. 가짜 시계에 `끔`이 아닌 모드를 조합하면 선행 타이머가 실제 시각 기준으로 즉시 발화하고 가짜 시계는 움직이지 않아 재설정이 반복된다.

**`SleepPreventionPolicyTests`(새 파일, 순수 함수)**

| 테스트 | 입력 | 기대 |
| --- | --- | --- |
| `testOffNeverHolds` | `끔` × (`isWorking` 참/거짓) × (`nextEventDate` nil/과거/30분 이내/멀리) × (AC/배터리) | 모두 거짓 |
| `testAroundScheduleHoldsWithinLeadTimeOrWhileWorking` | 3.2 판정표의 각 `date` 유형 | 표와 일치. 경계 `date − 30분 == now`는 참, `+1초`는 거짓 |
| `testAroundScheduleIgnoresPowerSource` | 같은 입력에서 AC/배터리만 바꿈 | 결과 동일 |
| `testAlwaysHoldsOnACOrWithinScheduleWindow` | `상시` × AC/배터리 × `isWorking` 참/거짓 × `nextEventDate` 유형 | AC면 모두 참. 배터리면 같은 입력의 `예약 전후만` 결과와 동일 |
| `testNextEvaluationDateOnlyWhenNotHoldingWithPendingSchedule` | `예약 전후만`+멀리 → `date − 30분`; `상시`+배터리+멀리 → `date − 30분`; `상시`+AC → nil; 쥐어야 하는 입력·`끔`·`nextEventDate` nil → nil | |
| `testAlwaysOnACHoldsWithoutAnySchedule` | `상시`+AC, `nextEventDate == nil`, `isWorking == false` | 참(예외 없음, 3.5) |

**`SleepPreventionTests`(새 파일, `AppState` 전이)**

가짜 두 개를 쓴다.

```swift
@MainActor final class FakeIdleSleepAssertion: IdleSleepAssertionHolding {
    private(set) var isHeld = false
    var nextAcquireResult: IOReturn = kIOReturnSuccess
    private(set) var transitions: [String] = []   // "acquire", "acquire_failed", "release"
}
final class FakePowerSource: @unchecked Sendable { var isOnAC = true }   // 클로저 { fake.isOnAC }로 주입
```

| 테스트 | 시나리오 | 기대 |
| --- | --- | --- |
| `testAroundScheduleAcquiresAtLeadTimeAndReleasesAfterConfirmation` | 06:00 첫 예약, 05:29 시작 → `reconcileSchedule(reason: "startup")` 명시 호출(`startScheduler: false`면 `init` 92~99행이 일정을 계산하지 않아 `nextEvent`가 nil) → 시계 05:30 + `reevaluate("lead_time")` → `handle(event)`로 비활성→워밍→활성 확인 → 종료 | 전이 `[acquire, release]`. `handle` 중 `isHeld == true`. 종료 후 `nextEvent.date == 11:00`, `isHeld == false`. 해제 트리거는 `schedule_changed`다(`working_changed` 시점에는 `nextEvent`가 아직 지난 06:00이라 유지됨, 3.2). |
| `testAroundScheduleStaysHeldThroughRetries` | 조회 실패(`quotaUnavailable`) 반복으로 30초·5분 재시도 4회 | 전 구간 `isHeld == true`, 전이는 `acquire` 1회 |
| `testAroundScheduleReleasesWhenRetriesAreExhausted` | 재시도 불가 오류(`oauthRefreshFailed`) → `nextEvent`가 내일 | `release` 1회 |
| `testAroundScheduleWorksOnBattery` | 위 첫 시나리오를 `isOnAC = false`로 | 결과 동일 |
| `testAlwaysFollowsPowerSourceOutsideScheduleWindow` | `상시`, 다음 예약이 30분보다 먼 상태에서 AC로 시작 → `isOnAC = false` + `reevaluate("power_source_changed")` → 다시 참 + 재평가 | `[acquire, release, acquire]` |
| `testAlwaysOnBatteryMatchesAroundSchedule` | `상시`, 배터리로 첫 시나리오(05:29 시작 → 05:30 `lead_time` → `handle(event)` → 완료) 반복 | 전이가 `예약 전후만`과 같은 `[acquire, release]` |
| `testAlwaysKeepsHoldingWhenACArrivesDuringScheduleWindow` | `상시`, 배터리로 예약 구간 보유 중 `isOnAC = true` + 재평가 → 확인 완료 → `finishWorking` | 전이 추가 없음. 완료 후에도 `isHeld == true`(AC) |
| `testSwitchingToOffReleasesImmediately` | 보유 중 `applySettings(sleepPrevention: .off)` | `release` 1회, 저장값 `.off` |
| `testApplySettingsWithNilSleepPreventionKeepsCurrentValue` | `상시` 저장 뒤 `applySettings(firstWarmupDate:weekdays:excludeKoreanHolidays:)`만 호출(기존 호출자 6곳의 경로) | 저장값·`state.settings.sleepPrevention` 모두 `.always` 유지, 전이 없음 |
| `testAcquireFailureIsRetriedOnNextTrigger` | `nextAcquireResult = kIOReturnError` → 재평가 → 성공으로 바꾼 뒤 `applySettings` 등 다음 트리거 | `[acquire_failed, acquire]`, `isHeld == true` |
| `testBlockedOperationsFollowPlainRule` | 세 모드 × AC/배터리. `executionCheck`가 차단 사유를 돌려주도록 주입 → `refreshExecutionPermission()` | `예약 전후만`: 해제(`trigger=schedule_changed`, `nextEvent == nil`). `상시`+AC: 유지. `상시`+배터리: 해제. 차단 입력이 따로 없음을 고정하는 테스트다(3.5). |
| `testCorruptSettingsBehaveAsOff` | 손상된 `scheduleSettings.versioned` 레코드(테스트 안에서 `MemoryDefaults`에 직접 기록한다. 공유 fixture는 없다) | `state.settings.sleepPrevention == .off`, 전이 없음 |
| `testInvariantHoldsAfterEveryPublicMutation` | 고정 순서로 `applySettings`(모드 셋 순환), `reconcileSchedule`(각 reason), `handle`, `handleTargetFailure`, `markScheduledWindowStarted`, `manualWarmup` 1회, 전원 토글을 수행하며 매 단계 뒤 검사. `handleTargetFailure`는 시계를 `event.targetAt` 이후로 옮긴 뒤 호출한다(그 전이면 `retryAt < targetAt`으로 `DailyCycle.validate()`가 실패해 저장소가 차단된다, `Models.swift` 152~154행). | 매 단계 `fake.isHeld == SleepPreventionPolicy.shouldHold(현재 입력)` (SP-06), 매 단계 `operationBlockReason == nil` |
| `testInitDoesNotTouchAssertionWhenOff` | 기본 설정으로 `AppState` 생성 | 전이 없음, `acquire` 호출 0회 |

**`SettingsStoreTests` 추가**

| 테스트 | 기대 |
| --- | --- |
| `testPersistedModelsContainOnlyExpectedFields` 갱신 | `ScheduleSettings` 키 집합 = `["firstWarmupMinutes", "weekdays", "excludeKoreanHolidays", "launchAtLogin", "sleepPrevention"]` |
| `testSettingsRecordWithoutSleepPreventionReadsAsOff` | 헤더 1·1과 네 필드만 있는 레코드를 `scheduleSettings.versioned`에 직접 써서 `loadSettings().sleepPrevention == .off`, `issue == nil` |
| `testLegacyVersionlessSettingsReadAsOff` | 버전 없는 `scheduleSettings` 키만 있는 레코드 → 이전 후 `.off` |
| `testSleepPreventionRoundTrip` | 세 값 각각 저장·재읽기 일치 |
| `testUnknownSleepPreventionValueIsReportedAsCorruptNotSilentlyOff` | `"sleepPrevention": "someFutureMode"` → `issue?.area == .settings`, `kind == .corrupt`, `loadSettings().sleepPrevention == .off`(초안). 7.2의 "미래 버전은 `minimumReaderVersion`을 올린다" 규칙을 고정하는 테스트다. |

`PowerSourceObserver`와 `IdleSleepAssertion`의 실제 IOKit 호출은 단위 테스트하지 않는다. OS 통합은 10.3의 실기 확인으로 검증한다(기존 테스트 계획의 "macOS Integration" 레벨).

선행 타이머 배선(`armSleepLeadTimer`)도 10.2에서는 실행되지 않는다. `schedulerEnabled` 가드 때문이며, 안전 규칙 4에 따라 가짜 시계와 `startScheduler: true`를 조합하지 않는다. 결정: 다음 평가 시각 계산은 순수 함수 `nextEvaluationDate`로 두고 단위 테스트하며, 타이머가 실제로 걸리고 발화하는지는 10.3의 `trigger=lead_time` 로그로 확인한다.

### 10.3 실기 확인(구현자 담당, `/Applications`의 서명 빌드)

확인 명령: `pmset -g assertions | grep -A1 ClaudeSessionWarmer`, `pmset -g batt | head -1`, `grep -E 'sleep_prevention|power\.source' ~/Library/Logs/ClaudeSessionWarmer/events.jsonl | tail`.

| 항목 | 절차 | 통과 기준 |
| --- | --- | --- |
| 상시·AC | `상시` 저장, 어댑터 연결 상태 | `pid <n>(ClaudeSessionWarmer): … PreventUserIdleSystemSleep named: "ClaudeSessionWarmer sleep prevention"` 한 줄. 다른 종류의 어서션 없음. 로그에 `acquired`(`trigger=settings_changed`). |
| 상시·전원 전환 | 다음 예약이 30분보다 먼 시간대에 어댑터 분리 → 10초 내 확인 → 재연결 → 확인 | 분리 후 줄이 사라지고 `power.source_changed`+`released`, 재연결 후 다시 나타나고 `acquired`. |
| 상시·배터리·예약 구간 | `상시` 저장, 어댑터 분리, 첫 워밍을 현재+31분으로 저장 | T−30분 이후 줄이 나타나고(`trigger=lead_time`), 창 확인 완료 후 사라짐. `예약 전후만`과 같은 동작. |
| 예약 전후만 | 첫 워밍을 현재+31분으로 저장(가짜 워밍이 아닌 실제 예약이므로 사용량 창이 비활성인 시간대를 고른다) | T−31분: 줄 없음. T−30분 이후: 줄 있음, `acquired`(`trigger=lead_time`). 창 확인 완료 후: 줄 없음, `released`(`trigger=schedule_changed`). |
| 끔 | `끔` 저장 후 위 시간대 반복 | 줄이 한 번도 나타나지 않음 |
| 종료 정리 | `상시`로 보유 중 메뉴 `종료` → 확인. 다시 실행해 보유 중 `kill -9 <pid>` → 확인 | 두 경우 모두 줄이 즉시 사라짐 |

전제: "첫 워밍을 현재+31분으로 저장"으로 다음 예약이 옮겨지는 것은 오늘이 실행일이고 `오늘 확인한 창`이 0일 때뿐이다(`ScheduleEngine` 83행 `count == 0 ? first : (cycle.nextResetAt ?? first)`). 이미 창을 처리한 날에는 다음 예약이 확인된 실제 리셋 시각이므로, 메뉴의 `다음 워밍` 시각 − 30분을 T−30분으로 삼아 같은 확인을 한다. 3개를 모두 처리했거나 비실행일이면 요일 설정에 다음 날을 포함해 다음 실행일 첫 예약 − 30분으로 확인한다(94~98행). 어느 경우든 실제 워밍이 1회 발생할 수 있으므로 사용량 창이 비활성인 시간대를 고르는 조건은 그대로 둔다.

업데이트 재시작은 0.1.8 배포 시 `update.relaunching` 전후로 같은 확인을 한 번 수행한다.

### 10.4 기본 자동 검증 명령

```sh
swift test
swift build -c release
python3 scripts/verify-execution.py
python3 scripts/verify-concurrent-storage.py
```

문서 작성 단계에서는 위 명령을 실행하지 않았다. 구현 후 전체 테스트와 release 빌드를 수행한다.

## 11. 기존 문서 수정 목록

실제 수정은 구현 PR에서 한다. 아래는 바꿀 위치와 내용이다.

### 11.1 `01_PRD.md`

| 위치 | 현재 | 변경 |
| --- | --- | --- |
| 33행 목표 | "화면 잠금 또는 디스플레이 꺼짐 상태에서도 예정된 실행을 지원한다." | 뒤에 한 문장 추가: "사용자가 선택하면 예약 전후 또는 전원 연결 중에 Mac의 유휴 잠자기를 막는다." |
| 41행 비목표 | "비용 분석, 자동 업데이트, Mac 깨우기" | 유지 |
| 42행 비목표 | "시스템 잠자기·앱 종료 중 실행 보장, Mac 강제 깨우기, 전날 예약의 소급 실행" | "잠자기 중 실행 보장, 잠든 Mac 깨우기, 저전력·수동 잠자기 등 유휴 외 원인의 잠자기 차단, 앱 종료 중 실행 보장, 전날 예약의 소급 실행"으로 바꾼다. 유휴 잠자기 방지는 비목표에서 빠진다. |
| 86행 포함 | "…실패 알림, 최근 결과, 로그인 실행" | "…로그인 실행, 유휴 잠자기 방지 설정(끔·예약 전후만·상시)" |
| 109행 다음 | REQ-013 행 | `REQ-014` 행 추가: "사용자는 `잠자기 방지`를 끔(기본)·예약 전후만·상시 중에서 선택할 수 있어야 한다." 수용 기준: "예약 전후만은 다음 워밍 30분 전부터 확인 완료까지, 상시는 전원 어댑터 연결 중 또는 그 구간에 `PreventUserIdleSystemSleep` 어서션을 유지한다. 디스플레이 꺼짐·화면 잠금과 유휴 외 원인의 잠자기는 막지 않는다." |
| 116행 호환성 | "…시스템 잠자기 등 명시적 미지원 상태의 실행 보장은 제공하지 않는다." | 뒤에 추가: "잠자기 방지 설정은 유휴로 인한 시스템 잠자기만 막는다." |
| 135행 리스크 OS 전원 상태 | 대응: "실행 기회가 생기면 오늘의 미완료 작업을 처리한다. 잠자기 중 실행·강제 깨우기는 보장하지 않는다." | "잠자기 방지 설정으로 유휴 잠자기를 줄일 수 있다. 저전력·수동 잠자기 등 유휴 외 원인은 막지 않으며, 실행 기회가 생기면 오늘의 미완료 작업을 처리한다. 잠든 Mac을 깨우지 않는다." |

### 11.2 `02_USER_FLOW.md`

| 위치 | 변경 |
| --- | --- |
| 7행 제품 약속 | "Mac 강제 깨우기와 잠자기 중 실행 보장은 제공하지 않는다." 뒤에 "선택한 경우 예약 전후 또는 전원 연결 중에 유휴 잠자기를 막는다(FLOW-014)."를 추가 |
| 22행 FLOW-002 | "첫 워밍 시각·요일·공휴일 제외를 draft로 편집하고" → "첫 워밍 시각·요일·공휴일 제외·잠자기 방지를 draft로 편집하고" |
| 5장 사용자 제어 끝 | `### FLOW-014 잠자기 방지 (REQ-014)` 추가. 본문: 세 값의 의미, 30분 규칙, 상시의 전원 조건과 배터리에서의 예약 구간 유지, 재시도 중 유지, 디스플레이 꺼짐·유휴 외 원인의 잠자기는 막지 않음, 확인 방법은 `pmset -g assertions`. 3.2의 타임라인 표를 축약해 넣는다. |

### 11.3 `03_TEST_PLAN.md`

| 위치 | 변경 |
| --- | --- |
| 5행 범위 | "`REQ-001`~`REQ-013`과 `FLOW-001`~`FLOW-013`을 기준으로" → "`REQ-001`~`REQ-014`와 `FLOW-001`~`FLOW-014`를 기준으로". 대상 목록 끝에 "유휴 잠자기 방지 설정" 추가 |
| 7행 | "실제 절전·덮개 닫힘·종료 중 실행을 보장하지 않으며" 유지. 뒤에 "잠자기 방지는 유휴 잠자기만 대상이다." 추가 |
| TC-UI-001 다음 | `### TC-SLEEP-001 — 잠자기 방지 모드·전원·정리 (P1, Unit+Integration+macOS)` 추가. 참조 `REQ-014`, `FLOW-014`. 실행·기대·증거는 이 문서 10.2~10.3을 요약한다. |
| 추적성 표 | `REQ-014` 행 추가: 흐름 `FLOW-002`, `FLOW-014`; 테스트 `TC-SLEEP-001` |

### 11.4 `README.md`

| 위치 | 변경 |
| --- | --- |
| 3·4·10행 | 0.1.8 배포 때 버전 배지와 다운로드 수 배지를 GitHub 릴리즈에서 자동으로 읽는 배지로 바꾸고, 버전별 인용문은 릴리즈 노트 링크로 대체했다. 이후 배포에서는 README의 버전 표기를 손으로 고치지 않는다. |
| 주요 기능 | "- 예약 전후 또는 전원 연결 중 Mac의 자동 잠자기 방지(선택)" 추가 |
| 사용법 2 | "첫 워밍 시각, 실행 요일, 공휴일 제외 여부, 잠자기 방지를 설정합니다." |
| 사용 시 참고 55행 | "화면 잠금이나 디스플레이 꺼짐과 시스템 잠자기는 다릅니다. 예약 실행을 위해 Mac이 깨어 있고 인터넷에 연결돼 있어야 합니다." → "화면 잠금이나 디스플레이 꺼짐과 시스템 잠자기는 다릅니다. 예약 실행을 위해 Mac이 깨어 있고 인터넷에 연결돼 있어야 합니다. `잠자기 방지`를 `예약 전후만`으로 두면 다음 워밍 30분 전부터 확인이 끝날 때까지, `상시`로 두면 전원 어댑터 연결 중에는 계속, 배터리에서는 예약 전후 구간에만 Mac이 유휴 상태로 잠들지 않습니다. 디스플레이는 그대로 꺼지고 화면도 잠깁니다." |
| 사용 시 참고 새 항목 | "- `상시`는 배터리로 바뀌면 예약 전후 구간 밖에서 해제되고 다시 연결되면 계속 유지됩니다. `예약 전후만`은 배터리에서도 적용되며 배터리 잔량을 확인하지 않습니다. 어느 설정도 저전력·수동 잠자기 등 유휴 외 원인의 잠자기를 막지 않습니다. 현재 상태는 터미널에서 `pmset -g assertions`로 확인할 수 있습니다." |
| 사용 시 참고 새 항목 | "- 잠든 Mac을 예약 시각에 깨우는 것은 앱이 하지 않습니다. 원하면 터미널에서 `sudo pmset repeat wakeorpoweron MTWRF 05:55:00`처럼 macOS 예약 깨우기를 직접 걸 수 있습니다(첫 워밍 06:00의 5분 전 예시)." |
| 0.1.7의 실행·저장소 보호 절 또는 새 절 | "0.1.7 이하로 되돌리면 잠자기 방지 설정은 읽히지 않고, 그 버전이 설정을 다시 저장하면 `끔`으로 돌아갑니다. 다른 설정과 실행 기록은 영향이 없습니다." |

### 11.5 `04_DEVELOPMENT_PLAN.md`

3장 "최소 코드 구조"의 파일 목록에 `SleepPrevention.swift` 한 줄을 추가한다. 다른 내용은 바꾸지 않는다.

## 12. 완료 기준과 범위

- [ ] `SleepPreventionMode`·`ScheduleSettings.sleepPrevention`과 `init(from:)` 구현, 저장 호환 테스트 통과
- [ ] `SleepPreventionPolicy` 판정표 전부 단위 테스트로 고정
- [ ] `IdleSleepAssertion`·`PowerSource`·`PowerSourceObserver` 구현, entitlements·Info.plist 키 변경 없음 확인
- [ ] `AppState`의 `didSet` 세 개·선행 타이머·전원 관찰자·`startup` 재평가(`defer`) 배선, 불변식 테스트 통과
- [ ] 10.2 테스트 안전 규칙 준수(세 백엔드 가짜 전부 주입, 공용 `makeState()`, 고정 순서, 가짜 시계에서 `startScheduler: false`)
- [ ] 메뉴 선택 상자와 도움말, 초안·저장 흐름
- [ ] 진단 로그 다섯 이벤트
- [ ] 기존 테스트 120개 포함 `swift test`, `swift build -c release`, `scripts/verify-scheduler.sh --build-only`·실행·동시 저장 검증 스크립트 통과
- [ ] 10.3 실기 확인 여섯 항목 기록
- [ ] 11장의 문서 수정

이 계획에 포함하지 않는 것: 배터리 잔량·저전력 모드 연동, 보유 시간 상한, 메뉴 상태 표시, 잠든 Mac 깨우기, 디스플레이 어서션, 특권 helper, `pmset` 설정 변경, 저장 형식 버전 변경.

## 근거

- [AppState](Sources/ClaudeSessionWarmer/AppState.swift): `scheduleNext` 367~394행, `reconcileSchedule` 397~413행, `arm` 439~466행, `handle` 495~518행, `checkSession` 556~640행, `handleTargetFailure` 728~768행, `refreshExecutionPermission` 107~120행
- [ScheduleEngine](Sources/ClaudeSessionWarmer/ScheduleEngine.swift): `nextEvent` 72~99행
- [SettingsStore](Sources/ClaudeSessionWarmer/SettingsStore.swift): `StoredRecord` 3~7행, `decodeRecord` 347~356행, `validateCurrentRecords` 326~345행, `loadSettings` 65행
- [Models](Sources/ClaudeSessionWarmer/Models.swift): `ScheduleSettings` 3~23행
- [MenuContent](Sources/ClaudeSessionWarmer/MenuContent.swift): `scheduleSettings` 156~238행, `hasDraftChanges` 311~316행, `saveDraft` 351~365행
- [DiagnosticLogger](Sources/ClaudeSessionWarmer/DiagnosticLogger.swift): `LifecycleMonitor` 194~277행, 민감 키 목록 29~45행
- [ExecutionOwnership](Sources/ClaudeSessionWarmer/ExecutionOwnership.swift), [앱 진입점](Sources/ClaudeSessionWarmer/ClaudeSessionWarmerApp.swift) 52~100행
- [서명 entitlements 생성](scripts/prepare-keychain-signing.py) 43~47행: 샌드박스 없음
- IOKit 헤더(MacOSX26.5 SDK): `IOPMLib.h` 276~292행(PreventUserIdleSystemSleep 의미와 한계), 757~781행(`IOPMAssertionCreateWithName`, 권한 불필요, 이름 128자), 1026~1030행(`NoIdleSleepAssertion` 별칭); `IOPowerSources.h` 131~147행(`kIOPSNotifyPowerSource`), 196~214행(반환 문자열 세 종류), 307~317행(`IOPSGetProvidingPowerSourceType`)
- 실측: 2026-10-02 이 Mac의 `pmset -g assertions`에서 Electron 앱이 `NoIdleSleepAssertion named: "Electron"`을 보유. Swift 타입체크로 `IOPMAssertionCreateWithName`, `IOPSGetProvidingPowerSourceType`, `notify_register_dispatch`(`import notify`) 접근 확인. `@Published` `didSet`이 `init` 직접 대입과 메서드 대입 모두에서 호출됨을 실행으로 확인.
- 선행 계획: [09 지연 워밍 복구](09_LATE_WARMUP_RECOVERY_PLAN.md), [13 데스크톱 안정화](13_DESKTOP_RELIABILITY_PLAN.md)
