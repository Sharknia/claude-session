# 무인 인증 접근 및 자동 복구 수정

2026-09-21, 브랜치 `codex/fix-unattended-keychain`.

제품 버전 0.1.6, 내부 빌드 12. 사용자 요청에 따라 dev → main PR 병합 후 배포한다.

상태: 로컬 구현 및 자동 검증 완료. Developer ID 프로비저닝 프로필이 없어 패키지·실제 Keychain·잠금 상태 검증은 미완료다. 설치된 0.1.5 빌드 11과 실제 인증 정보는 변경하지 않았다. 해결 완료나 다음 06:00 성공으로 판정하지 않는다.

## 확인된 문제

06:00:00.004 타이머 콜백과 06:00:00.008 예약 처리는 정상이다. 06:00:00.055 `keychain_unavailable` 이후 첫 실패에 `retry_at=none`으로 다음 날을 예약했다. 시스템 로그는 `SecItemCopyMatching` 중 `CSSMERR_CSP_OPERATION_AUTH_DENIED`와 무결성 검사 단계 접근 거부를 기록했다. 같은 시각 Keychain은 `unlocked`로 기록됐다. 09:54 화면 잠금 해제는 자동 복구를 호출하지 않았다.

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
- 서명 빌드는 이 앱·팀에 맞는 유효한 Developer ID 프로필을 요구한다. 권한 파일을 프로필에서 검증·생성하고 앱에 프로필을 포함한다. 프로필 없이 새 실행 파일을 설치하지 않는다.

## 검증 결과

| 검증 | 결과 | 한계 |
| --- | --- | --- |
| `swift test` | 94개, 실패 0 | 서비스·Keychain 실패 주입을 사용하는 자동 검증 |
| `swift build -c release` | 성공 | 서명·프로비저닝·실제 접근 검증 아님 |
| `bash scripts/verify-scheduler.sh late 147` | 성공 | 실제 타이머, 가짜 서비스 |
| `python3 scripts/test-keychain-signing.py` | 통과 | 정상 프로필 및 팀·앱·만료·권한 불일치 합성 데이터 |
| `VerifyWarmup.swift` 컴파일 | 성공 | 실제 실행 전 프로필 필요 |
| 프로필 없는 패키지 빌드 | 예상대로 차단 | 기존 설치 앱이나 인증 정보에 접근하지 않음 |

새 회귀 검증은 4회 인증 접근 실패 후 당일 예약 유지, 재시작 후 상태 복원, 화면 잠금 해제의 실제 알림 연결, 복구 후 1회 전송과 중복 콜백 차단을 확인한다. credential 이전 중 쓰기·검증 실패는 원본을 유지하며, Data Protection 접근 거부는 legacy로 우회하지 않는다. 회전 토큰 저장 실패 후 원래 토큰으로 재갱신하지 않는 것도 확인한다.

로컬 실행 결과: `/tmp/claude-session-keychain-tests.log`, `/tmp/claude-session-keychain-release.log`, `/tmp/claude-session-keychain-scheduler.log`.

## 실제 설치 전에 필요한 검증

팀 `V9SQZ6B7RP`, Bundle ID `com.sharknia.ClaudeSessionWarmer`의 Developer ID 배포 프로필이 필요하다. App ID와 Keychain 접근 그룹을 허용해야 한다. 이 Mac의 프로필 폴더와 프로젝트에는 해당 파일이 없다. 프로필 위치는 환경변수 `PROVISIONING_PROFILE`로 전달하며 저장소에는 커밋하지 않는다.

1. `bash scripts/verify-warmup.sh --storage-probe`: 실제 계정과 무관한 임시 항목으로 서명·Data Protection 저장·읽기·실제 반환 접근 정책을 검증한다. 종료 시 임시 항목만 삭제한다.
2. 버전 0.1.6·빌드 12의 `bash scripts/build-dmg.sh`로 서명·공증을 검증한다.
3. 기존 앱의 예약·작업 종료를 확인해 정상 종료하고 새 앱을 설치한다. 구버전과 새 버전을 동시에 실행하지 않는다.
4. 새 앱과 동일한 서명의 `--keychain-only`로 기존 인증 이전 및 재읽기를 확인한다. 이 단계부터 실제 인증 저장소가 이전된다. 이후 구버전으로 되돌리면 재로그인이 필요할 수 있다.
5. 설치 앱이 화면 잠금 중 실제 예약을 처리하는지 확인한다. 만료 토큰 갱신이 필요한 경우 갱신·저장까지 확인한다. 이미 활성인 창의 조회 성공은 새 창 생성 검증과 구별한다.

프로필을 확보하기 전까지 1~5는 수행하지 않는다. 단위 테스트 통과를 무인 실사용 성공으로 보고하지 않는다.
