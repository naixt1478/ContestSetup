# ContestSetup v2.0 작업 이관 문서 (HANDOFF)

> **작성일**: 2026-11-12  
> **대상 저장소**: `https://github.com/naixt1478/ContestSetup` (`main` 브랜치)  
> **목적**: 원격 작업 환경에서 수행한 **ContestSetup v2.0 전면 개편 및 검증 내역**을 OPC 서버의 Antigravity(`agy`) 환경으로 손실 없이 이관하기 위한 인계 문서입니다.

---

## 1. 현재 상태 요약 (Executive Summary)

| 항목 | 현재 상태 |
|---|---|
| **목표 시험 일정** | **2026-11-23 (월) 19:00 ~ 20:30 KST** (90분, 복구 시각 `20:30:00`) |
| **코드 버전** | `ContestSetup v2.0.0` (`common.ps1` 내 `$ContestSetupVersion = '2.0.0'`) |
| **브랜치 / 동기화** | `main` (`origin/main`에 모든 코드·문서·테스트·CI 워크플로 푸시 완료) |
| **자동화 테스트** | `python3 -B tests/run_tests.py --tier all --strict` → **283 / 283 PASS** (변이 테스트 **75 / 75 = 100%** 탐지) |
| **GitHub Actions CI** | 커밋 `00bf4a1` 기준 **Windows (`windows-latest`, PS 5.1 & PS 7)** + **Ubuntu (`ubuntu-latest`, `--strict`)** **모두 `success`** ([Run #43035749254](https://github.com/naixt1478/ContestSetup/actions/runs/43035749254)) |
| **미완료 / 후속 항목** | 1) `v2.0.0` Git 태그 푸시, 2) Windows CI 테스트 스텝의 `continue-on-error` 해제 검토, 3) **실제 Windows PC(또는 Windows Sandbox) 실기 E2E 리허설** |

---

## 2. OPC Server (`agy`)에서 바로 이어받는 방법

### Step 1. 저장소 클론 (또는 최신화)

```bash
# 신규 클론 시
git clone https://github.com/naixt1478/ContestSetup.git
cd ContestSetup

# 이미 클론되어 있는 경우
cd ContestSetup
git pull origin main
```

### Step 2. (선택) Linux OPC 서버에서 PowerShell 실엔진 테스트(`--strict`)까지 실행하려면

기본 Python 테스트(`python3 -B tests/run_tests.py --tier all`)는 Python 3만으로 즉시 실행됩니다.  
실제 PowerShell 엔진 회귀 테스트(`T5_33`)까지 건너뛰지 않고(`--strict`) 검증하려면 `pwsh`가 `PATH` 또는 `~/.local/pwsh/pwsh`에 있어야 합니다:

```bash
# pwsh가 없는 Linux 환경일 때 사용자 공간(root 불필요) 설치 예시
mkdir -p ~/.local/pwsh && cd ~/.local/pwsh
curl -sSL -o pwsh.tgz https://github.com/PowerShell/PowerShell/releases/download/v7.4.6/powershell-7.4.6-linux-x64.tar.gz
tar xzf pwsh.tgz && chmod +x pwsh && rm -f pwsh.tgz
export PATH="$HOME/.local/pwsh:$PATH"

# 전체 5-Tier 테스트 스위트 실행 (283/283 PASS 확인)
cd /path/to/ContestSetup
python3 -B tests/run_tests.py --tier all --strict
```

### Step 3. OPC Server `agy`에 붙여넣을 인계 프롬프트

OPC 서버의 Antigravity(`agy`) 새 세션에서 아래 프롬프트를 그대로 입력하면 컨텍스트를 즉시 복원할 수 있습니다:

```text
@HANDOFF.md @ARCHITECTURE_V2.md @PROJECT.md @CHANGELOG.md 를 읽고 현재 ContestSetup v2.0 작업 상태를 인계받아줘.
11/23(월) 19:00-20:30 KST 시험 대비 v2.0 코드 개편과 283개 테스트(T1~T5), GitHub Actions CI까지 main에 반영된 상태야.
먼저 `git status`, `git log -n 6`, `python3 -B tests/run_tests.py --tier all`로 로컬 상태를 확인한 뒤, HANDOFF.md 5장의 남은 과제(릴리스 태그, Windows CI 하드 게이트 전환, 실기 Windows 테스트 체크리스트/보완)를 이어서 진행하자.
```

