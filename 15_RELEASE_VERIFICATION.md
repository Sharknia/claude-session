# Keychain 검증 및 앱·DMG 공증 운영 절차

2026-09-21 작성. 0.1.7 / 빌드 13 배포에서 확인한 설정과 절차다. [0.1.6 장애 분석](11_UNATTENDED_KEYCHAIN_FIX.md)은 당시의 기록으로 보존하고, 다음 배포에서는 이 문서와 현재 스크립트를 함께 확인한다.

## 각 단계가 확인하는 것

| 단계 | 확인하는 내용 | 이것만으로 확인되지 않는 내용 |
| --- | --- | --- |
| Keychain 검증 | 실제 macOS API로 legacy → Data Protection 이전, 재읽기, 토큰 모양의 시험 값 갱신, 접근 정책 확인 | 실제 사용자 계정의 로그인·갱신, 잠금 중 예약 성공, 새 Mac에서의 동작 |
| 앱 서명·공증 | 앱과 포함된 실행 코드의 Developer ID 서명, Apple 공증 승인, 앱에 티켓 첨부, Gatekeeper 실행 판정 | Keychain의 실제 접근 성공이나 예약 로직의 정확성 |
| DMG 서명·공증 | 사용자에게 배포할 최종 DMG의 서명·공증·티켓·Gatekeeper 열기 판정 | 앱 내부 기능의 실행 결과 |
| Sparkle 서명 | 다운로드한 DMG와 업데이트 피드의 무결성·서명 일치 | Apple 공증이나 기능 검증의 대체가 아님 |

이 프로젝트는 **앱과 DMG를 각각 제출하고 검사한다.** 앱은 ZIP으로 제출한 뒤 앱 자체에 공증 티켓을 붙인다. 그 앱으로 DMG를 만들고 DMG를 다시 제출·검증한다.

## 다음 배포에서도 재사용할 설정

| 용도 | 0.1.7에서 사용한 값 |
| --- | --- |
| Bundle ID | `com.sharknia.ClaudeSessionWarmer` |
| Team ID | `V9SQZ6B7RP` |
| Developer ID | `Developer ID Application: HakKyeol Lee (V9SQZ6B7RP)` |
| 서명 인증서 SHA-1 식별자 | `BAA3087E6C31CF17C49F806DB60D01F0913CD8FB` |
| 프로비저닝 프로필 | `ClaudeSessionWarmer-DeveloperID` |
| 프로필 UUID | `96fa1ff5-ef49-422d-bc52-426d2d4472b3` |
| notarytool의 Keychain 프로필 이름 | `claude-session-notary` |
| Sparkle 서명 키 계정 | `com.sharknia.ClaudeSessionWarmer.sparkle` |
| Sparkle 공개키 | `QWaU6+2OaX2kXVVigERyQ7kejQ5FIE5L/5nDHaWajeA=` |

`claude-session-notary`는 공증 서버에 인증하는 기존 Keychain 항목의 이름이다. **앱의 프로비저닝 프로필과 서로 다른 항목**이다. Safari의 Apple 로그인도 이 CLI 인증 설정을 대체하지 않는다.

새 버전을 배포한다고 인증서·프로필·공증 인증 정보·Sparkle 키를 다시 만들지 않는다. 유효한 기존 설정을 재사용하고, 만료·폐기·팀 또는 App ID 변경 등 실제 불일치가 있을 때만 필요한 항목을 변경한다. 반면 **새로 빌드한 앱과 DMG는 이번 산출물로 공증을 다시 받아야 한다.** 이전 버전의 승인 결과를 새 파일의 승인으로 사용하지 않는다.

프로필은 Git에 넣지 않는다. `prepare-keychain-signing.py auto`는 다음 위치에서 기존 파일을 찾아 App ID·팀·유효기간·배포 유형·Keychain 그룹·서명 인증서 일치를 검사한다.

1. 저장소의 무시된 파일 `packaging/ClaudeSessionWarmer.provisionprofile`
2. `~/Library/Developer/Xcode/UserData/Provisioning Profiles/*.provisionprofile`
3. `~/Library/MobileDevice/Provisioning Profiles/*.provisionprofile`

