# Claude Session Warmer

정해진 근무일의 Claude Code 5시간 사용량 창을 준비하는 내부 배포용 macOS 메뉴바 앱입니다.

## MVP 정책

- 사용자가 지정한 첫 시각에 첫 번째 창을 확인하고 필요할 때만 워밍합니다.
- 실제 `resets_at`을 우선 따르고, 실패·놓침에는 `targetAt + 5시간` fallback으로 후속 워밍을 최대 2회 수행해 하루 최대 3개 창을 관리합니다.
- 선택한 요일에만 실행하며, 기본적으로 대한민국 공휴일을 제외합니다.
- 화면 잠금과 디스플레이 꺼짐 상태는 지원합니다.
- 시스템 잠자기, MacBook 덮개 닫힘, 종료, 로그아웃 중 놓친 실행은 나중에 따라잡지 않습니다.
- 첫 번째 창이 실패해도 `targetAt + 5시간` 기준으로 두 번째·세 번째 창은 계속 진행합니다.

## 요구 환경

- macOS 14 이상
- Apple Silicon Mac
- Claude Code 설치 및 Claude.ai 유료 구독 계정

## Claude 인증

일정 `저장`과 `Claude 로그인`은 별도 동작입니다. 저장은 시각·요일·공휴일·macOS 로그인 시 실행 설정만 적용하며 OAuth를 시작하지 않습니다.

`Claude 로그인`을 선택하면 앱이 S256 PKCE와 임의 state를 만들고 `127.0.0.1`의 임시 포트에서 일회성 callback listener를 연 뒤 시스템 브라우저로 Claude 로그인을 시작합니다. callback의 code와 state를 검증해 authorization code를 토큰으로 직접 교환합니다. Claude Code 설치 여부만 확인하며 CLI 인증 명령이나 Claude Code Keychain은 사용하지 않습니다.

access token·회전형 refresh token·만료 시각은 앱 전용 Keychain에만 `AfterFirstUnlockThisDeviceOnly`로 저장합니다. 일반적인 Developer ID 서명 빌드는 다른 앱 Keychain을 읽지 않으므로 cross-app 승인창 원인을 제거합니다. ad-hoc 또는 다시 서명한 개발 빌드는 앱 자체 Keychain ACL이 달라져 승인창이 나타날 수 있습니다.

자동 예약은 인증 UI를 열지 않습니다. access token 만료가 가까우면 앱 전용 refresh token으로 자체 갱신하고, 새 access token·회전된 refresh token·만료 시각을 함께 교체합니다. 만료·401·refresh 실패 시 해당 창을 실패 처리해 후속 2·3번째 창 일정은 유지하고, 잠금 해제 후 `Claude 로그인`을 다시 실행하도록 안내합니다.

이 방식은 Anthropic이 제3자 앱용으로 공식 승인한 Claude.ai OAuth 통합이 아닙니다. 사용자의 명시적 승인 아래 Claude Code OAuth client를 활용하는 내부 MVP이며, callback·token endpoint 또는 정책 변경으로 중단될 수 있습니다.

## 개발 검증

```bash
swift test
```

## Developer ID 서명 빌드

이 Mac의 기본 서명 인증서는 `Developer ID Application: HakKyeol Lee (V9SQZ6B7RP)`입니다. ad-hoc 서명으로 자동 대체하지 않습니다.

```bash
./scripts/build-dmg.sh
```

앱 내 실행 파일과 앱 번들에 hardened runtime·보안 타임스탬프를 적용한 뒤 DMG를 만들고 DMG도 서명합니다. Bundle ID `com.sharknia.ClaudeSessionWarmer`와 Team ID `V9SQZ6B7RP`를 유지합니다. `packaging/designated-requirement.txt`는 같은 팀의 Developer ID 인증서 갱신 후에도 호환되는 조건을 정의합니다. 다른 팀이나 개발용 인증서는 검증 단계에서 거부합니다.

