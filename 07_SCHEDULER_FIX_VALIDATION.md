# 실제 시각 예약 수정 검증 기록

작성일: 2026-09-14 (Asia/Seoul)

상태: 구현·자동 테스트·기본 타이머 검증·서명·공증·설치 완료. 오늘·내일 이후 실사용 예약 관찰 중.

최신 설치본 변경: 사용자 지시에 따라 제품 버전을 0.1.4로 고정했다. 버전 표시·원클릭 업데이트를 포함한 현재 설치본은 0.1.4 빌드 9다. 공증 프로필 접근이 복구돼 빌드 9의 별도 공증·stapling과 설치 앱의 Gatekeeper 검증을 완료했다. 아래 빌드 6 결과는 과거 검증 기록이다.

## 코드와 작업 브랜치

- 기준: 최신 `origin/main`의 `fe1a3c6431004b31fdff4210a86874c76a1fed2b`에서 분기
- 브랜치: `codex/fix-wall-clock-scheduling`
- 검증 대상 코드: `7eb2062` (0.1.4, 빌드 6)
- 서브에이전트 사용 없음
- 기존 `05_UNATTENDED_VALIDATION.md` 수정분은 보존하고 이번 커밋에서 제외

## 완료된 검증

| 항목 | 결과 | 근거 |
|---|---|---|
| 전체 자동 테스트 | 81개, 실패 0개 | 2026-09-14 11:15:44 종료, [테스트 로그](/Users/crobat/dev/claude-session/.build/scheduler-tests.log) |
| release 빌드 | 통과 | 패키징 로그의 `Build complete! (4.52s)` |
| 벽시계 타이머 기본 동작 | 통과 | 실제 AppState → 타이머 → 가짜 사용량 조회 → 결과 저장 → 후속 예약 |
| 잠자기 없는 실행을 잠자기 검증으로 오인하지 않음 | 통과 | `before 5`에서 sleeps=0, wakes=0으로 exit 1 |
| 취소·해제·observer 수명 | 통과 | `WallClockTimerTests` |
| 복귀·시계 변경·주말·5초/3분·재시도·설정 변경 경합 | 통과 | `SchedulerRecoveryTests` 10개 |
| 콜백부터 완료까지 동일 예약 식별자 연결 | 통과 | 아래 실제 타이머 로그 |

기본 타이머 검증은 `bash scripts/verify-scheduler.sh awake 5`로 수행했다. 프로세스 이름은 `ClaudeSessionWarmerTests-SleepProbe`, PID는 70954다. 가짜 서비스는 활성 상태를 반환하며 실제 Claude 호출과 인증 정보 접근은 하지 않는다.

- launch: `7E75C05E-3361-4939-AA52-FF0FF49620F6`
- 예약 식별자: `47719723-72C7-4B97-A7A8-B18A9A2F8959`
- 목표: 11:14:39.892
- 백그라운드 콜백: 11:14:39.899, 지연 약 7ms
- MainActor 처리: 11:14:39.900, 지연 약 8ms
- 가짜 사용량 조회 시작 지연: 약 14.53ms
- 조회 1회, 실제 워밍 0회, `already_active` 처리 및 다음 5시간 목표 등록

검증 도구의 실패 판정을 확인하기 위해 PID 64911의 `before 5` 실행에서는 잠자기를 수행하지 않았다. 타이머와 가짜 조회는 정상이었지만 `result=failed inspections=1 sleeps=0 wakes=0` 및 exit 1을 확인했다. 이것은 예상된 도구 검증 결과이며 앱 결함으로 분류하지 않는다.

## 실기기 검증 절차와 남은 항목

2026-09-14 사용자는 강제 잠자기 반복 테스트를 원하지 않으며 오늘 실사용과 내일 이후 자연스러운 환경의 테스트로 대체하도록 지시했다. 아래 도구는 보존하되 현재 필수 검증으로 실행하지 않는다.

검증 프로그램은 실제 앱과 동일한 AppState, WallClockTimer, LifecycleMonitor를 컴파일한다. 격리된 UserDefaults와 가짜 서비스를 사용하므로 실제 사용량 창을 열지 않는다. 프로그램이 Mac을 강제로 깨우거나 전원 설정을 변경하지 않는다.

```bash
# 한 번 잠들었다가 목표 전에 복귀
bash /Users/crobat/dev/claude-session/scripts/verify-scheduler.sh before 180

# 두 번 이상 잠들었다가 목표 전에 복귀
bash /Users/crobat/dev/claude-session/scripts/verify-scheduler.sh multiple 300

# 목표 시각을 지나 잠든 상태를 유지하고, 목표 5초 이후 복귀
bash /Users/crobat/dev/claude-session/scripts/verify-scheduler.sh after 60
```