자동 탐색이 실패하면 먼저 기존 파일과 오류 내용을 확인한다. 필요한 경우에만 `PROVISIONING_PROFILE`로 **기존 프로필 경로**를 지정한다. 생성된 `.build/signing/keychain.entitlements`와 `embedded.provisionprofile`을 서명 및 bundle 구성에 사용한다. 암호·개인키·OAuth 토큰은 문서나 Git에 남기지 않는다.

## 실행 절차

프로젝트 루트에서 실행한다. 우선 저장소·버전·서명 설정을 확인한다.

```sh
git status --short --branch
security find-identity -v -p codesigning
xcrun notarytool history --keychain-profile claude-session-notary --output-format json
```

`packaging/Info.plist`의 제품 버전과 증가하는 빌드 번호를 반영한 뒤, 다음 명령으로 전체 배포 산출물을 만든다.

```sh
CODESIGN_IDENTITY=BAA3087E6C31CF17C49F806DB60D01F0913CD8FB \
  bash scripts/build-dmg.sh
```

`build-dmg.sh`가 아래 순서를 수행하므로 동일한 검증을 별도로 반복할 필요는 없다.

1. 기존 프로필 검증 및 공증 인증 확인.
2. `swift test`와 서명된 `verify-warmup.sh --storage-probe` 실행. 실패하면 기존 배포 산출물을 지우기 전에 중단.
3. release 빌드, Sparkle 내부 코드부터 앱 바깥 순서로 서명. 앱과 실행 파일의 서명·designated requirement 검사.
4. 앱 ZIP 제출 → `dist/app-notarization.json`의 `status=Accepted` 확인 → 앱 `stapler staple/validate` → `spctl --assess --type execute`.
5. 공증한 앱으로 DMG 생성·서명 → `dist/dmg-notarization.json`의 `status=Accepted` 확인 → DMG `stapler staple/validate` → `spctl --assess --type open --context context:primary-signature`.
6. 기존 Sparkle 키로 DMG 서명이 포함된 `dist/appcast.xml` 생성 및 피드 자체 서명·검증.

`RELEASE_BUILD=0`은 내부용 서명 산출물만 만든다. 공증·stapling이 완료된 공개 배포 산출물로 취급하지 않는다.

### Keychain만 확인할 때

```sh
CODESIGN_IDENTITY=BAA3087E6C31CF17C49F806DB60D01F0913CD8FB \
  bash scripts/verify-warmup.sh --storage-probe
```

같은 앱 식별자·서명·권한·포함 프로필로 임시 검증 앱을 만든다. 매 실행마다 다른 `com.sharknia.ClaudeSessionWarmer.probe.<UUID>` 서비스의 시험 항목을 사용하며 실제 계정에는 접근하지 않는다. legacy 항목 생성 → Data Protection 이전·재읽기 → legacy 제거 확인 → 시험 값 갱신·재읽기 → `AfterFirstUnlockThisDeviceOnly` 속성 확인 순서다.

통과 출력은 다음과 같다.

```text
result=storage_probe_pass; backend=data_protection; migration=verified; rotation=verified; accessible=after_first_unlock_this_device_only
```

시험 항목은 종료 시 삭제를 시도하고 임시 앱도 정리한다. 스크립트는 물리 경로를 사용하고, 임시 bundle 삭제 **후** 그 경로의 Launch Services 등록을 해제한다. 확인이 필요하면 생성된 정확한 경로를 기준으로 잔여물 유무를 검사한다. 전체 앱 등록이나 OS 권한을 초기화하지 않는다.

이 검증은 같은 사용자 안에서 시험 데이터만 분리한 검증이다. 별도 macOS 사용자나 개발 프로필 설치 이력이 없는 Mac의 검증을 대신하지 않는다. `--keychain-only`는 실제 앱 인증 정보를 읽고, `--warmup`은 실제 계정의 워밍을 수행하므로 시험 항목 검증과 혼동하지 않는다. 실제 계정 모드는 실행 소유권을 확인하며, 인수 없는 실행은 계정에 접근하지 않고 종료한다.

### 실패한 경우