기본 결과물 `dist/ClaudeSessionWarmer-0.1.1-dev.dmg`는 **서명된 내부 검증용**입니다. 공증·stapling 전에는 공개 배포하지 않습니다. 이 Mac에서는 Developer ID 서명의 검증 도구로 기존 앱 Keychain을 비대화형으로 읽는 것까지 확인했습니다.

## 공개 배포 공증

공증용 Keychain 프로필은 별도로 준비해야 합니다. Apple ID와 앱 전용 암호 또는 App Store Connect API 인증으로 `notarytool store-credentials`를 사용해 구성한 뒤 실행합니다. 인증 비밀은 저장소에 넣지 않습니다.

```bash
RELEASE_BUILD=1 NOTARY_PROFILE="claude-session-notary" ./scripts/build-dmg.sh
```

프로필이 없으면 빌드 시작 전에 실패합니다. 앱 ZIP 공증의 `Accepted` 확인 → 앱 stapling·검증·Gatekeeper 평가 → DMG 생성·서명 → DMG 공증의 `Accepted` 확인 → DMG stapling·검증·Gatekeeper 평가를 모두 통과해야 공개 배포 결과물 `dist/ClaudeSessionWarmer-0.1.1.dmg`이 완료됩니다. 현재 실제 공증은 미실행 상태입니다.

