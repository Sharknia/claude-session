# 무인 인증 접근 및 자동 복구 수정

2026-09-21, 브랜치 `codex/fix-unattended-keychain`.

제품 버전 0.1.6, 내부 빌드 12. 사용자 요청에 따라 dev → main PR 병합 후 배포한다.

상태: 자동 검증, 실제 Keychain의 격리된 이전·갱신 검증, 앱·DMG 서명·공증·stapling·Gatekeeper 검증 완료. 설치된 0.1.5 빌드 11과 실제 계정 인증 정보는 변경하지 않았다. 0.1.6의 실제 잠금 상태 06:00 워밍은 아직 확인하지 않았다.

## 확인된 문제

06:00:00.004 타이머 콜백과 06:00:00.008 예약 처리는 정상이다. 06:00:00.055 `keychain_unavailable` 이후 첫 실패에 `retry_at=none`으로 다음 날을 예약했다. 시스템 로그는 `SecItemCopyMatching` 중 `CSSMERR_CSP_OPERATION_AUTH_DENIED`와 무결성 검사 단계 접근 거부를 기록했다. 같은 시각 Keychain은 `unlocked`로 기록됐다. 09:54 화면 잠금 해제는 자동 복구를 호출하지 않았다.

지난 대화와 현재 보존 로그에서 2026-09-08 06:00에는 기존 저장 방식으로 잠금 중 인증 갱신·저장·워밍이 성공한 것도 확인했다. 기존 방식이 잠금 중 항상 실패한다는 의미는 아니다.

10:13 같은 프로세스의 인증 갱신과 저장이 성공했으므로 인증 정보가 지속적으로 소실·파손됐다고 볼 수 없다. 이것이 06:00의 읽기 접근까지 성공했다는 뜻은 아니다. 최초 접근 거부를 유발한 macOS 내부 상태는 기존 로그만으로 확정하지 않는다.