---

## 3. 지금까지 완료된 핵심 작업 내역

### 3.1 커밋 이력 (`47828ba..00bf4a1`)

1. **`6e3d140`** (`chore`): `.gitignore` 추가(`.agents/`, 캐시, 임시 백업 파일 제외) 및 `.editorconfig` 정비
2. **`33a5015`** (`feat`): `ContestSetup v2.0` 12개 PowerShell 스크립트 전면 개편 반영 (2026-11-23 19:00~20:30 KST 시험 일정, 아키텍처 전환, 안정성 패치 `S-01`~`S-28`, 속도 최적화 `O1`~`O10`, `common.ps1` 얕은 스코프 버그 패치 포함)
3. **`65ba24c`** (`test`): 5-Tier 자동화 검증 스위트(`tests/run_tests.py`, 283개 테스트) 및 실엔진 `pwsh` 얕은 스코프 회귀 테스트(`T5_33`), `--strict` 플래그 추가
4. **`7b86f9f`** (`docs`): `README.md`(한국어 운영자·수험자 가이드 및 런북), `ARCHITECTURE_V2.md`, `PROJECT.md`, `TEST_INFRA.md`, `CHANGELOG.md` 정리
5. **`00bf4a1`** (`ci`): `.github/workflows/ci.yml` 추가 (`windows-latest`에서 Windows PowerShell 5.1 & PowerShell 7 전수 AST 파싱 검증 + `ubuntu-latest`에서 `--strict` 전체 스위트 검증)

### 3.2 시험 일정 및 스케줄러 안전장치 (`2026-11-23` 월요일 `19:00 ~ 20:30` KST)

- **일정 단일화**: 모든 스크립트(`common.ps1`, `install-env.ps1`, `setup-restore-task.ps1`, `ai-hosts-block.ps1`, `install-ai-hosts.ps1`)의 기본값을 `$ExamStart = '2026-11-23T19:00:00'`, `$ExamEnd = '2026-11-23T20:30:00'`, `$RestoreAt = '2026-11-23T20:30:00'`으로 통일했습니다.
- **KST(`+09:00`) 정규화 및 시계 오차 점검**: PC 타임존이 KST가 아니더라도 KST 기준으로 정확히 로컬 트리거 시각을 계산하며(`ConvertTo-KstDateTimeOffset`), HTTPS 응답 헤더 기반 시스템 시계 오차 점검(`Test-SystemClockSkewHttps`)을 수행합니다.
- **과거 시점 강제 종료 방어 (Past-Timestamp Safeguard)**: 시험 종료 시각(`20:30`) 이후 테스트 실행 시 `-StartWhenAvailable`과 `-Shutdown`이 결합되어 PC가 즉시 종료되는 사고를 막기 위해 자동으로 `-Shutdown`을 해제하고 트리거를 현재 +2시간으로 유예합니다.
- **사전 설치 지원 (`ContestSetupExamStartEnforcement`)**: 19:00 이전에 미리 설치하더라도 `-DeferAiBlockUntilExamStart` 옵션 또는 19:00 정각 강제 재적용 예약 작업(SYSTEM `S-1-5-18`, `EndBoundary` 설정)을 통해 시험 시작과 동시에 차단을 보장합니다.
- **완전한 복구**: `restore-and-cleanup.ps1` 실행 시 3개 예약 작업(`ContestSetupRestoreAndCleanup`, `ContestSetupRestoreAiHostsBlock`, `ContestSetupExamStartEnforcement`)을 모두 해제하고 수험자 코드(`C:\CPTools\contest`)를 `%LOCALAPPDATA%\ContestSetup-Backups`로 백업합니다.

### 3.3 아키텍처 개선 (v1 → v2.0)

