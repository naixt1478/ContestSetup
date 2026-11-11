# ContestSetup v2.0

이 리포지토리는 Windows 10/11(Windows PowerShell 5.1 및 PowerShell 7+) 환경에서 안전하고 신뢰할 수 있는 **대회용 프로그래밍 환경(Contest Environment v2.0)**을 빠르게 구축하고, 시험 종료 시각에 맞춰 자동으로 원래 환경으로 복구해 주는 스크립트 모음을 제공합니다.

- **대상 시험 일정**: **2026년 11월 23일(월) 19:00 ~ 20:30** (`2026-11-23T19:00:00` ~ `2026-11-23T20:30:00` KST)
- **자동 복구 스케줄러 작동 시각**: **2026년 11월 23일(월) 20시 30분** (`2026-11-23T20:30:00` KST)
- 아키텍처 개선, 안정성 하드닝(`S-01`~`S-28`) 및 설치 시간 최적화(`O1`~`O10`) 상세 분석은 [`ARCHITECTURE_V2.md`](./ARCHITECTURE_V2.md)를 참고하세요.

---

## ⚠️ 시험 종료(2026-11-23 월요일 20:30) 자동 초기화 및 소스코드 백업 안내

> **반드시 시험 종료 시각(20:30) 이전에 모든 답안 코드를 온라인 저지(OJ)에 제출하고, 개인 보관이 필요한 코드는 별도 폴더(바탕화면·문서·USB 등 `C:\CPTools` 외부)에 미리 저장하세요!**

1. **20:30 정각 자동 복구 및 폴더 정리**:
   - **2026년 11월 23일(월) 20시 30분(KST)**이 되면 Windows 작업 스케줄러(`ContestSetupRestoreAndCleanup`, `SYSTEM` 권한)가 자동 실행되어 AI 도메인 및 브라우저 DoH 차단을 해제하고, 단축아이콘과 `PATH` 환경변수를 시험 전 상태로 되돌린 뒤 **`C:\CPTools` 폴더(`C:\CPTools\contest` 포함)를 삭제하고 PC를 자동 종료(30초 카운트다운)**합니다.
2. **학생 답안 소스코드 자동 안전 백업**:
   - 실수로 미처 옮기지 못한 코드가 영구 유실되는 사고를 방지하기 위해, 자동 복구 스크립트는 `C:\CPTools` 삭제 직전에 `C:\CPTools\contest` 내 답안 소스 파일(`.cpp`, `.cc`, `.cxx`, `.c`, `.h`, `.hpp`, `.py`, `.java`, `.txt`, `.md`, 파일당 5MB 이하)을 학생 프로필의 영구 보관 폴더 **`%LOCALAPPDATA%\ContestSetup-Backups\ContestSetup-Workspace-Backup-<타임스탬프>`** (학생 프로필 미식별 `SYSTEM` 환경에서는 `%ProgramData%\ContestSetup-Backups` / `%TEMP%\ContestSetup-Workspace-Backup-<타임스탬프>`)에 자동 백업합니다 (`-PurgeWorkspace` 지정 시 제외).
3. **기존 개인 환경 보존 및 다음 날 부팅 안전장치**:
   - MSYS2(`C:\msys64`, 설정 파일 원복 포함), 기존 개인용 Python, 개인용 VS Code(`%APPDATA%\Code`, `%USERPROFILE%\.vscode`)는 **절대 삭제되지 않습니다**.
   - 시험 종료 전에 노트북 전원을 껐다가 다음 날(`11/24` 등, 예정 복구 시각으로부터 **25분 초과 경과 후**) 부팅하더라도, 자동 복구만 조용히 완료되고 **수업 중 강제 종료(`-Shutdown`)는 자동으로 비활성화**됩니다.

---

## ✨ 주요 기능 요약 (v2.0)

- **이중 격리형 포터블 VS Code 및 확장 화이트리스트**: 기존 VS Code 설정을 건드리지 않는 완전 격리형(`C:\CPTools\vscode\data` 포터블 모드 + `C:\CPTools\vscode-contest`) 구성, 한국어 UI(`--locale ko`) 강제 적용, 필수 4종 확장 외 비인가 확장 자동 차단, 마켓플레이스 로컬 잠금(`127.0.0.1`) 및 C++ IntelliSense/디버깅 설정 자동 생성
- **고속 MSYS2 (UCRT64 GCC/GDB) 및 충돌 방지 Python 3.10 설치**:
  - 국내 고속 미러(`ftp.kaist.ac.kr`, `mirror.harukasan.org`) 우선 적용, `ParallelDownloads = 8`, 2단계 런타임 업그레이드(`SyncFirst`) 및 PGP 키링 자동 복구
  - 기존 시스템 Python 3.10과 충돌하지 않는 격리형 `C:\CPTools\Python310`(`python.exe`, `python3.exe`, 표준 라이브러리 검증 포함) 구성