| 게이트 | 현재 상태 | 필요한 증거 |
|---|---|---|
| 강제 잠자기·반복 복귀·목표 이후 복귀 | 사용자 지시로 필수 게이트에서 제외 | 자연스럽게 발생할 때 관찰 사실 기록 |
| 새 설치본 실행 | 통과 | 0.1.4/빌드 6, PID 95584, 아래 launch 및 실행 파일 해시 |
| 오늘 실제 후속 예약 | 대기 | 15:59:59.541 KST 목표의 콜백·처리·결과 저장 |
| 내일 이후 첫 예약 및 후속 예약 | 대기 | 첫 예약 결과와 실제 리셋 목표의 후속 결과 저장 |

자동 테스트만으로 실운영 검증 완료를 선언하지 않는다. 실제 사용에서 자연스러운 잠자기가 관찰되지 않으면 잠자기 조건의 실측은 미관찰로 명시하며 별도의 강제 검증을 요구하지 않는다. 잠자기 기록이 없는 지연도 콜백·MainActor·서비스 로그로 조사한다. 설치형 검증에서는 `already_active`와 새 창을 연 `warmed`를 구별한다. 다음 예약 등록을 다음 실행 성공으로 보지 않는다.

매시간 5분에 같은 작업에서 실사용 로그를 확인하는 모니터를 등록했다(ID: `automation`). 새로운 결과나 실패가 없으면 알리지 않는다. 오늘 후속 예약과 내일 이후 첫·후속 예약의 검증 및 전체 완료 감사를 마치면 중지한다.

## 패키징·복구

- 후보: 0.1.4, 빌드 6
- 2026-09-14 11:21:29 KST에 0.1.4/빌드 6으로 설치본 교체 및 실행
- 기존 배포용 앱 백업: [ClaudeSessionWarmer-0.1.3.app](/Users/crobat/dev/claude-session/.build/scheduler-release-backup.nc2Ano/ClaudeSessionWarmer-0.1.3.app)
- 기존 0.1.3 DMG 보존: [ClaudeSessionWarmer-0.1.3.dmg](/Users/crobat/dev/claude-session/dist/ClaudeSessionWarmer-0.1.3.dmg)
- 당시 후보 보존본: [ClaudeSessionWarmer-0.1.4-build6.dmg](/Users/crobat/dev/claude-session/.build/scheduler-release-backup.nc2Ano/ClaudeSessionWarmer-0.1.4-build6.dmg)
- 앱·DMG 모두 Developer ID 서명 검증, 공증 `Accepted`, stapler validate, Gatekeeper `accepted` 통과
- Team ID: `V9SQZ6B7RP`, Bundle ID: `com.sharknia.ClaudeSessionWarmer` 유지
- 앱 공증 ID: `0915e195-6b9b-4830-b49b-c80ca17fc598`
- DMG 공증 ID: `e9643a81-c1f7-403d-9ce9-ff1caab411f9`
- DMG SHA-256: `25b6bd130216bf81ca3bcf3e83549c480d91c203caedcb3ed69ee62c42a75679`
- 앱 실행 파일 SHA-256: `90603b5ee6b813377704b1c91f354bede60b028bb69974899512d6d273456ec7`
- 읽기 전용으로 마운트한 DMG 안의 앱, dist 앱, 실제 설치 앱의 실행 파일 해시 일치 확인
- 설치 launch: `8346A533-B441-41A5-8216-BE18C3BE9274`, PID: `95584`
- 기존 처리 수 2와 다음 리셋 시각 보존. 15:59:59.541 KST 목표가 `clock=wall`로 등록됨
- 최초 새 예약 식별자: `E59266B9-0580-4B0F-B7FA-6CEF871ABDAB`
- 교체 전 실제 설치본은 [installed-0.1.3.app](/Users/crobat/dev/claude-session/.build/scheduler-release-backup.nc2Ano/installed-0.1.3.app)에 보존. 설정 및 교체 전 이벤트 로그도 같은 백업 디렉터리에 보존
- GitHub 릴리스 게시 및 main 병합은 수행하지 않음

검증 로그 위치는 프로그램 시작 시 출력한다. 기본 타이머 검증 사본은 [awake-70954.jsonl](/Users/crobat/dev/claude-session/.build/scheduler-verification/evidence/awake-70954.jsonl), 자동 테스트 결과는 [scheduler-tests.log](/Users/crobat/dev/claude-session/.build/scheduler-tests.log), 패키징 결과는 [scheduler-packaging.log](/Users/crobat/dev/claude-session/.build/scheduler-packaging.log)에 보존한다.

## 버전 표시 추가 당시 기록: 0.1.5 (현재 미사용)

