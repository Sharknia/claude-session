# 업데이트 확인과 원클릭 설치

상태: 업데이트 기능 구현·자동 테스트·SDK 설치 경로 검증 완료. 2026-09-17 사용자 요청에 따른 릴리스 버전은 0.1.5, 내부 빌드는 11이다. 아래 2026-09-14 결과는 0.1.4 개발 당시 기록이다.

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

배포용 빌드는 앱·DMG 서명, 공증, stapling 후 `generate-appcast.sh`를 실행해 서명된 목록을 생성한다. 현재 브랜치의 출력은 `dist/ClaudeSessionWarmer-0.1.5.dmg`와 `dist/appcast.xml`이다. 서명 키나 공증 프로필에 접근하지 못하면 배포용 결과를 성공 처리하지 않는다.

별도 테스트 아카이브나 다른 다운로드 주소를 검증할 때는 다음 형식을 사용한다.

```bash
bash scripts/generate-appcast.sh <아카이브 경로> <다운로드 URL 접두사> <출력 XML 경로>
```

실제 업데이트 목록의 공개 게시와 제품 릴리스 게시는 구현·로컬 검증과 구분해 확인한다. v0.1.5 릴리스에는 공증된 DMG, 서명된 appcast.xml, SHA256SUMS.txt를 함께 게시한다. 기존 로컬 검증 빌드 10에서도 업데이트를 인식하도록 내부 빌드를 11로 증가시킨다.

## 검증 기준

- 기존 예약 관련 테스트 통과
- 업데이트 목록과 아카이브 서명 검증, 변조된 목록 거부
- 동일 제품 버전에서도 빌드 번호 증가를 새 업데이트로 인식
- 격리된 테스트 앱에서 다운로드 → 교체 → 재실행 확인
- 업데이트 후 설정 유지와 예약 재등록 확인
- 실제 설치 앱에서 버전 표시와 업데이트 확인 버튼 확인
- 실제 게시된 업데이트 목록의 HTTPS 응답과 서명 검증

검증을 위해 사용자 앱에 테스트용 업데이트를 게시하거나, 기존 공개 DMG를 덮어쓰거나, 사용자 인증 정보를 초기화하지 않는다.

## 2026-09-14 검증 결과

- 최종 코드 `5ae434c`, 전체 테스트 83개 통과. 설치 승인 없이 자동 진행하지 않음, 승인 후 추가 재시작 클릭 생략, 취소 시 승인 해제, 워밍 완료 후 지연 설치 재개를 포함한다.
- Sparkle 2.10.0 공식 소스의 `sparkle-cli`를 별도 테스트 드라이버로 컴파일해 SDK의 실제 다운로드·설치 경로를 검증했다.
- 테스트 앱은 `com.sharknia.ClaudeSessionWarmer.UpdateVerification`이라는 별도 식별자를 사용했다. 사용자 앱과 설정·프로세스를 분리했다.
- 제품 버전은 양쪽 모두 0.1.4, 내부 빌드 7→8로 검증했다. 업데이트 발견, 파일 다운로드, 검증·추출, 교체, 재시작 성공. 이전 PID 17282는 종료됐고 새 PID 17313으로 재실행됐다.
- 교체 후 빌드 8과 설정 값 `updateProbeMarker=preserved` 유지, 코드 서명 검증 성공. 재확인은 새 업데이트 없음(exit 4)으로 종료됐다.
- 서명 뒤 제목을 변조한 테스트 피드는 오류 1000으로 거부됐으며 설치되지 않았다.
- 테스트 서버와 테스트 앱은 종료하고 테스트 설정을 정리했다. 이 설치 경로 검증은 Developer ID 서명된 테스트 복사본으로 수행했으며, 최종 공증된 운영 빌드 사이의 업데이트 검증과는 구분한다.
- 원클릭 UI 어댑터의 승인 분기는 단위 테스트로 확인했다. 자동 화면 조작은 접근 시간 초과로 미실시지만, 실제 설치 앱에서 12:55:45 업데이트 확인 요청과 12:55:46 최신 상태 응답이 기록돼 실제 버튼 호출·응답 경로도 확인했다.

공개 피드 초기 연결:

- 기존 v0.1.3 릴리스에 서명된 `appcast.xml`만 추가했다. 기존 DMG는 변경하지 않았고 0.1.4 제품 릴리스는 게시하지 않았다.
- 피드는 실제 공개된 0.1.3/빌드 5와 기존 DMG를 가리킨다. DMG의 공개 SHA256SUMS와 로컬 파일 해시가 일치함을 확인하고 EdDSA로 서명했다.
- 앱의 실제 `SUFeedURL`에 HTTPS로 접근해 동일 파일 다운로드와 서명 검증을 확인했다.
- 게시 피드 SHA-256: `521d35743a362c2433e17549b17358724603b1a0c1e25df4b650b23919b90b2c`
- 공개 피드에 대한 SDK 확인 결과: 새 업데이트 없음. 개발 중인 빌드 8/9가 공개 빌드 5보다 새 버전이므로 정상이다.

공증 프로필 접근이 복구돼 최신 빌드 9의 앱·DMG 공증과 서명된 appcast 생성까지 완료했다. 배포 후보는 [ClaudeSessionWarmer-0.1.4.dmg](/Users/crobat/dev/claude-session/dist/ClaudeSessionWarmer-0.1.4.dmg)이며, [appcast.xml](/Users/crobat/dev/claude-session/dist/appcast.xml)과 함께 새 릴리스에 올려야 한다. 아직 0.1.4 제품 릴리스는 게시하지 않았다. 공증 ID와 해시는 [07 검증 기록](/Users/crobat/dev/claude-session/07_SCHEDULER_FIX_VALIDATION.md)에 보존한다. 기존 `-dev.dmg`는 배포에 사용하지 않는다.

## 근거

- [Sparkle 기본 설정](https://sparkle-project.org/documentation/)
- [SwiftUI 연결](https://sparkle-project.org/documentation/programmatic-setup/)
- [설정과 서명 정책](https://sparkle-project.org/documentation/customization/)
- [업데이트 배포](https://sparkle-project.org/documentation/publishing/)
