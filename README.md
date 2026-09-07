# Claude Session Warmer

[![release](https://img.shields.io/badge/release-v0.1.3-orange?style=flat-square)](https://github.com/Sharknia/claude-session/releases/latest)
[![asset downloads](https://img.shields.io/badge/asset%20downloads-1-yellowgreen?style=flat-square)](https://github.com/Sharknia/claude-session/releases)
![languages](https://img.shields.io/badge/languages-한국어-green?style=flat-square)
[![license](https://img.shields.io/badge/license-MIT-green?style=flat-square)](LICENSE)

정해진 시각에 Claude Code의 5시간 사용량 창을 준비하는 macOS 메뉴바 앱입니다. 업무 시작 전에 첫 창을 열고, 실제 리셋 시각에 맞춰 후속 창을 관리합니다.

## 주요 기능

- 첫 워밍 시각과 실행 요일 설정
- 대한민국 공휴일 제외 옵션
- 사용량 창이 이미 열려 있으면 추가 호출 생략
- 수동·자동 워밍 후 간격을 두고 세션 활성화 확인
- 실제 리셋 시각을 기준으로 하루 최대 3개 창 관리
- 현재 사용량, 실행 결과, 다음 예약 확인
- 수동 워밍 및 macOS 로그인 시 자동 실행
- 앱 전용 Keychain에 인증 정보를 저장하고 자동 갱신

## 요구 환경

- Apple Silicon Mac
- macOS 14 이상
- Claude Code 설치
- Claude.ai 유료 구독 계정
- 인터넷 연결

## 설치

1. [최신 릴리즈](https://github.com/Sharknia/claude-session/releases/latest)에서 DMG를 다운로드합니다.
2. DMG를 열고 **ClaudeSessionWarmer.app**을 옆의 **Applications** 폴더로 드래그합니다.
3. 응용 프로그램 폴더에서 앱을 실행합니다. 메뉴바에 앱 아이콘이 나타납니다.

배포용 앱과 DMG는 Developer ID로 서명하고 Apple 공증을 거칩니다.

## 사용법

1. 메뉴바에서 앱을 열고 **Claude 로그인**을 선택해 브라우저에서 계정을 연결합니다.
2. 첫 워밍 시각, 실행 요일, 공휴일 제외 여부를 설정합니다.
3. 필요하면 **macOS 로그인 시 실행**을 켜고 **저장**합니다.
4. 앱을 실행 상태로 두면 예약 시각에 사용량 창을 확인하고, 필요한 경우에만 워밍합니다.

일정 저장과 Claude 로그인은 별도 동작입니다. 이미 열린 창은 다시 워밍하지 않으며, 첫 창 실행에 실패해도 해당 예약 시각에서 5시간 뒤의 후속 예약은 유지합니다.

## 사용 시 참고

- 화면 잠금이나 디스플레이 꺼짐과 시스템 잠자기는 다릅니다. 예약 실행을 위해 Mac이 깨어 있고 인터넷에 연결돼 있어야 합니다.
- 시스템 잠자기, 덮개 닫힘, 종료 또는 로그아웃으로 놓친 예약은 나중에 따라잡지 않습니다. 밤사이 실행할 때는 전원을 연결하고 덮개를 열어 두세요.
- 앱은 Claude Code의 인증 정보와 별도로 계정을 연결합니다. 인증 정보는 앱 전용 macOS Keychain에 저장합니다.
- Anthropic의 공식 앱이나 공식 승인된 제3자 OAuth 통합은 아닙니다. Claude의 인증 방식이나 서비스 정책 변경에 영향을 받을 수 있습니다.

## 라이선스

[MIT License](LICENSE)