- **3단계 초고속 압축 해제 및 무대역폭 실습실 캐시(`-Mode ExportCache`)**: `System32\tar.exe` → `.NET ZipFile` → 무소음 `Expand-Archive` 3단계 추출과 확장/패키지 완전 오프라인 시드를 통해 50~200대 실습실에서도 외부 인터넷 트래픽 0 MB로 1분 이내 설치 완료
- **강화된 AI 부정행위 차단 (IPv4 + IPv6 + `www.` + 브라우저 DoH/내장 AI 정책 잠금)**:
  - ChatGPT(`chatgpt.com`/`chat.com`), Claude(`claude.ai`/`claude.com`), Gemini, AI Studio, Grok(`grok.com`/`x.ai`), Copilot(`m365copilot.com`/`copilot.cloud.microsoft`), Cursor(`api2.cursor.sh`), Windsurf, DeepSeek, Qwen, Kimi, Perplexity, Genspark(`genspark.ai`), Manus(`manus.im`) 및 국내 AI(뤼튼 `wrtn.ai`, 네이버 CLOVA X/Cue, 라이너 `liner.com`, 앨런 등) 135개 이상 도메인을 IPv4(`0.0.0.0`)·IPv6(`::`) 동시 차단
  - Chrome, Edge, Naver Whale, Brave, Firefox의 **DNS-over-HTTPS(DoH)**(`DnsOverHttpsMode`, `DnsOverHttpsTemplates`, 내장 DNS) 및 브라우저 내장 AI(`BuiltInAIAPIsEnabled`, `BraveAIChatEnabled`, Edge/Windows Copilot 사이드바) 우회를 HKLM 정책(22개 항목)으로 일시 잠금 (복구 시 `browser-policies.bak.json` 기반 완벽 원복)
- **SID 인식 `SYSTEM` 스케줄러 자동 복구**: 학생이 조기 퇴실(로그오프)하거나 조교가 별도 관리자 계정(UAC)으로 설치한 실습실에서도 `S-1-5-18`(`SYSTEM`) 서비스 작업과 학생 `SID` 레지스트리 추적으로 `User`/`Machine` PATH(`REG_EXPAND_SZ` 보존) 및 모든 설정을 정확히 복원

---

## 🚀 설치 및 사용 방법

**권장**: **관리자 권한**으로 Windows PowerShell 또는 터미널을 실행하세요(일반 권한에서 실행해도 학생 계정 SID를 보존한 채 자동으로 관리자 권한 승격을 요청합니다).

1. `시작` 버튼을 우클릭하거나 `Win + X` 키를 누릅니다.
2. **Windows PowerShell (관리자)** 또는 **터미널 (관리자)**를 선택합니다.
3. 아래 명령어를 복사하여 붙여넣고 엔터를 누릅니다.

```powershell
irm https://raw.githubusercontent.com/naixt1478/ContestSetup/main/install-env.ps1 | iex
```

### 로컬 클론 및 50~200대 실습실 USB/LAN 대량 배포 (`-Mode ExportCache` & `-CacheDir`)

캠퍼스 공유 네트워크에서 50~200대 PC를 동시에 설치할 때 외부 다운로드 병목과 VS Code 마켓플레이스 `HTTP 429` 속도 제한을 완전히 제거하려면 아래 절차를 사용하세요:

```powershell
# [1단계: 사전 준비 - 마스터 PC 1대에서 실행]
# 먼저 마스터 PC에 대회 환경을 1회 설치한 뒤, USB 또는 네트워크 공유 폴더로 전체 캐시를 내보냅니다.
.\install-env.ps1 -NoPause
.\install-env.ps1 -Mode ExportCache -CacheDir "D:\ContestCache" -NoPause

# [2단계: 실습실 좌석 배포 - 각 실습실 PC에서 실행]
# 설치 파일 + VS Code 확장 + MSYS2 패키지를 모두 로컬 캐시에서 즉시 복사하여 약 35~55초 내에 무인 설치합니다.
D:\ContestCache\scripts\install-env.ps1 -CacheDir "D:\ContestCache" -NoPause -NoRestoreShutdown

# [사전 설치 옵션] 시험 전날(11/22 등) 미리 설치하되, AI 사이트 차단은 시험 시작(11/23 19:00)부터 적용하려는 경우
.\install-env.ps1 -CacheDir "D:\ContestCache" -DeferAiBlockUntilExamStart -NoPause

# [상태 및 무결성 점검] 시스템이나 hosts 파일을 건드리지 않는 비파괴 점검 (Verify 실패 시 종료코드 1 반환)
.\install-env.ps1 -Mode Status
.\install-env.ps1 -Mode Verify -NoPause
.\install-env.ps1 -Mode DryRun

# [선택 사항] Visual Studio 2022 Community C++ 워크로드까지 함께 설치하려는 경우
.\install-env.ps1 -IncludeVisualStudio
```