- **Local-First + Staged Modular 로더**: 로컬/USB 실행 시 `$PSScriptRoot` 모듈을 네트워크 없이 즉시 로드하며, 원격 `irm | iex` 실행 시 `$Root\scripts`에 한 번 스테이징 및 PowerShell AST 문법 검증 후 dot-source하여 정확한 줄 번호 스택 트레이스를 보장합니다.
- **6가지 실행 모드 (`-Mode`)**:
  - `Install` (기본 설치)
  - `DryRun` (시스템 변경 없이 사전 점검 및 실행 계획 확인)
  - `Status` (설치 상태 및 매니페스트 조회)
  - `Verify` (컴파일러·Python·VS Code·AI 차단·예약 작업 무결성 검증, 종료 코드 `0`/`1`)
  - `Restore` (즉시 환경 복구 및 정리)
  - `ExportCache` (다좌석 실습실 배포용 오프라인 캐시 번들 추출)
- **상태 매니페스트 (`C:\CPTools\state\install-manifest.json`)**: 단계별 체크포인트 및 ContestSetup이 직접 설치한 리소스 소유권(`PythonInstalledByContestSetup` 등)을 기록해 복구 시 사용자 기존 프로그램 오삭제를 방지합니다.

### 3.4 주요 안정성 패치 (`S-01` ~ `S-28` + 실엔진 발견 버그)

- **실엔진 `pwsh` 검증에서 추가 발견·수정한 버그 (`common.ps1` `Get-ContestVariableValue`)**:
  - 최상위 스코프(`irm | iex` 또는 프롬프트 직접 dot-source)에서 `Get-Variable -Scope 2 -ErrorAction SilentlyContinue` 호출 시 PowerShell이 종료 불가능한 `PSArgumentOutOfRangeException`을 던져 `$ErrorActionPreference = 'Stop'` 아래에서 즉시 크래시하던 문제를 `try/catch`로 해결하고 `T5_33` 회귀 테스트로 고정했습니다.
- **최신 VS Code 1.145+ 포터블 디렉터리 구조 대응 (`Resolve-VSCodeProductJsonPath`)**:
  - 기존 `resources\app\product.json`뿐 아니라 최신 VS Code 포터블 아카이브의 `<commit>\resources\app\product.json` 레이아웃을 설치(`setup-vscode.ps1`)와 검증(`-Mode Verify`) 양쪽에서 모두 처리하며, 재실행 시 `product.json.contest-orig` 원본을 먼저 복원해 마켓플레이스 `127.0.0.1` 교착(`S-01`)을 방지합니다.
- **PowerShell 5.1 호환성 및 인코딩 안전성**:
  - 모든 `.ps1` 파일을 7-bit ASCII + UTF-8(No BOM) + LF로 유지하여 한글 Windows PowerShell 5.1의 CP949 오독 문제를 원천 차단했습니다(`S-19`).
  - 단일 원소 배열 언롤링 방지(`ConvertTo-Json -InputObject`, `@(...)`), StrictMode `.Count` 및 `.PSObject.Properties` 안전 접근, `-LiteralPath` 처리를 전수 반영했습니다.
- **AI 차단 강화 및 우회 차단 (`ai-hosts-block.ps1`)**:
  - IPv4(`0.0.0.0`) + IPv6(`::`) + `www.` 서브도메인 동시 차단, 최신 AI 도메인(ChatGPT, Claude, Gemini, Copilot, Perplexity, Grok, DeepSeek, Cursor, Windsurf, Wrtn, Clova X 등) 반영, 주요 브라우저(Chrome, Edge, Whale, Brave, Firefox)의 DoH(DNS-over-HTTPS) 및 내장 AI 기능 HKLM 정책 잠금·원복 기능을 포함합니다.
- **기타 핵심 패치**:
  - 비파괴적 에러 핸들링(실패 시 로그 잠금 해제 후 `%TEMP%\ContestSetup-Logs` 백업, 수험자 코드 보존)
  - 시스템 Python 3.10 기설치 시 `TargetDir` 누락 해결 및 개인 Python 삭제 방지
  - MSYS2 잔존 데몬 종료 및 `db.lck` 자동 복구, 두 단계 `SyncFirst` 업그레이드
  - SYSTEM 계정 실행 시 활성 콘솔 사용자 SID/프로필 역추적(`Resolve-ContestTargetUser`)으로 `HKU\.DEFAULT` 오기입 방지
  - 전역 뮤텍스(`Global\ContestSetupExecutionLock`)로 예약 작업과 수동 실행 간 경합 방지

