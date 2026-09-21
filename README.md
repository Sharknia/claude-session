# Claude Session Warmer

[![release](https://img.shields.io/badge/release-v0.1.7-orange?style=flat-square)](https://github.com/Sharknia/claude-session/releases/latest)
[![asset downloads](https://img.shields.io/badge/asset%20downloads-1-yellowgreen?style=flat-square)](https://github.com/Sharknia/claude-session/releases)
![languages](https://img.shields.io/badge/languages-한국어-green?style=flat-square)
[![license](https://img.shields.io/badge/license-MIT-green?style=flat-square)](LICENSE)

정해진 시각부터 Claude Code의 5시간 사용량 창을 준비하는 macOS 메뉴바 앱입니다. 업무 시작 전에 첫 창을 열고, 실제 리셋 시각에 맞춰 후속 창을 관리합니다.

> 0.1.7은 중복 실행 방지, 실행 기록의 영속 저장, 손상된 설정의 복구를 보강합니다. 일시적인 네트워크·인증 장애 뒤에도 당일 예약을 재확인합니다.

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

유지보수용 절차와 승인·체크섬 기록은 [Keychain 검증 및 앱·DMG 공증 운영 절차](15_RELEASE_VERIFICATION.md)에 정리했습니다.

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
- 일시 실패는 30초 간격으로 최대 3회 추가 재시도합니다. 인증 정보 접근이 일시적으로 거부되면 이후에도 당일 예약을 유지해 5분 간격으로 확인하고, 화면 잠금 해제 시 바로 재시도합니다. 그 밖의 지속적인 실패는 원인을 표시합니다.
- 전송 결과가 불명확하면 자동 재전송하지 않습니다. 필요하면 `미확인 전송을 해제하고 다시 워밍…`에서 별도로 확인할 수 있습니다.
- 구버전에서 업데이트한 당일에는 기존 처리 수를 상한으로 보존합니다. 새 집계는 다음 실행일부터 적용돼 도입 당일 목표가 조기 종료될 수 있습니다.
- 앱은 Claude Code의 인증 정보와 별도로 계정을 연결합니다. 인증 정보는 앱 전용 macOS Data Protection Keychain에 저장하며, Mac 재시작 후 첫 로그인부터 접근할 수 있습니다.
- Anthropic의 공식 앱이나 공식 승인된 제3자 OAuth 통합은 아닙니다. Claude의 인증 방식이나 서비스 정책 변경에 영향을 받을 수 있습니다.

## 0.1.7의 실행·저장소 보호

0.1.7부터 적용하는 동작입니다. 0.1.6 이하 설치본에는 다음 보호가 없습니다.

- 운영 앱은 `/Applications/ClaudeSessionWarmer.app` 한 곳에서 실행합니다. 다른 경로에서는 예약·로그인 등록·업데이트를 시작하지 않습니다. 같은 사용자의 중복 실행은 OS 파일 잠금으로 막습니다.
- 0.1.6 이하의 구버전은 새 잠금을 따르지 않습니다. 전환 전에 구버전을 정상 종료하고 사용하지 않는 복사본을 정리해야 합니다. 새 앱이 구버전을 감지하면 후속 작업을 멈춥니다.
- 손상된 예약 설정은 원본을 남기고 메뉴의 초안을 저장해 복구합니다. 손상된 실행 기록은 **실행 기록 복구…**에서 명시적으로 복구합니다. 복구 당일에는 자동 워밍을 중지하며, 마지막 전송이 불확실하면 상태 확인이나 재전송 여부를 따로 선택합니다.
- 더 새로운 저장 형식은 덮어쓰지 않습니다. 호환되는 앱으로 업데이트해야 합니다. 저장 장치의 일시 오류는 **다시 읽기**로 재확인할 수 있습니다.
- 예약 설정은 별도 버전 키에, 실행 기록은 `~/Library/Application Support/com.sharknia.ClaudeSessionWarmer/runtime-state.json`에 둡니다. 정상 백업·이전 원본·손상 원본도 같은 폴더에 보존합니다. 인증 토큰은 계속 Keychain에만 보관합니다. 운영 중 이 폴더나 잠금 파일을 삭제하지 마세요.
- macOS에서 로그인 실행을 끈 뒤 예약 시각만 바꿔도 자동으로 다시 켜지지 않습니다. 캐시 비우기는 예약·실행 기록·인증을 초기화하지 않습니다.

검증 명령은 `swift test`, `swift build -c release`, `python3 scripts/verify-execution.py`, `python3 scripts/verify-concurrent-storage.py`, `bash scripts/verify-scheduler.sh late 147`입니다. 단위 테스트와 타이머 검증은 메모리 설정을 사용합니다. 서명된 Keychain 검증은 임시 항목을 사용합니다. 별도 Mac/사용자 환경의 설치 검증 여부는 운영 절차와 검증 결과에 구분해 기록합니다.

개발 잔여물 정리는 `scripts/apply-cleanup-manifest.py`로 검토한 목록만 적용합니다. 기본 실행은 현재 앱 해시·프로세스·등록 항목·빈 전용 설정 도메인을 재확인하며, `--apply`를 붙였을 때만 정리합니다. 결과 JSON에 앱의 휴지통 위치와 설정 백업 경로를 기록합니다. 앱 복구는 해당 휴지통 항목을 원래 경로로 되돌리고, 설정 복구는 `defaults import <도메인> <백업 plist>`로 수행합니다. 운영 중인 앱과 귀속이 불분명한 일반 테스트 도메인은 정리 대상에서 제외합니다.

메뉴 복구 화면은 `bash scripts/preview-recovery-menu.sh settings` (`runtime`, `future`도 지원)로 확인할 수 있습니다. 이 창의 설정·조회·로그인·워밍은 모두 시험용이며 운영 계정을 사용하지 않습니다. 상세 검증 결과와 아직 필요한 설치 환경은 [안정화 검증 결과](14_RELIABILITY_ACCEPTANCE.md)에 기록했습니다.

Keychain 검증은 `bash scripts/verify-warmup.sh --storage-probe`로 분리된 임시 항목만 사용합니다. 실제 계정으로 확인하려면 `--keychain-only` 또는 `--warmup`을 명시해야 하며, 다른 제품 인스턴스가 실행 중이면 계정에 접근하지 않습니다. 인수 없는 실행은 워밍하지 않고 종료합니다.

## 라이선스

[MIT License](LICENSE)