---

## ⚙️ 전체 CLI 옵션 및 `CONTEST_*` 환경 변수 레퍼런스

### 1. `install-env.ps1` 전체 파라미터 (21개)

CLI 인자를 생략한 경우 대응하는 `CONTEST_*` 환경 변수가 자동으로 적용됩니다.

| CLI 파라미터 | 환경 변수 | 기본값 | 설명 |
|---|---|---|---|
| `-Mode` | `CONTEST_MODE` | `Install` | 실행 모드 (`Install`, `Status`, `Verify`, `DryRun`, `Restore`, `ExportCache`) |
| `-ExamStart` | `CONTEST_EXAM_START` | `2026-11-23T19:00:00` | 시험 시작 시각 (오프셋 생략 시 KST `+09:00` 기준 해석) |
| `-ExamEnd` | `CONTEST_EXAM_END` | `2026-11-23T20:30:00` | 시험 종료 시각 (`19:00` 강제 작업 만료 경계로도 사용) |
| `-RestoreAt` | `CONTEST_RESTORE_AT` | `2026-11-23T20:30:00` | 자동 복구 스케줄러 작동 시각 |
| `-Root` | `CONTEST_ROOT` | `C:\CPTools` | 대회 전용 도구·VS Code·워크스페이스 루트 경로 |
| `-MsysRoot` | `CONTEST_MSYS_ROOT` | `C:\msys64` | MSYS2 설치 루트 경로 (복구 시에도 삭제되지 않고 보존됨) |
| `-CacheDir` | `CONTEST_CACHE_DIR` | `''` | 오프라인/USB/LAN 캐시 디렉터리 경로 (`ExportCache` 출력 또는 `Install` 입력) |
| `-Msys2CaCertificatePath` | `CONTEST_MSYS2_CA_PATH` | `''` | 학내망/방화벽 HTTPS 프록시 루트 CA 인증서(`.crt`/`.pem`) 경로 |
| `-PythonVersion` | `CONTEST_PYTHON_VERSION` | `3.10.11` | 설치할 대회용 Python 버전 |
| `-TargetUserSid` | `CONTEST_TARGET_USER_SID` | `''` | `SYSTEM`/관리자 배포 시 대상 학생 계정의 Windows SID (미지정 시 자동 감지) |
| `-TargetUserProfile` | `CONTEST_TARGET_USER_PROFILE` | `''` | 대상 학생 계정의 프로필 경로 (예: `C:\Users\Student`, 미지정 시 자동 감지) |
| `-IncludeVisualStudio` | `CONTEST_INCLUDE_VS` | `$false` | Visual Studio 2022 C++ 워크로드 추가 설치 여부 (기본 스킵) |
| `-ForceUpdate` | `CONTEST_FORCE_UPDATE` | `$false` | 이미 설치된 MSYS2 패키지 및 VS Code 확장 강제 재설치 |
| `-NoRestoreTask` | `CONTEST_NO_RESTORE_TASK` | `$false` | `20:30` 자동 복구 작업(`ContestSetupRestoreAndCleanup`) 등록 생략 (종료 후 수동 `-Mode Restore` 필수; `-DeferAiBlockUntilExamStart` 병행 시 `19:00` 차단 작업은 유지) |
| `-NoRestoreShutdown` | `CONTEST_NO_RESTORE_SHUTDOWN` | `$false` | 자동 복구 완료 후 PC 자동 종료(`-Shutdown`) 생략 |
| `-RollbackOnFailure` | `CONTEST_ROLLBACK_ON_FAILURE` | `$false` | 설치 중 오류 발생 시 즉시 부분 설치 내역 롤백 (`contest`/`downloads`/`logs`는 보존) |
| `-UseRemote` | `CONTEST_USE_REMOTE` | `$false` | 로컬 스크립트 대신 GitHub 원격 최신 스크립트를 강제로 스테이징하여 실행 |
| `-KeepVSCode` | `CONTEST_KEEP_VSCODE` | `$false` | `-Mode Restore` 실행 시 격리된 대회용 VS Code(`vscode`, `vscode-contest`) 보존 및 `product.json` 마켓플레이스 잠금 해제 |
| `-NoPause` | `CONTEST_NO_PAUSE` | `$false` | 완료/오류 GUI 메시지 박스 및 콘솔 대기 생략 (실습실 무인 배포·자동화 필수) |
| `-SkipSignatureCheck` | `CONTEST_SKIP_SIGNATURE_CHECK` | `$false` | 설치 파일 Authenticode 디지털 서명 검증 생략 (헤더·최소 크기 검증은 유지) |
| `-DeferAiBlockUntilExamStart` | `CONTEST_DEFER_AI_BLOCK` | `$false` | 시험 시작 전 사전 설치 시 즉시 `hosts` 차단을 유예하고 `19:00` 예약 작업(`ContestSetupExamStartEnforcement`, 등록 실패 시 설치 중단)으로 차단 시작 |

