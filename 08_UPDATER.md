# 업데이트 확인과 원클릭 설치

상태: 업데이트 확인·설치 연결 구현 및 검증 진행 중. 제품 버전은 사용자 지시에 따라 0.1.4로 고정하고 내부 빌드 번호만 증가시킨다.

## 사용자 동작

1. 메뉴 하단에서 현재 버전·빌드를 확인한다.
2. `업데이트 확인`을 누르면 새 버전을 확인한다.
3. 새 버전이 있으면 설치를 한 번 승인한다. 다운로드와 서명 검증이 끝나면 추가 재시작 확인 없이 설치·재시작을 이어간다.
4. 최신 버전이면 최신 상태를 표시하고, 네트워크·서명 검증 실패는 오류로 알린다.

자동 확인·무인 자동 설치는 기본으로 켜지 않는다. 시스템 정보 전송도 비활성화한다. 워밍 중에는 업데이트 확인 버튼을 비활성화하며, 설치 직전 워밍이 진행 중이면 완료까지 재시작을 미룬다.

업데이트 기능이 없는 기존 0.1.3 사용자는 업데이트 지원 버전을 한 번 직접 설치해야 한다. 그 이후부터 앱 안의 업데이트 확인을 사용할 수 있다.

## 구현

- Sparkle 2.10.0을 Swift Package Manager로 고정하고 Package.resolved를 커밋한다.
- `SPUUpdater`가 확인, 다운로드, 검증, 설치, 재시작을 처리한다. `OneClickUpdateUserDriver`는 Sparkle 기본 UI에 위임하되 사용자가 설치를 승인한 경우에만 두 번째 재시작 확인을 생략한다. 취소·건너뛰기·오류에서는 승인 상태를 해제한다.
- SwiftUI는 `canCheckForUpdates`와 워밍 상태를 관찰한다.
- 제품 버전과 내부 빌드를 분리한다. Sparkle은 증가하는 `CFBundleVersion`으로 업데이트 여부를 비교한다.
- 아카이브와 업데이트 목록은 EdDSA로 서명하고, 내려받은 파일은 추출 전에 검증한다.
- 개인 서명 키는 Keychain의 `com.sharknia.ClaudeSessionWarmer.sparkle` 계정에 보관하고 내보내지 않는다. 앱에는 공개키만 포함한다.
- Sparkle 프레임워크와 내부 실행 파일을 앱에 포함하고 기존 Developer ID로 서명한다.

## 배포 연결

업데이트 목록 주소는 `https://github.com/Sharknia/claude-session/releases/latest/download/appcast.xml`이다. 이후 각 GitHub 릴리스에는 DMG와 서명된 `appcast.xml`을 함께 올려야 한다. 자동 생성 이후 XML을 편집하면 서명이 무효화되므로 재서명해야 한다.

```bash
bash scripts/build-dmg.sh
```

배포용 빌드는 앱·DMG 서명, 공증, stapling 후 `generate-appcast.sh`를 실행해 서명된 목록을 생성한다. 현재 브랜치의 출력은 `dist/ClaudeSessionWarmer-0.1.4.dmg`와 `dist/appcast.xml`이다. 서명 키나 공증 프로필에 접근하지 못하면 배포용 결과를 성공 처리하지 않는다.

별도 테스트 아카이브나 다른 다운로드 주소를 검증할 때는 다음 형식을 사용한다.

```bash
bash scripts/generate-appcast.sh <아카이브 경로> <다운로드 URL 접두사> <출력 XML 경로>
```

실제 업데이트 목록의 공개 게시와 새 제품 릴리스 게시는 구현·로컬 검증과 구분해 기록한다. 0.1.5는 이 브랜치의 배포 버전으로 사용하지 않는다.

## 검증 기준

- 기존 예약 관련 테스트 통과
- 업데이트 목록과 아카이브 서명 검증, 변조된 목록 거부
- 동일 제품 버전에서도 빌드 번호 증가를 새 업데이트로 인식
- 격리된 테스트 앱에서 다운로드 → 교체 → 재실행 확인
- 업데이트 후 설정 유지와 예약 재등록 확인
- 실제 설치 앱에서 버전 표시와 업데이트 확인 버튼 확인
- 실제 게시된 업데이트 목록의 HTTPS 응답과 서명 검증

검증을 위해 사용자 앱에 테스트용 업데이트를 게시하거나, 기존 공개 DMG를 덮어쓰거나, 사용자 인증 정보를 초기화하지 않는다.

## 근거

- [Sparkle 기본 설정](https://sparkle-project.org/documentation/)
- [SwiftUI 연결](https://sparkle-project.org/documentation/programmatic-setup/)
- [설정과 서명 정책](https://sparkle-project.org/documentation/customization/)
- [업데이트 배포](https://sparkle-project.org/documentation/publishing/)
