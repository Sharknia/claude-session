# Claude Session Warmer

정해진 근무일의 Claude Code 5시간 사용량 창을 준비하는 내부 배포용 macOS 메뉴바 앱입니다.

## MVP 정책

- 사용자가 지정한 첫 시각에 첫 번째 창을 확인하고 필요할 때만 워밍합니다.
- 실제 `resets_at`을 우선 따르고, 실패·놓침에는 `targetAt + 5시간` fallback으로 후속 워밍을 최대 2회 수행해 하루 최대 3개 창을 관리합니다.
- 선택한 요일에만 실행하며, 기본적으로 대한민국 공휴일을 제외합니다.
- 화면 잠금과 디스플레이 꺼짐 상태는 지원합니다.
- 시스템 잠자기, MacBook 덮개 닫힘, 종료, 로그아웃 중 놓친 실행은 나중에 따라잡지 않습니다.

## 요구 환경

- macOS 14 이상
- Apple Silicon Mac
- Claude Code 설치
- Claude Code에서 `claude.ai` 구독 계정으로 로그인

저장 시 access token만 이 Mac의 앱 전용 Keychain cache에 보관하며 refresh token은 저장하지 않습니다. 자동 예약은 UI 없이 cache를 사용하고, 401·만료 시 잠금 해제 후 `새로고침`이 필요합니다.

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
2. 첫 워밍 시각, 요일, 공휴일 제외 및 로그인 실행 여부를 draft로 설정합니다.
3. `저장`을 눌러 예약을 적용하고, 필요하면 Claude Code Keychain 읽기 요청을 승인합니다.
4. `새로고침`으로 CLI·인증·사용량을 확인합니다.

## 현재 상태

구현, 자동화 테스트, ad-hoc 앱 서명 및 개발 DMG 생성은 실제 모델 호출 없이 검증했습니다.

비활성 사용량 창에서 PTY 워밍이 일반 Claude 구독의 새 5시간 창을 여는 라이브 앵커 검증은 아직 수행하지 않았습니다. 이 검증을 통과하기 전까지 배포 판단은 **CONDITIONAL GO**입니다.