### 2. `restore-and-cleanup.ps1` 주요 옵션

| CLI 파라미터 | 환경 변수 | 설명 |
|---|---|---|
| `-Root` / `-MsysRoot` | `CONTEST_ROOT` / `CONTEST_MSYS_ROOT` | 복구 대상 대회 루트 및 설정 원복 대상 MSYS2 경로 |
| `-KeepWorkspace` | - | `C:\CPTools\contest` 학생 답안 폴더를 삭제하지 않고 그대로 보존 |
| `-PurgeWorkspace` | - | 학생 소스코드 자동 안전 백업을 생략하고 실습실 공용 PC에서 즉시 완전 삭제 |
| `-KeepVSCode` | `CONTEST_KEEP_VSCODE` | 격리된 VS Code 및 단축아이콘 구성을 유지하되 `product.json` 마켓플레이스 잠금은 원복 |
| `-KeepDownloads` / `-KeepLogs` | - | `downloads` 설치 캐시 또는 `logs` 로그 폴더 보존 |
| `-Shutdown` | - | 복구 및 폴더 삭제가 완전히 끝난 뒤 PC 종료 (`-ScheduledRestoreAt` 대비 25분 초과 지연 시 자동 해제) |

---

## 📋 감독관/조교 시험 당일 운영 체크리스트 (2026-11-23 월요일 18:30 ~ 20:30)

### 1) `18:30 ~ 18:45` — 실습실 좌석 배포 및 시계 확인
- 마스터 USB 또는 학내 공유 폴더(`-CacheDir`)를 이용해 미설치 좌석에 무인 설치를 실행합니다:
  ```powershell
  .\install-env.ps1 -CacheDir "D:\ContestCache" -NoPause
  ```
- 모든 시험용 PC의 Windows 날짜/시간이 **2026-11-23(월) KST(UTC+09:00)** 기준 정확한지 확인합니다(사전 점검 단계에서 5분 이상 시계 오차 시 자동 경고가 출력됩니다).

### 2) `18:50 ~ 18:58` — 시험 직전 전 좌석 무결성 검증 (`-Mode Verify`)
- 응시자 입실 후 열려 있던 웹 브라우저(Chrome/Edge/Whale 등)를 **모두 완전히 종료 후 재실행**하도록 안내하여 DoH 비활성화 정책과 DNS 캐시 플러시가 즉시 반영되게 합니다.
- 검증 명령으로 컴파일러(`g++`, `python3`), VS Code 한국어·확장·마켓플레이스 잠금, AI `hosts` 차단, `20:30` 자동 복구 스케줄러를 비파괴 점검합니다:
  ```powershell
  .\install-env.ps1 -Mode Verify -NoPause
  ```
- 바탕화면의 **`Visual Studio Code` 단축아이콘** 또는 터미널의 `code` 명령으로 `C:\CPTools\contest` 워크스페이스가 한국어 UI로 정상 열리는지 확인합니다.

### 3) `19:00 ~ 20:30` — 본 시험 진행 및 비상시 종료 시각 연장 방법
- `19:00` 정각에 사전 설치 좌석의 `ContestSetupExamStartEnforcement` 작업이 자동 실행되어 AI 차단과 브라우저 DoH 잠금을 재확인합니다.
- **(비상 상황 대응)** 온라인 저지(OJ) 장애 등으로 시험 종료 시각을 예: `20:50`으로 **20분 연장**해야 하는 경우, 관리자 PowerShell에서 아래 명령으로 전체 재설치 없이 복구 스케줄러 시각만 즉시 갱신할 수 있습니다:
  ```powershell
  $env:CONTEST_RESTORE_AT = '2026-11-23T20:50:00'
  .\setup-restore-task.ps1
  ```

