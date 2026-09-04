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
- Claude Code 설치
- Claude Code 설치 및 Claude.ai 유료 구독 계정

## Claude 인증

일정 `저장`과 `Claude 로그인`은 별도 동작입니다. 저장은 시각·요일·공휴일·macOS 로그인 시 실행 설정만 적용하며 OAuth를 시작하지 않습니다.

`Claude 로그인`을 선택하면 앱은 사용자 확인 후 `claude auth login --claudeai`에 로그인을 위임합니다. 로그인 전 기본 Claude Code credential을 임시 보관하고, 로그인 결과의 access token·회전형 refresh token·만료 시각을 앱 전용 Keychain에 `AfterFirstUnlockThisDeviceOnly`로 저장한 뒤 기본 credential을 원래 값으로 복구합니다. 앱은 이 단일 managed credential만 사용하며 다중 계정과 앱 내 로그아웃은 지원하지 않습니다.

자동 예약은 인증 UI를 열지 않습니다. access token 만료가 가까우면 앱 전용 refresh token으로 자체 갱신하고, 새 access token·회전된 refresh token·만료 시각을 함께 교체합니다. 만료·401·refresh 실패 시 해당 창을 실패 처리해 후속 2·3번째 창 일정은 유지하고, 잠금 해제 후 `Claude 로그인`을 다시 실행하도록 안내합니다.

이 방식은 Anthropic이 제3자 앱용으로 공식 승인한 Claude.ai OAuth 통합이 아닙니다. 사용자의 명시적 승인 아래 Claude Code OAuth client와 CLI 로그인 흐름을 활용하는 내부 MVP이며, Anthropic의 정책이나 OAuth 동작 변경으로 중단될 수 있습니다.

## 개발 검증

```bash
swift test
```

개발용 ad-hoc 서명 DMG를 만듭니다.

```bash
./scripts/build-dmg.sh
```

결과물은 `dist/ClaudeSessionWarmer-0.1.0-dev.dmg`입니다.

## 내부 배포 DMG

Developer ID 인증서와 `notarytool` Keychain 프로필을 지정합니다.

```bash
RELEASE_BUILD=1 \
CODESIGN_IDENTITY="Developer ID Application: Example Company (TEAMID)" \
NOTARY_PROFILE="claude-session-notary" \
./scripts/build-dmg.sh
```

스크립트는 Developer ID 서명과 hardened runtime을 적용하고, DMG 공증 완료를 기다린 뒤 티켓을 stapling합니다.

## 설치와 첫 실행

1. DMG에서 `ClaudeSessionWarmer.app`을 Applications 폴더로 복사해 실행합니다.
2. `Claude 로그인`을 눌러 Claude.ai 계정 승인을 완료합니다.
3. 첫 워밍 시각, 요일, 공휴일 제외 및 macOS 로그인 시 실행 여부를 draft로 설정합니다.
4. `저장`을 눌러 예약을 적용합니다. 저장은 Claude 로그인을 시작하지 않습니다.
5. 메뉴를 열면 managed 인증과 사용량을 자동으로 확인합니다.

## 현재 상태

managed Claude OAuth 단일계정 흐름과 자동화 테스트는 구현했습니다. 실제 브라우저 로그인, 기본 Claude Code credential 원상복구, 회전 refresh와 화면 잠금 상태 자동 실행은 내부 Mac에서 추가 검증해야 합니다.

비활성 사용량 창에서 PTY 워밍이 일반 Claude 구독의 새 5시간 창을 여는 라이브 앵커 검증은 아직 수행하지 않았습니다. 이 검증을 통과하기 전까지 배포 판단은 **CONDITIONAL GO**입니다.