- 사용자 요청: Claude Session Warmer 화면에 현재 버전 표시
- 코드 커밋: `698fccf`, release 빌드 통과 및 원격 푸시 완료
- 메뉴 하단 왼쪽에 Bundle의 실제 버전·빌드를 읽어 `v0.1.5 (빌드 7)` 형식으로 표시
- 새 설치본: 0.1.5 빌드 7, PID 20937, launch `08582A9B-38D5-44CA-9247-215E85FDAA29`
- 설치 실행 파일 SHA-256: `5f9dd43dd4318d74ab78aaaa517235ac84190f501328790cd2e5528c78838bce`
- 기존 0.1.4 설치본 백업: [installed-0.1.4.app](/Users/crobat/dev/claude-session/.build/scheduler-release-backup.nc2Ano/installed-0.1.4.app)
- 기존 Developer ID 서명 및 지정 요구사항 검증 통과. `claude-session-notary` 프로필이 현재 검색되지 않아 공증은 미완료
- 로컬 패키지: [ClaudeSessionWarmer-0.1.5-dev.dmg](/Users/crobat/dev/claude-session/dist/ClaudeSessionWarmer-0.1.5-dev.dmg), 공개 릴리스 아님
- 설치 버전과 프로세스는 확인했으나 화면 확인 도구가 앱 접근 시간 초과를 반환해 실제 화면의 시각적 확인은 미실시
- 실사용 로그 모니터는 이 새 설치본의 launch를 따라가도록 갱신

0.1.4는 외부 공개 전이었으므로 버전 표시 추가 시 패치 버전을 올리는 것은 필수가 아니었다. 이후 사용자가 이 브랜치의 버전을 0.1.4로 고정하도록 지시했으므로 0.1.5는 배포 버전으로 사용하지 않는다.

## 현재 설치본: 0.1.4 빌드 9

- 2026-09-14 12:26:10 KST 실행, PID 64588
- launch: `CBF7F666-8CD0-4AD3-873F-16342816B1B1`
- 코드: `5ae434c`, 전체 테스트 83개 통과
- 실행 파일 SHA-256: `d2c9a145f203f9bfeb2d1d46faa9054baca8d881c6e7b3a4b50683b73bc6398e`
- 로컬 DMG SHA-256: `449a62c39036bb27cc823effc9a60eb370c96caa4bcf1fe290e896d5ebf8c46a`
- 기존 처리 수 2와 오늘 15:59:59.541 KST 목표 보존
- 예약 식별자: `05B5363F-893B-4870-B4D6-D53954540AED`, 시간 기준 `wall`
- `update.check_availability`가 true로 바뀌어 업데이트 확인 가능한 상태 확인
- 업데이트 상세 검증과 공개 피드 연결은 08 문서에 기록
- 빌드 9는 Developer ID 서명 검증과 아래 별도 공증을 완료했다.

### 빌드 9 공증 및 실제 업데이트 확인

- 앱 공증 ID: `5d2ee0e5-f5c4-492e-b5dd-560a11fc3973`, 결과 `Accepted`
- DMG 공증 ID: `5d71b3d9-f881-4965-8ede-c09f6a7cba90`, 결과 `Accepted`
- [빌드 9 배포 후보 DMG](/Users/crobat/dev/claude-session/dist/ClaudeSessionWarmer-0.1.4.dmg) SHA-256: `89b35a22a48ad53aba05efd9289785c12b3189cd14e883e11dded7593289b464`
- 새 appcast.xml SHA-256: `728ea99bc75487e6b218bf9328b92f2f2d295c88a40ccddcc1032a644d889c5f`, 서명 검증 통과. 아직 공개 0.1.4 릴리스에 게시하지 않았다.
- 공증된 앱과 실행 중인 설치 앱의 CDHash는 모두 `51a5c3378efd5259b03522a12eb651dff3d3b5b8`로 일치했다. 재서명 시각 때문에 전체 실행 파일 SHA-256은 다르므로 같은 값이라고 취급하지 않는다.
- 설치 앱에 직접 공증 티켓을 부착한 후 `stapler validate`, `spctl --assess --type execute`, `codesign --verify --deep --strict` 통과. 앱 재시작 없이 PID 64588과 기존 예약 유지.
- 실제 설치 앱에서 12:55:45.850 업데이트 확인 요청, 12:55:46.608 최신 상태 응답 확인. 이후 Sparkle의 오류 코드 1001은 새 업데이트 없음에 따른 정상 종료이며 설치 실패가 아니다.
- 근거: [공증 패키징 로그](/Users/crobat/dev/claude-session/.build/updater-notarized-packaging.log), 해당 launch의 sequence 11~15. 예약 워밍 실행 성공과는 별개 증거다.