Apple 공식 안내: [Developer ID 서명과 공증](https://developer.apple.com/developer-id/).

## 설치와 첫 실행

1. DMG에서 `ClaudeSessionWarmer.app`을 Applications 폴더로 복사해 실행합니다.
2. `Claude 로그인`을 눌러 Claude.ai 계정 승인을 완료합니다.
3. 첫 워밍 시각, 요일, 공휴일 제외 및 macOS 로그인 시 실행 여부를 draft로 설정합니다.
4. `저장`을 눌러 예약을 적용합니다. 저장은 Claude 로그인을 시작하지 않습니다.
5. 메뉴를 열면 최근 5분 캐시를 우선 사용하고, 만료된 경우에만 managed 인증과 사용량을 확인합니다. 정시·수동 워밍 판단은 항상 실조회합니다.

## 현재 상태

managed Claude OAuth 단일계정 흐름과 자동화 테스트는 구현했습니다. 실제 브라우저 callback·token exchange, 회전 refresh, Developer ID 빌드의 앱 Keychain과 화면 잠금 상태 자동 실행은 내부 Mac에서 추가 검증해야 합니다.

비활성 사용량 창에서 PTY 워밍이 일반 Claude 구독의 새 5시간 창을 여는 라이브 앵커 검증은 아직 수행하지 않았습니다. 이 검증을 통과하기 전까지 배포 판단은 **CONDITIONAL GO**입니다.

## 2026-09-07 인증 갱신 검증

현재 앱 인증으로 기존 갱신 요청의 HTTP 400 `invalid_scope`를 재현했습니다. 실제 발급 scope에는 없는 `org:create_api_key`를 고정 목록으로 추가한 것이 원인이었습니다. 갱신 요청은 저장된 발급 scope만 사용하고, scope를 모르면 해당 필드를 생략합니다.

같은 앱 프로세스 안에서 credential 읽기 → 갱신 → Keychain 저장 전체와 로그인 후 저장을 직렬화했습니다. 기존 앱을 종료한 상태에서 동일 서명의 검증 도구로 실제 서비스 코드를 실행해, 재로그인 없이 두 번 연속 갱신·회전·즉시 저장·재읽기 일치와 이후 사용량 조회 성공을 확인했습니다. 다른 앱 프로세스 사이의 갱신 잠금은 이 검증 범위에 포함되지 않습니다.

이 검증은 인증 갱신에 한정합니다. 실제 PTY 워밍 성공과 예약 스케줄러 문제는 별도로 검증해야 합니다. 진단 로그의 `oauth_error`에는 허용된 OAuth 오류 코드만 남기며 응답 원문이나 토큰은 기록하지 않습니다.

## 2026-09-07 워밍 실행 검증

정상 인증에서도 기존 PTY 입력 방식은 30초 타임아웃이 재현됐습니다. 화면에는 프롬프트가 입력돼 있었지만 전송되지 않았습니다. 초기 프롬프트를 CLI 위치 인수로 전달하고, 120×40 PTY와 `--ax-screen-reader`를 사용하도록 수정했습니다. 응답 판정은 ANSI/OSC를 제거한 `claude:` 답변의 성공 마커만 인정하며, 사용자 입력 에코와 터미널 제목은 인정하지 않습니다. 제한 시간은 30초 그대로입니다.

실제 CLI 2.1.258에서 수정된 서비스 코드의 응답 수신과 후속 사용량 조회는 성공했습니다. 당시 사용량 창이 이미 활성 상태였으므로 **비활성 → 활성 전환 검증은 아직 미통과**입니다.

검증 도구는 앱과 동일한 인증서로 서명해야 합니다. 다른 앱 실행과 중복 워밍되지 않도록 조정한 상태에서 실행합니다.

```bash
./scripts/verify-warmup.sh
```

기본 실행은 활성 창이면 호출하지 않고 종료 코드 2를 반환합니다. 비활성일 때만 한 번 워밍하고 최대 25초 동안 사용량을 재조회합니다. `result=inactive_to_active_pass`가 최종 통과입니다. `--allow-active`는 실행 경로 진단용이며 `cli_only_pass`를 최종 통과로 취급하지 않습니다. 토큰·프롬프트·CLI 원문 출력은 기록하지 않습니다.

## 2026-09-07 예약 상태 수정

오늘 첫 창이 한 번 처리됐으면 3분 허용 시간 안에서도 다시 선택하지 않습니다. 처리 완료된 창에 지연 콜백이나 중복 종료가 도착해도 상태를 변경하지 않습니다.

인증 거절·인증 정보 누락·Keychain 오류는 같은 창에서 반복하지 않고 실패 처리 후 다음 fallback 예약으로 이동합니다. 갱신 네트워크 오류·HTTP 429/5xx와 일시적 사용량 조회 오류는 30초 간격으로 기존 3분 허용 범위 안에서 재시도합니다. 워밍이 이미 전송됐을 가능성이 있으면 기존 중복 방지 규칙에 따라 후속 시도는 사용량만 확인합니다.

창별 최초 실패 메시지를 저장하므로 이후 재시도 오류나 재시작 후 허용 시간 만료가 `missed`로 덮어쓰지 않습니다. 새 창에서 시도할 때는 이전 실패를 분리합니다. 실제 장애와 같은 258회 중복 처리, 인증 오류 즉시 종료, 일시적 오류 재시도, 재시작 후 최초 실패 유지 및 다음 창으로 한 번만 이동하는 회귀 테스트를 추가했습니다.

## 월요일 진단

진단 로그는 `~/Library/Logs/ClaudeSessionWarmer/events.jsonl`과 교체본 `events.previous.jsonl`에 JSONL로 남깁니다. 디렉터리는 `0700`, 파일은 `0600`, 각 파일은 2MiB로 제한합니다. app start/heartbeat/terminate, 화면 잠금·display/system sleep·wake, schedule·timer drift, quota HTTP 결과와 response hash·size·top-level keys·`five_hour` 형태/known fields, pre/post 결정, OAuth refresh, PTY spawn/pid/marker/timeout, retry/fallback/final만 기록합니다.

token·authorization header·OAuth code/state/verifier·prompt/output·raw body·경로는 기록하지 않습니다.

월요일에는 `tail -f ~/Library/Logs/ClaudeSessionWarmer/events.jsonl`로 현재 `launch_id`를 확인하고, 각 `target_at`의 schedule → timer drift → quota/PTY → final/fallback 순서를 대조합니다. sleep/wake 사이 공백은 놓친 창과 fallback을, lock 상태의 연속 heartbeat와 timer 발화는 잠금 중 실행을 보여 줍니다. terminate 없는 launch 종료는 비정상 종료 또는 강제 종료로 구분합니다.