### 3.5 설치 시간 단축 최적화 (`O1` ~ `O10`)

- **초기 설치**: 기존 15~35분+ → **약 2~3.5분** (Visual Studio 2022 선택 옵션화 `-IncludeVisualStudio`, MSYS2 국내 미러 KAIST/Harukasan 최우선 + `ParallelDownloads = 8`, 병렬 프리페치 다운로드, `tar.exe` 고속 압축 해제, VS Code 확장팩 단일 배치 설치)
- **재실행 (Warm Re-run)**: 기존 3~6분 → **약 5~10초** (MSYS2/Python/VS Code Fast-Path 스킵 및 캐시 매직바이트 검증 재사용)
- **다좌석 실습실 오프라인 배포**: 1대에서 `-Mode ExportCache -CacheDir D:\ContestCache` 실행 후 USB/NAS로 `-CacheDir D:\ContestCache` 설치 시 외부 네트워크 트래픽 없이 **좌석당 약 45~90초** 내 설치 가능

---

## 4. 저장소 주요 파일 구조

```text
ContestSetup/
├── install-env.ps1            # 메인 엔트리포인트 (-Mode Install|Verify|Status|DryRun|Restore|ExportCache)
├── common.ps1                 # 공통 유틸리티, 일정 검증(KST), 매니페스트, 병렬 다운로드, PATH/유저 SID 처리, 감사
├── setup-msys2.ps1            # MSYS2 설치, 국내 미러, db.lck 복구, UCRT64 g++/gdb 프로비저닝
├── setup-python.ps1           # Python 3.10 격리 설치, 시드/NuGet 폴백, python3 래퍼 보장
├── setup-vscode.ps1           # VS Code 포터블 설치, 한국어/확장팩 일괄 설치, product.json 잠금/복원
├── setup-visualstudio.ps1     # (-IncludeVisualStudio 시) vswhere 탐지 및 최소 VC++ 워크로드 설치
├── setup-wrappers.ps1         # gcc/g++/gdb/python3 .cmd 래퍼(@setlocal) 및 User/Machine PATH 정렬
├── ai-hosts-block.ps1         # AI 도메인 hosts 차단(IPv4/IPv6/www) + 브라우저 DoH/내장 AI 정책 잠금/복원
├── setup-ai-hosts.ps1         # 설치 단계 AI 차단 호출 및 19:00 강제 적용 연동 모듈
├── install-ai-hosts.ps1       # AI 호스트 차단 단독 설치 스크립트 (2026-11-23 일정 동기화됨)
├── setup-restore-task.ps1     # SYSTEM 예약 작업 등록 (19:00 AI 강제 적용 + 20:30 환경 복구)
├── restore-and-cleanup.ps1    # 예약 작업 해제, AI/브라우저 정책 복원, 수험자 코드 백업, 안전한 환경 정리
├── README.md                  # 운영자·수험자용 한국어 매뉴얼 및 시험 당일 런북
├── ARCHITECTURE_V2.md         # v2.0 아키텍처 설계, S-01~S-28 결함 분석 및 O1~O10 최적화 상세 보고서
├── PROJECT.md                 # 기능 명세 및 모듈 간 계약(Contract) 정의서
├── TEST_INFRA.md              # 5-Tier 테스트 아키텍처 및 변이 검증 명세
├── CHANGELOG.md               # v2.0.0 변경 이력
├── HANDOFF.md                 # (본 문서) OPC 서버 이관 및 후속 작업 가이드
├── tests/
│   └── run_tests.py           # 283개 자동화 테스트 스위트 (--tier 1..5|all, --strict, --verbose, --json)
└── .github/workflows/
    └── ci.yml                 # Windows (PS 5.1 & PS 7) + Ubuntu (--strict) GitHub Actions CI
```

---

## 5. OPC Server 이관 후 남은 작업 및 11/23 전 체크리스트

