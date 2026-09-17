# Claude Session Warmer

[![release](https://img.shields.io/badge/release-v0.1.5-orange?style=flat-square)](https://github.com/Sharknia/claude-session/releases/latest)
[![asset downloads](https://img.shields.io/badge/asset%20downloads-1-yellowgreen?style=flat-square)](https://github.com/Sharknia/claude-session/releases)
![languages](https://img.shields.io/badge/languages-한국어-green?style=flat-square)
[![license](https://img.shields.io/badge/license-MIT-green?style=flat-square)](LICENSE)

정해진 시각부터 Claude Code의 5시간 사용량 창을 준비하는 macOS 메뉴바 앱입니다. 업무 시작 전에 첫 창을 열고, 실제 리셋 시각에 맞춰 후속 창을 관리합니다.

> 0.1.5부터 잠자기·앱 종료로 지연된 당일 예약을 복구합니다. 이미 활성인 창과 미확인 전송을 확인해 중복 워밍을 방지합니다.

## 주요 기능

- 첫 워밍 시각과 실행 요일 설정
- 대한민국 공휴일 제외 옵션
- 사용량 창이 이미 열려 있으면 추가 호출 생략
- 수동·자동 워밍 후 간격을 두고 세션 활성화 확인
- 실제 리셋 시각을 기준으로 하루 최대 3개 창 관리
- 현재 사용량, 실행 결과, 다음 예약 확인
- 수동 워밍 및 macOS 로그인 시 자동 실행
- 앱 전용 Keychain에 인증 정보를 저장하고 자동 갱신
- 앱 안에서 업데이트 확인 및 설치·재시작

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

일정 저장과 Claude 로그인은 별도 동작입니다. 이미 열린 창은 다시 워밍하지 않습니다. 지연되거나 실패한 작업은 완료 횟수를 소진하지 않으며, 후속 예약은 확인된 실제 리셋 시각을 따릅니다.

메뉴 하단에서 현재 버전을 확인하고 **업데이트 확인**을 누를 수 있습니다. 새 버전의 설치를 승인하면 다운로드·서명 검증 후 앱이 다시 시작됩니다. 자동 설치는 기본으로 켜져 있지 않으며, 워밍 중에는 업데이트를 확인할 수 없습니다. 업데이트 기능이 없는 기존 버전에서는 지원 버전을 한 번 직접 설치해야 합니다.

## 사용 시 참고

- 화면 잠금이나 디스플레이 꺼짐과 시스템 잠자기는 다릅니다. 예약 실행을 위해 Mac이 깨어 있고 인터넷에 연결돼 있어야 합니다.
- 예약 전에 잠들었다가 예정 시각 전에 깨어나면 원래 예약 시각을 유지합니다. 잠들었던 시간만큼 예약이 뒤로 밀리지 않도록 복귀 시 일정을 다시 계산합니다.
- 잠자기나 앱 종료로 늦어진 당일 예약은 복귀·앱 시작·지연 콜백에서 현재 세션을 확인한 뒤 처리합니다. 전날 예약을 몰아서 실행하지 않으며 Mac을 강제로 깨우지는 않습니다.
- 일시 실패는 30초 간격으로 최대 3회 추가 재시도합니다. 계속 실패하면 원인을 표시하고 복귀 또는 `지금 워밍`에서 다시 확인합니다.
- 전송 결과가 불명확하면 자동 재전송하지 않습니다. 필요하면 `미확인 전송을 해제하고 다시 워밍…`에서 별도로 확인할 수 있습니다.
- 구버전에서 업데이트한 당일에는 기존 처리 수를 상한으로 보존합니다. 새 집계는 다음 실행일부터 적용돼 도입 당일 목표가 조기 종료될 수 있습니다.
- 앱은 Claude Code의 인증 정보와 별도로 계정을 연결합니다. 인증 정보는 앱 전용 macOS Keychain에 저장합니다.
- Anthropic의 공식 앱이나 공식 승인된 제3자 OAuth 통합은 아닙니다. Claude의 인증 방식이나 서비스 정책 변경에 영향을 받을 수 있습니다.

## 라이선스

[MIT License](LICENSE)