### 4) `20:25 ~ 20:30` — 종료 5분 전 공지 및 자동 초기화 확인
- **20:25 공지**: *"20시 30분 정각에 자동 환경 복구 및 PC 종료가 시작되므로 모든 코드를 제출하고 개인 보관용 코드는 바탕화면/USB로 백업하세요."*
- **20:30 정각**: `ContestSetupRestoreAndCleanup` 작업이 실행되어 학생 코드를 `%LOCALAPPDATA%\ContestSetup-Backups\ContestSetup-Workspace-Backup-*`에 안전 백업한 뒤, AI 차단 해제·환경 복원·`C:\CPTools` 삭제 후 PC를 종료합니다.
- 만약 종료 카운트다운 중 긴급히 종료를 취소해야 하는 좌석이 있다면 명령 프롬프트/실행(`Win+R`)에서 `shutdown /a`를 입력하면 PC 종료만 즉시 취소됩니다.

---

## ♻️ 수동 복구 (선택 사항)

자동 복구 스케줄러(**2026년 11월 23일 20:30 작동**)를 기다리지 않고 **즉시** 대회 환경을 제거하고 원래 상태로 되돌리려면 아래 명령어를 관리자 권한으로 실행하세요.

```powershell
irm https://raw.githubusercontent.com/naixt1478/ContestSetup/main/restore-and-cleanup.ps1 | iex
```

또는 로컬에서 다음 명령어를 실행할 수 있습니다:

```powershell
.\install-env.ps1 -Mode Restore
# 또는 답안 폴더(C:\CPTools\contest)를 그대로 유지한 채 환경만 복구하려면:
.\restore-and-cleanup.ps1 -KeepWorkspace
```

이 명령어는 등록된 대회 스케줄러 작업(`ContestSetupRestoreAndCleanup`, `ContestSetupRestoreAiHostsBlock`, `ContestSetupExamStartEnforcement`)을 모두 해제하고, 대회용 Python, 격리된 VS Code, AI 호스트 및 브라우저 DoH 차단 정책, 단축아이콘, MSYS2 미러/설정 백업(`.contest-bak`) 및 환경 변수(`PATH`)를 설치 이전 상태로 안전하게 되돌립니다. MSYS2(`C:\msys64`)와 사용자의 기존 개인 개발 환경은 그대로 보존됩니다.

---

## 🧪 개발자용: 테스트 및 CI

저장소에는 스크립트 수정 시 회귀를 잡기 위한 Python 기반 5-Tier 검증 스위트(`tests/run_tests.py`, 283개 테스트)가 포함되어 있습니다. 세부 구성은 `TEST_INFRA.md`, 설계 배경은 `ARCHITECTURE_V2.md`, 변경 이력은 `CHANGELOG.md`를 참고하세요.

```bash
# 저장소 루트에서 전체 실행 (Python 3.8+, __pycache__ 미생성)
python3 -B tests/run_tests.py --tier all

# 특정 Tier만 실행 (1~5), 개별 결과 출력
python3 -B tests/run_tests.py --tier 5 --verbose

# CI 모드: pwsh가 없어 실엔진 회귀 테스트(T5_33)를 건너뛰면 실패로 처리
python3 -B tests/run_tests.py --tier all --strict
```

- 대부분의 테스트는 `.ps1` 소스의 정적 구조·계약 검사와 Python 동작 모델로 수행되며 Windows가 필요하지 않습니다.
- `T5_33`은 PowerShell 7(`pwsh`)로 `common.ps1`을 최상위 `irm | iex` 방식으로 실제 로드하여 `Get-ContestVariableValue`의 얕은 스코프 회귀를 검증합니다. `pwsh`는 `CONTEST_PWSH` 환경 변수 → `PATH` → `~/.local/pwsh/pwsh` 순서로 탐색하며, 찾지 못하면 `SKIP`으로 표시됩니다.
- GitHub Actions(`.github/workflows/ci.yml`)는 `windows-latest`에서 모든 `.ps1`을 Windows PowerShell 5.1과 PowerShell 7 파서로 구문 검사하고, Ubuntu(`pwsh` 포함)에서 전체 테스트를 `--strict`로 실행합니다 (Windows 테스트 실행은 참고용).