추가로 기존 `cacheAddPayload`는 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`만 설정하고 `kSecUseDataProtectionKeychain`을 누락했다. Apple은 macOS에서 `kSecAttrAccessible`이 Data Protection Keychain 또는 동기화 항목에만 적용된다고 명시한다. 기존 저장은 file-based Keychain 경로이므로 잠금 중 접근 정책이 적용됐다는 보장이 없었다. 기존 테스트는 옵션 값만 확인했다.

- [Apple kSecAttrAccessible](https://developer.apple.com/documentation/security/ksecattraccessible)
- [Apple TN3137](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains)

## 수정

- 앱 전용 Data Protection Keychain에 `AfterFirstUnlockThisDeviceOnly`로 저장한다. 동기화는 켜지 않는다.
- 새 저장소에 항목이 없을 때만 legacy 앱 항목을 읽는다. 접근 거부·프로필 누락은 항목 부재로 처리하거나 legacy로 우회하지 않는다.
- 기존 credential을 새 저장소에 쓰고 다시 읽어 일치하는 것을 확인한 뒤 legacy 항목을 정리한다. 쓰기나 검증 실패 시 legacy 원본을 유지한다.
- 읽기·추가·수정·이전 검증마다 backend와 원래 OSStatus를 기록한다. 비밀 값은 기록하지 않는다.
- 일시적인 Keychain 접근 거부는 30초 간격으로 3회 추가 확인한 뒤, 당일 미완료 대상에 대해 5분 간격 재확인을 유지한다. 화면 잠금 해제나 실제 인증 접근 성공 시 즉시 복구한다. 서버 인증 거절·잘못된 권한·파손 오류에는 무한 재시도를 적용하지 않는다.
- OAuth 서버가 토큰을 회전했는데 저장이 실패하면 프로세스 메모리에서 새 토큰을 유지하고 다음 시도에서 저장부터 재개한다. 이전 토큰으로 다시 갱신하지 않는다. 저장 성공 전에 프로세스가 강제 종료되면 이 메모리 상태는 유지되지 않는다.
- 서명 빌드는 이 앱·팀에 맞는 유효한 Developer ID 프로필을 요구한다. 권한 파일을 프로필에서 검증·생성하고 앱에 프로필을 포함한다. 프로필에 기존 배포 서명 인증서가 포함됐는지도 SHA-1으로 대조한다. 새 작업 디렉터리에서도 기존 Xcode 프로필을 자동 탐색해 재사용한다. 프로필 없이 새 실행 파일을 설치하지 않는다.

## 검증 결과

| 검증 | 결과 | 한계 |
| --- | --- | --- |
| `swift test` | 94개, 실패 0 | 서비스·Keychain 실패 주입을 사용하는 자동 검증 |
| `swift build -c release` | 성공 | 서명·프로비저닝·실제 접근 검증 아님 |
| `bash scripts/verify-scheduler.sh late 147` | 성공 | 실제 타이머, 가짜 서비스 |
| `python3 scripts/test-keychain-signing.py` | 통과 | 정상 프로필 및 팀·앱·만료·권한 불일치 합성 데이터 |
| `bash scripts/verify-warmup.sh --storage-probe` | 실제 legacy → Data Protection 이전·재읽기·원본 정리·갱신 성공 | 임시 항목만 사용, 실제 계정 미접근 |
| 앱·DMG 공증 및 Gatekeeper | Accepted / accepted | 잠금 중 실제 예약 성공의 증거는 아님 |
| 프로필 없는 패키지 빌드 | 예상대로 차단 | 기존 설치 앱이나 인증 정보에 접근하지 않음 |

새 회귀 검증은 4회 인증 접근 실패 후 당일 예약 유지, 재시작 후 상태 복원, 화면 잠금 해제의 실제 알림 연결, 복구 후 1회 전송과 중복 콜백 차단을 확인한다. credential 이전 중 쓰기·검증 실패는 원본을 유지하며, Data Protection 접근 거부는 legacy로 우회하지 않는다. 회전 토큰 저장 실패 후 원래 토큰으로 재갱신하지 않는 것도 확인한다.

로컬 실행 결과: `/tmp/claude-session-keychain-tests.log`, `/tmp/claude-session-keychain-release.log`, `/tmp/claude-session-keychain-scheduler.log`.

## 배포 설정과 남은 실사용 검증

기존 `Developer ID Application: HakKyeol Lee (V9SQZ6B7RP)` 인증서와 `claude-session-notary` 공증 설정을 그대로 사용했다. Apple 계정에는 같은 Bundle ID `com.sharknia.ClaudeSessionWarmer`를 등록하고, 새 저장 방식에 필요한 프로비저닝 프로필을 추가했다. 이 프로필은 공증 자격을 대체하지 않는다.

- 프로필: `ClaudeSessionWarmer-DeveloperID`, UUID `96fa1ff5-ef49-422d-bc52-426d2d4472b3`
- 앱 인증서 SHA-1: `BAA3087E6C31CF17C49F806DB60D01F0913CD8FB`, 기존 릴리즈와 동일
- 프로필은 Xcode의 표준 로컬 프로필 폴더에 보관하며 Git에 커밋하지 않는다. `bash scripts/build-dmg.sh`는 이 파일을 자동 탐색·검증해 재사용한다. 필요할 때만 `PROVISIONING_PROFILE`로 경로를 지정한다.
- 앱 공증: `30051426-749a-4782-a669-f8f6dc774c3b`, Accepted
- DMG 공증: `8b7f9183-16d6-44ab-9756-ec1182209bca`, Accepted
- `ClaudeSessionWarmer-0.1.6.dmg` SHA-256: `682be9856eca61bfc905de04762af2abe4872bf1bdd6069172057d4bfd322957`
- `appcast.xml` SHA-256: `93c0df397af9ee7a29d5d42cc5776c889a76e8cac84808a5ccbce038acb83642`
- Sparkle 아카이브·피드 서명 검증 완료. 버전 0.1.6 / 빌드 12.

실제 API 검증은 사용자 계정과 분리한 임시 항목을 동일한 앱 서명·권한으로 생성해 수행했다. 접근 정책 `AfterFirstUnlockThisDeviceOnly`의 실제 반환값, legacy 이전과 재읽기, 갱신, legacy 원본 정리를 확인했고 임시 항목은 정리했다. 사용자의 실제 credential을 이전하거나 앱을 재설치하지 않았다.

사용자가 새 앱을 설치한 뒤에는 화면 잠금 중 실제 예약 실행을 관찰해야 한다. 만료 토큰 갱신이 필요한 경우 갱신·저장까지 확인한다. 이미 활성인 창의 조회 성공은 새 창 생성 성공과 구별한다. 기존 인증 정보가 실제로 이전된 뒤 구버전으로 되돌리면 재로그인이 필요할 수 있다.