- 프로필 불일치: 기존 프로필의 앱·팀·인증서와 `CODESIGN_IDENTITY`를 대조한다. 인증서가 여러 개면 SHA-1 식별자로 의도한 인증서를 지정한다.
- Keychain 실패: 원래 OSStatus와 실패 단계를 확인한다. 공증 성공이나 수동 인증 성공만으로 다른 실행 시점의 접근 성공을 단정하지 않는다.
- 공증 실패 또는 대기: 응답의 submission ID로 `notarytool info`를 확인하고 `notarytool log`로 원인을 읽는다. 진행 중인 제출을 확인하지 않은 채 다시 제출하거나 인증 정보를 재생성하지 않는다.

```sh
xcrun notarytool info <submission-id> --keychain-profile claude-session-notary
xcrun notarytool log <submission-id> --keychain-profile claude-session-notary
```

## 공개 전후 확인과 기록

검증한 빌드 소스와 최종 main의 소스 트리가 같은지 확인한 뒤 그 main 커밋에 태그를 붙인다. 릴리즈 초안에 DMG·서명된 appcast·`SHA256SUMS.txt`를 모두 올려 크기와 SHA-256을 대조한 뒤 공개한다. 이미 공개한 이전 버전의 파일은 덮어쓰지 않는다.

공개 후에는 인증 없이 세 파일을 내려받아 로컬 산출물과 대조하고, `releases/latest/download/appcast.xml`도 새 버전·빌드를 가리키는지 확인한다. 내려받은 피드와 DMG의 EdDSA 서명도 검사한다. 배포 완료와 사용자 Mac에 새 버전이 설치된 것은 구분한다.

다음 배포 기록에는 버전·빌드, main/태그 커밋, Keychain 검증 결과, 앱·DMG submission ID와 승인 상태, 파일 크기·SHA-256, 공개 다운로드·최신 피드 확인, 남은 검증 조건을 남긴다. `/tmp` 실행 로그만을 유일한 기록으로 두지 않는다.

## 0.1.7 / 빌드 13 실제 결과

| 항목 | 결과 |
| --- | --- |
| 공개 시각 | 2026-09-21 15:32:32 KST |
| main 및 v0.1.7 대상 커밋 | `8a67bec3395e30e317a77b2d92fadb48677eac81` |
| PR | [dev #16](https://github.com/Sharknia/claude-session/pull/16), [main #17](https://github.com/Sharknia/claude-session/pull/17) 머지 |
| 자동 검증 | 테스트 120개, 실패 0; release 빌드 통과 |
| Keychain | `storage_probe_pass`; 이전·재읽기·갱신·실제 접근 속성 확인 |
| 앱 공증 | `8944eade-ab0f-4ad7-9ee0-21a91a5ec75a` — Accepted |
| DMG 공증 | `6ec0b74f-2db3-45d5-8be1-b4f15dabdec1` — Accepted |
| 앱·DMG 후속 검사 | stapling/validate 및 Gatekeeper accepted |
| DMG | `ClaudeSessionWarmer-0.1.7.dmg`, 3,410,094 bytes |
| DMG SHA-256 | `4cf6edc4e97e3fdc7edc4b28eff0796ca83844e571c4b65bf965757ef2980c51` |
| appcast SHA-256 | `3c873a3620ff4350a77d15b92ea2612aa96dbdb6d8ad372556f4f31eda2a4469` |
| 체크섬 파일 SHA-256 | `668ae1c89d5841c986424d43705cfc98e7bc4a0ae0c81e6d807ef6e4bd1d2f8a` |
| 공개 확인 | 3개 자산의 다운로드 바이트 일치, latest 피드 0.1.7/13 일치, 피드·DMG 서명 통과 |

릴리즈: [v0.1.7](https://github.com/Sharknia/claude-session/releases/tag/v0.1.7). 근거는 공개 자산·체크섬, 로컬 `dist/app-notarization.json`, `dist/dmg-notarization.json`, `/tmp/claude-session-release-017.log`에서 확인했다.

개발 프로필 설치 이력이 없는 별도 Mac/사용자 환경의 설치·Keychain 검증과 새 설치본의 실제 잠금 중 예약 성공은 아직 확인하지 않았다. 공증 결과를 이 검증의 완료로 표시하지 않는다.

관련 스크립트: [프로필 확인](scripts/prepare-keychain-signing.py), [Keychain 검증](scripts/verify-warmup.sh), [배포 빌드](scripts/build-dmg.sh), [업데이트 피드](scripts/generate-appcast.sh).