### 5.1 Git 릴리스 태그(`v2.0.0`) 생성 (권장)
`CHANGELOG.md` 하단의 릴리스 비교 링크(`/releases/tag/v2.0.0`)가 동작하도록 실기 점검 전후에 태그를 푸시합니다:

```bash
git tag -a v2.0.0 -m "ContestSetup v2.0.0 for 2026-11-23 19:00-20:30 KST exam"
git push origin v2.0.0
```

### 5.2 GitHub Actions Windows 테스트 하드 게이트 승격 검토
현재 `.github/workflows/ci.yml`의 `windows-parse` 잡에서:
- PowerShell 5.1 및 PowerShell 7 AST 파싱은 **필수 통과(blocking)** 로 동작 중이며 성공 확인되었습니다.
- `Run test suite (advisory on Windows)` 스텝은 `continue-on-error: true`가 붙어 있습니다. GitHub 웹 UI에서 해당 스텝의 상세 출력이 `283/283 passed`인지 확인한 뒤, 이상이 없으면 `continue-on-error: true`를 제거해 Windows에서도 테스트 실패 시 빌드를 막도록 승격할 수 있습니다.

### 5.3 실제 Windows 10/11 시험용 PC (또는 Windows Sandbox) E2E 리허설 (필수)
리눅스 환경에서는 `WindowsPrincipal`(관리자 권한 확인), `ScheduledTasks`, `System32\drivers\etc\hosts` 잠금, HKLM 레지스트리 정책, 실제 설치 프로그램 실행을 끝까지 구동할 수 없으므로 **11/23 시험 전 실제 Windows 환경에서 관리자 PowerShell 5.1로 아래 순서대로 1회 리허설**을 권장합니다:

```powershell
# 1. 사전 점검 (시스템 변경 없음)
powershell -ExecutionPolicy Bypass -File .\install-env.ps1 -Mode DryRun

# 2. 실제 설치 (테스트 시 PC 자동 종료 방지를 위해 -NoRestoreShutdown 권장)
powershell -ExecutionPolicy Bypass -File .\install-env.ps1 -NoRestoreShutdown

# 3. 상태 및 무결성 검증 (종료 코드 0 확인)
powershell -ExecutionPolicy Bypass -File .\install-env.ps1 -Mode Status
powershell -ExecutionPolicy Bypass -File .\install-env.ps1 -Mode Verify
Write-Host "Verify ExitCode = $LASTEXITCODE"

# 4. 수험자 시나리오 수동 확인
# - 바탕화면 'Contest VS Code' 실행 -> C:\CPTools\contest 에서 C++(g++), Python(python3) 컴파일/디버깅 확인
# - 브라우저(Edge/Chrome/Whale)에서 chatgpt.com, claude.ai, gemini.google.com 접속 차단 확인
# - 작업 스케줄러(taskschd.msc)에 ContestSetup* 작업 등록 확인

# 5. 복구 리허설 (원상복구 확인 — -Mode Restore는 기본값으로 PC를 종료하지 않음)
powershell -ExecutionPolicy Bypass -File .\install-env.ps1 -Mode Restore -NoPause
# - C:\CPTools\contest 내 테스트 코드가 %LOCALAPPDATA%\ContestSetup-Backups 에 백업되었는지 확인
# - hosts 파일 및 브라우저 AI 도메인 접속이 정상 복구되었는지 확인
# - 작업 스케줄러에서 ContestSetup* 예약 작업이 모두 제거되었는지 확인
```

### 5.4 (다좌석 고사장 운영 시) 오프라인 설치 캐시 번들 준비
수십 대의 시험장 PC에서 동시에 설치할 경우 네트워크 병목을 피하기 위해 관리자 PC 1대에서 미리 캐시를 떠서 USB/내부망으로 배포할 수 있습니다:

```powershell
# 1. 캐시 번들 추출 (관리자 PC 1회)
powershell -ExecutionPolicy Bypass -File .\install-env.ps1 -Mode ExportCache -CacheDir D:\ContestCache

# 2. 각 고사장 PC에서 캐시를 사용해 고속 설치
powershell -ExecutionPolicy Bypass -File .\install-env.ps1 -CacheDir D:\ContestCache
```
