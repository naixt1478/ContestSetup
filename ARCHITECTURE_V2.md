# ContestSetup v2.0 — 아키텍처 재설계, 심층 안정성 강화(`S-01`~`S-28`) 및 대규모 실습실 최적화(`O1`~`O10`) 기술 보고서

본 문서는 **2026년 11월 23일(월) 19:00 ~ 20:30 (KST)** 시험 일정에 맞추어 기존 `ContestSetup` v1.x 스크립트의 구조적 불안정성과 Windows PowerShell 5.1 실환경·실습실(50~200대 PC) 운영 엣지 케이스, AI 부정행위 우회 경로를 전수 진단하고, **하이브리드 로컬 우선 스테이징 아키텍처(Hybrid Local-First Staged Modular Architecture)** 및 **무대역폭(Zero-Bandwidth) 실습실 배포·속도 최적화**를 종합 구현한 **ContestSetup v2.0** 엔지니어링 분석 보고서입니다.

---

## 1. 시험 일정 반영 및 스케줄러 안전성 설계 (2026-11-23 월요일 19:00 ~ 20:30 KST)

### 1.1 기존 v1.x의 일정 및 운영상 문제점
1. **하드코딩된 과거 시험 일시**:
   - `setup-restore-task.ps1`에 `2026-05-09T17:10:00`이 하드코딩되어 있었으며, `README.md`에는 `2026년 5월 9일 17시 10분`, `ai-hosts-block.ps1` 및 `install-ai-hosts.ps1` 주석에는 `2026-05-04 18:00`이 남아 있었습니다.
2. **과거 시각 등록 및 다음 날 부팅 시 강제 종료(Shutdown) 위험**:
   - `New-ScheduledTaskSettingsSet -StartWhenAvailable`과 `-Shutdown`(`Stop-Computer -Force`)이 결합되어 있어, 시험 종료 후 테스트 실행 시 또는 노트북이 꺼진 상태로 밤을 지낸 뒤 다음 날(`11/24`) 수업 중 부팅될 때 PC가 예고 없이 강제 종료될 위험이 있었습니다.
3. **수동 복구 후 스케줄러 미해제 (`S-07`) 및 다중 계정(`SYSTEM` / UAC) 미작동**:
   - 수동 복구 후에도 예약 작업이 남아 20:30에 PC가 종료되거나, 반대로 조교가 관리자 계정(UAC)으로 승격 설치한 실습실 PC나 시험을 일찍 마치고 로그오프한 자리에서는 `Interactive` 작업이 아예 실행되지 않는 치명적 한계가 있었습니다.

### 1.2 ContestSetup v2.0 일정 및 KST 정규화 아키텍처
1. **중앙화된 시험 일정 기본값 및 KST(`+09:00`) 타임존 정규화 (`common.ps1`, `install-env.ps1`, `setup-restore-task.ps1`)**:
   - **시험 시작 시각 (`$ExamStart`)**: `'2026-11-23T19:00:00'` (2026년 11월 23일 월요일 19시 00분 KST)
   - **시험 종료 시각 (`$ExamEnd`)**: `'2026-11-23T20:30:00'` (2026년 11월 23일 월요일 20시 30분 KST, 90분 시험)
   - **자동 복구 시각 (`$RestoreAt`)**: `'2026-11-23T20:30:00'` (`-RestoreAt` 또는 환경변수 `CONTEST_RESTORE_AT`으로 실시간 조정 가능)
   - **오프셋 없는 일정 문자열의 `+09:00` 정규화 (`S-25`)**: 타임존 오프셋이 생략된 ISO 문자열을 한국 표준시(`+09:00`) 기준 `DateTimeOffset`으로 파싱한 뒤 로컬 시각(`.LocalDateTime`)으로 변환하므로, 해외 타임존으로 잘못 설정된 학생 노트북도 정확히 동일한 절대 시각(`2026-11-23T11:30:00Z`)에 작동합니다. 또한 사전 점검 단계에서 HTTPS 응답 `Date` 헤더와 로컬 시계의 오차(5분 초과 시 경고)를 검증합니다.
2. **`NT AUTHORITY\SYSTEM` (`S-1-5-18`) 주체 등록 및 절전 해제(`-WakeToRun`) (`S-23`)**:
   - 모든 대회 예약 작업(`ContestSetupRestoreAndCleanup`, `ContestSetupExamStartEnforcement`, `ContestSetupRestoreAiHostsBlock`)을 `S-1-5-18` (`ServiceAccount`, `-RunLevel Highest`, `-WakeToRun`, 배터리 허용, 최대 1시간 제한)로 등록하여 학생이 조기 퇴실(로그오프)하거나 별도 관리자 계정으로 설치된 실습실에서도 100% 작동합니다.
3. **이중 `-StartWhenAvailable` 레이스 차단 및 지연 부팅 자동 종료 억제 (`S-24`)**:
   - `19:00` 시작 강제 작업(`ContestSetupExamStartEnforcement`)에 트리거 만료 경계(`EndBoundary = ExamEnd`)와 `-NotAfter` 인자를 부여하고 `Global\ContestSetupEnvironmentMutex`로 직렬화하여, 시험 종료 후 부팅된 PC에서 `hosts` 차단이 되살아나는 레이스를 원천 차단합니다.
   - `restore-and-cleanup.ps1` 실행 시 예정된 복구 시각(`-ScheduledRestoreAt`)으로부터 **25분 이상 경과**한 지연 실행(예: 다음 날 오전 노트북 부팅)이면 `-Shutdown`을 자동으로 비활성화하여 조용히 환경만 복구하고 수업 중 강제 종료를 방지합니다.
4. **학생 답안 소스코드 자동 안전 백업 및 삭제 완료 후 종료 보장 (`S-24`, `S-25`)**:
   - `C:\CPTools` 삭제 직전 `C:\CPTools\contest` 내 학생 답안 파일(`.cpp`, `.c`, `.py`, `.java`, `.txt` 등 5MB 이하)을 학생 계정의 영구 보관 경로 `%LOCALAPPDATA%\ContestSetup-Backups\ContestSetup-Workspace-Backup-<타임스탬프>` (`SYSTEM` 작업 시 `TargetUserProfile\AppData\Local\ContestSetup-Backups`, 폴백 `%ProgramData%\ContestSetup-Backups` / `%TEMP%`)에 자동 백업합니다.
   - 실행 중인 복구 스크립트가 `C:\CPTools` 내부에 위치하면 `%TEMP%\contest-restore-runner.ps1`로 자기 복제(Self-Relocation)하여 파일 핸들 잠금을 원천 제거하고, 지연 배치가 필요한 경우 `ping` 대기 및 `rmdir /s /q` 완료 **이후**에만 `shutdown.exe`가 호출되도록 순서를 엄격히 보장합니다 (`-KeepVSCode` 지정 시에는 실행 중인 VS Code를 유지하되 `product.json` 마켓플레이스 잠금은 원복합니다).

---

## 2. 기존 v1.x 불안정성(`S-01`~`S-18`) 및 Round 2 심층 하드닝(`S-19`~`S-28`) 전수 분석

### 2.1 Round 1 핵심 불안정성 해결 내역 (`S-01` ~ `S-18`)

| ID | 심각도 | 대상 파일 | 기존 v1.x 불안정성 원인 | v2.0 해결 방안 |
|---|---|---|---|---|
| **S-01** | **CRITICAL** | `setup-vscode.ps1` | **재실행 시 VS Code 마켓플레이스 데드락**: 1회차에 `product.json` 갤러리 URL을 `127.0.0.1`로 덮어쓴 뒤 2회차 실행 시 확장 설치가 `127.0.0.1`로 요청되어 100% 실패합니다. | `product.json.contest-orig` 원본 백업을 보존하고, 누락 확장 설치 직전 원본 복원 후 재잠금합니다. |
| **S-02** | **CRITICAL** | `install-env.ps1` `restore-and-cleanup.ps1` | **실패 시 자동 롤백이 에러 로그·캐시·학생 코드를 모두 삭제**: `Stop-SetupLogging` 호출 전에 롤백이 실행되어 로그와 수백 MB 설치 파일, 학생 코드를 삭제합니다. | `catch` 진입 즉시 `Stop-SetupLogging` 후 `%TEMP%\ContestSetup-Logs`에 백업하며, 기본적으로 `contest`, `downloads`, `logs`를 보존합니다. |
| **S-03** | **CRITICAL** | `setup-python.ps1` `restore-and-cleanup.ps1` | **기존 시스템 Python 3.10.11 충돌 및 개인 Python 삭제**: WiX Burn이 `TargetDir` 생성을 건너뛰어 크래시되고, 복구 시 `InstallLocation` 검증 없이 개인 Python을 삭제합니다. | MSI `1618` 재시도·시드 복사/NuGet 폴백을 지원하고, `install-manifest.json` 및 `Test-PathInside`로 `C:\CPTools` 내부 설치본만 제거합니다. |
| **S-04** | **CRITICAL** | `setup-msys2.ps1` | **MSYS2 중단 후 `db.lck` 영구 잠금**: `pacman` 강제 종료 시 `db.lck` 및 `gpg-agent`/`dirmngr` 잔존으로 재실행이 영구 실패합니다. | `Remove-StaleMsys2Locks`로 활성 `pacman.exe` 부재 시 잔존 프로세스 종료 및 `db.lck` 자동 제거를 수행합니다. |
| **S-05** | **CRITICAL** | `common.ps1` `setup-wrappers.ps1` | **`Machine` PATH가 `User` PATH를 가리는 현상**: 시스템 PATH의 타 컴파일러나 Git `cat.exe`가 대회 도구를 가립니다. | 원본 `User`/`Machine` PATH 스냅샷 백업 후 양쪽 앞단에 대회 경로를 일관 배치하고 복구 시 원복합니다. |
| **S-06** | **CRITICAL** | `setup-restore-task.ps1` | **하드코딩된 과거 일정 (`2026-05-09T17:10:00`)**: 시험 일정 변경 시 코드 수정이 필요하고 과거 시각 방어가 없습니다. | 기본값을 `2026-11-23T19:00:00` ~ `2026-11-23T20:30:00`으로 갱신하고 과거 시각 방어 로직을 적용했습니다. |
| **S-07** | **HIGH** | `restore-and-cleanup.ps1` | **복구 시 예약 작업 미해제**: 수동 복구 후에도 `ContestSetupRestoreAndCleanup`이 남아 20:30에 PC가 종료됩니다. | 복구 시작 시 3종의 대회 예약 작업을 모두 즉시 해제합니다. |
| **S-08** | **HIGH** | `install-env.ps1` | **UAC 승격 시 공백 경로 인자 깨짐 및 UTF-8 BOM 누락**: 공백 경로 인자 분리 및 PS 5.1 한글 깨짐이 발생합니다. | `Quote-ProcessArgument` 이스케이프 및 임시 승격 스크립트 UTF-8 BOM 기록을 적용했습니다. |
| **S-09** | **HIGH** | `install-env.ps1` `common.ps1` | **무인/자동 배포 시 팝업 블로킹**: `-NoPause` 전달 시에도 `MessageBox`와 대기 루프가 실행을 멈춥니다. | `-NoPause` 지정 시 모든 모달 대화상자와 대기 루프를 생략합니다. |
| **S-10** | **HIGH** | `restore-and-cleanup.ps1` | **복구 스크립트 관리자 권한 확인 누락**: 일반 권한 실행 시 매니페스트만 지워지고 `hosts`와 폴더가 남습니다. | 최상단 `Test-IsAdmin` 검증 및 자동 UAC 승격 로직을 적용했습니다. |
| **S-11** | **HIGH** | `ai-hosts-block.ps1` | **빈 `hosts` 크래시, 잠금 실패 및 IPv6/`www.` 우회**: 빈 문자열 바인딩 오류 및 IPv6/`www.` 미차단 문제가 있었습니다. | `[AllowEmptyString()]`, `ReadOnly` 해제 + 5회 재시도, IPv4(`0.0.0.0`) + IPv6(`::`) + `www.` 확장을 적용했습니다. |
| **S-12** | **HIGH** | `setup-wrappers.ps1` | **`.cmd` 래퍼 `setlocal` 누락 및 `.exe` 섀도잉**: 반복 호출 시 `%PATH%` 8191자 초과 및 `.cmd` 섀도잉이 발생합니다. | 모든 `.cmd`에 `@setlocal`을 추가하고 `$PythonDir -> $UcrtBin -> $MsysUsrBin -> $ToolBin` 순서를 보장합니다. |
| **S-13** | **HIGH** | `setup-msys2.ps1` | **매 실행 300개 인증서 개별 생성 및 유럽 단일 미러 의존**: `update-ca-trust` 지연 및 미러 속도 저하가 발생합니다. | 한국 미러(KAIST, Harukasan) 최우선 배치 및 TLS 오류 시 지연형 단일 PEM 번들 동기화를 적용했습니다. |
| **S-14** | **HIGH** | `setup-visualstudio.ps1` | **VS Community 경로 하드코딩 및 `3010` 실패 처리**: 타 에디션 미인식 및 7~12GB 무조건 설치 문제가 있었습니다. | `vswhere.exe` 전 에디션 감지, 기본 스킵(`-IncludeVisualStudio` 선택 설치), 종료코드 `0`/`3010` 성공 처리를 적용했습니다. |
| **S-15** | **HIGH** | `restore-and-cleanup.ps1` | **하위 프로세스(`cpptools-srv.exe`) 잠금 및 ASCII 배치 인코딩**: 언어 서버 잠금 및 한글 경로 배치 오류가 발생합니다. | `Test-PathInside` 기반 전 하위 프로세스 종료 및 `remove-cptools.cmd` UTF-8(`chcp 65001 >nul`) 기록을 적용했습니다. |
| **S-16** | **MEDIUM** | `common.ps1` | **PS 7+ 폴백 차단 및 캐시 재사용 불가**: `.zip`/`latest` 캐시를 매번 삭제 후 재다운로드합니다. | 전 버전 폴백 허용 및 매직 헤더(`PK\x03\x04`, `MZ`) + 최소 크기 검증 기반 즉시 재사용을 구현했습니다. |
| **S-17** | **MEDIUM** | `install-env.ps1` `setup-*.ps1` | **로컬 파일 무시 및 무조건적인 원격 다운로드**: 로컬 실행 시에도 GitHub 원격 스크립트를 호출합니다. | 로컬 모듈 우선 실행(`-UseRemote` 제어) 및 `$Root\scripts` 스테이징 + AST 구문 검증을 구현했습니다. |
| **S-18** | **MEDIUM** | `common.ps1` `setup-vscode.ps1` | **단일 원소 배열 JSON 직렬화 풀림 및 필수 확장 누락 무시**: 파이프라인 `ConvertTo-Json`이 원소 1개 배열을 단일 객체로 풉니다. | `ConvertTo-Json -InputObject` 배열 보존 및 필수 확장 누락 시 즉시 예외 발생을 적용했습니다. |

### 2.2 Round 2 Windows PowerShell 5.1 실환경·보안·운영 심층 하드닝 (`S-19` ~ `S-28`)

| ID | 심각도 | 대상 파일 | 심층 감사에서 발굴된 실환경 결함 및 우회 벡터 | Round 2 근본 해결 설계 |
|---|---|---|---|---|
| **S-19** | **CRITICAL** | 전체 20개 `.ps1` (`/*.ps1` 12 + `lib/*.ps1` 8) | **BOM 없는 UTF-8 소스 및 `Get-Content`의 한국어 Windows(`CP949`) 깨짐**: `.editorconfig`(UTF-8 no-BOM) 하에서 PS 5.1은 비-ASCII 문자를 `CP949`로 읽어 파싱 오류를 일으키고, 인코딩 미지정 `Get-Content`가 한글 사용자 경로(`C:\Users\홍길동\...`) 매니페스트/PATH 백업을 손상시킵니다. | 20개 모든 `.ps1` 소스를 **100% 7-bit ASCII(`byte < 0x80`)**로 유지하여 UTF-8 no-BOM과 CP949 호환성을 동시 달성하고, 모든 파일 읽기를 `[System.IO.File]::ReadAllText(..., UTF8)` 기반 `Read-TextUtf8`/`Read-LinesUtf8`(`lib/core-primitives.ps1`)로 전면 교체했습니다. |
| **S-20** | **CRITICAL** | `common.ps1` `setup-vscode.ps1` `restore-and-cleanup.ps1` | **PS 5.1 `@(... \| ConvertFrom-Json)` 2중 배열(`Object[][]`) 버그, JSONC 주석 크래시, `product.json` 속성 대입 예외**: PS 5.1에서 단축아이콘 복구가 `Object[][]`로 실패하고, 최신 VS Code `product.json`에 `cacheUrl` 부재 시 직접 대입이 예외를 던져 마켓플레이스가 열린 채 방치됩니다. | 문자열 외부 `//`·`/* */` 주석을 제거하는 `ConvertFrom-JsonSafe` 및 단일 파이프라인을 분리한 `ConvertFrom-JsonArray`를 도입하고, `Set-ObjectProperty`(`Add-Member -Force`) + 기록 후 `serviceUrl == 127.0.0.1` 재검증을 강제했습니다. |
| **S-21** | **CRITICAL** | `install-env.ps1` `restore-and-cleanup.ps1` `common.ps1` | **`CONTEST_*` 문자열 환경변수 무효화, `-Mode Verify`의 파괴적 `hosts` 삭제 및 종료코드 `0` 반환**: `param()` 기본값 때문에 환경변수가 무시되고, `-Mode Verify` 실패 시 `catch`에서 활성 AI `hosts` 차단을 지우며 종료코드 `0`을 반환했습니다. | `$PSBoundParameters.ContainsKey(...)` 기반 환경변수 바인딩, `$PSCommandPath` 통일, 뮤텍스 즉시 `try/finally` 보호, 비파괴 `-Mode Verify` 분리 및 실패 시 정확한 종료코드 `1`(`$global:LASTEXITCODE = 1`) 반환을 구현했습니다. |
| **S-22** | **CRITICAL** | `setup-vscode.ps1` | **VS Code 한국어 UI 미적용(`argv.json` 무시) 및 `Code.exe` 직접 실행 우회**: `--user-data-dir`만으로는 `argv.json`이 무시되어 영문 UI로 실행되며, 탐색기에서 `C:\CPTools\vscode\Code.exe` 직접 실행 시 개인 AI 확장이 로드됩니다. | 모든 런처/단축아이콘에 `--locale ko`를 명시 전달하고, 공식 포터블 디렉터리 `C:\CPTools\vscode\data`(`argv.json`, AI 차단 `settings.json`, 격리 `extensions`)를 함께 초기화하여 직접 실행 우회까지 원천 차단했습니다. |
| **S-23** | **CRITICAL** | `setup-restore-task.ps1` `restore-and-cleanup.ps1` `common.ps1` | **`Interactive` 예약 작업 미실행 및 `SYSTEM` 실행 시 `HKU\.DEFAULT` 오염**: 별도 관리자 UAC 승격이나 학생 조기 로그오프 시 작업이 실행되지 않으며, 단순 `SYSTEM` 전환 시 `User` PATH가 `HKU\.DEFAULT`에 잘못 기록됩니다. | 승격 전/콘솔 세션(`explorer.exe`)에서 학생 `TargetUserSid`·`TargetUserProfile`을 포착해 매니페스트에 저장하고, 예약 작업은 `S-1-5-18`(`ServiceAccount`, `-WakeToRun`)로 실행하되 `Registry::HKEY_USERS\<SID>\Environment`(`REG_EXPAND_SZ` 보존, 로그오프 시 `NTUSER.DAT` 임시 로드)만 정확히 갱신합니다. |
| **S-24** | **CRITICAL** | `setup-restore-task.ps1` `restore-and-cleanup.ps1` `ai-hosts-block.ps1` | **이중 `-StartWhenAvailable` 충돌, 다음 날 수업 중 강제 종료, `remove-cptools.cmd` vs `Stop-Computer` 레이스**: 미실행된 19:00·20:30 작업이 다음 날 동시 실행되어 `hosts`를 재차단하거나 PC를 끄고, `Stop-Computer`가 `rmdir` 전에 배치를 종료시킵니다. | 19:00 작업 `EndBoundary` + `-NotAfter` 만료 가드(`InvariantCulture` 날짜 포맷), 25분 초과 지연 실행 시 `-Shutdown` 자동 해제, `%TEMP%\contest-restore-runner.ps1` 자기 복제, `ping` 대기 배치 및 `rmdir` 완료 **직후** `shutdown.exe` 호출로 모든 레이스를 제거했습니다. |
| **S-25** | **HIGH** | `common.ps1` `setup-restore-task.ps1` `restore-and-cleanup.ps1` | **비-KST 타임존·시계 오차로 인한 시험 중 조기 삭제 위험 및 `SYSTEM` `%TEMP%` 백업 비가시성**: 오프셋 없는 시각 파싱으로 타임존 오설정 노트북에서 코드가 유실되거나 `SYSTEM` 작업 시 `C:\Windows\Temp`에 백업되어 학생이 찾기 어려웠습니다. | `+09:00`(KST) `DateTimeOffset` 정규화, HTTPS 서버 시각 대조(`Invoke-PreflightChecks`), 복구 전 학생 프로필 영구 경로(`TargetUserProfile\AppData\Local\ContestSetup-Backups\ContestSetup-Workspace-Backup-*`) 우선 자동 안전 백업을 구현했습니다. |
| **S-26** | **HIGH** | `setup-msys2.ps1` `restore-and-cleanup.ps1` | **MSYS2 2단계 런타임 업그레이드(`SyncFirst`) 미완성 종료, PGP 키링 오류, `.contest-bak` 미복원**: 코어 런타임 갱신 시 `gcc`/`gdb` 미설치 상태로 종료코드 `0`이 반환되고, 시험 후 학생의 `mingw64`/`clang64` 저장소가 주석 처리된 채 남습니다. | `trustdb.gpg`/`msys2-keyring` 자동 복구, 1차 `pacman` 후 `g++.exe`/`gdb.exe` 실재 재확인 및 2차 트랜잭션 자동 실행, 복구 시 `pacman.conf.contest-bak`·`mirrorlist.*.contest-bak` 원복 및 임시 CA 번들 정리를 추가했습니다. |
| **S-27** | **HIGH** | `ai-hosts-block.ps1` `setup-ai-hosts.ps1` `setup-vscode.ps1` | **브라우저 DoH(DNS-over-HTTPS)·내장 AI 우회, 2025~2026/국내 AI 도메인 누락, 미인가 VS Code 확장**: 브라우저 내장 DoH/AI 기능이나 `chat.com`, `claude.com`, `grok.com`, `genspark.ai`, `manus.im`, `wrtn.ai`, `clova-x.naver.com`, `aistudio.google.com`, `api2.cursor.sh` 등이 우회 경로로 악용될 수 있었습니다. | Chrome/Edge/Whale/Brave/Firefox HKLM DoH(`DnsOverHttpsMode`, `DnsOverHttpsTemplates`) 및 내장 AI/Copilot 정책 22개 항목 잠금(`browser-policies.bak.json` 가역 백업), 135개 이상 기본 도메인(2026·국내 AI 및 ccSLD `.co.kr` `www.` 확장), VS Code 확장 화이트리스트, Fail-Closed `-DeferAiBlockUntilExamStart`(`-NoRestoreTask`와 병행 시에도 `19:00` 작업 보장)를 구현했습니다. |
| **S-28** | **MEDIUM** | `common.ps1` `restore-and-cleanup.ps1` `setup-*.ps1` | **탭 자동완성 후행 `\` 쿼팅 깨짐, `path-*` 역순 정렬, Windows 11 MSIX `pwsh.exe` 스케줄러 오류, WiX Burn 언인스톨 쿼팅**: `-Root "C:\CPTools\"`가 예약 작업 인자를 깨뜨리고, 최신 백업을 원본 대신 복원하며, WindowsApps `pwsh.exe`가 `SYSTEM`에서 실패합니다. | `System32\...\powershell.exe` 최우선 선택, 모든 작업 인자의 `Quote-ProcessArgument` 생성, `path-*` 오름차순(최초 원본 우선) 정렬, WiX Burn `QuietUninstallString` 안전 실행, PS 5.1 공백 경로 `.cmd` 안전 래핑을 적용했습니다. |

---

## 3. ContestSetup 구조적 아키텍처 대안 분석 및 v2.0 설계

### 3.1 아키텍처 대안 비교

| 평가 항목 | 대안 A: 단일 모놀리식 스크립트 (`contest-setup.ps1` 1개 파일) | 대안 B: 기존 v1.x 순수 원격 `irm \| iex` 스트리밍 | **대안 C (채택): v2.0 하이브리드 로컬 우선 + 3계층(`/*.ps1` + `lib/*.ps1`) 스테이징 모듈러 아키텍처** |
|---|---|---|---|
| **유지보수성 및 모듈 분리** | 낮음 (3,000줄 이상 단일 파일로 충돌 및 감사 어려움) | 높음 (역할별 `.ps1` 분리, 단 공통 함수 중복 발생) | **최상** (루트 오케스트레이터 12개 + `lib/` 단일 진실 공급원 8개 = 총 20개 순수 ASCII `.ps1` 분리, [`docs/STRUCTURE.md`](./docs/STRUCTURE.md) 참고) |
| **원라이너(`irm \| iex`) 지원** | 지원 | 지원 | **지원** (`install-env.ps1` 진입점 동일 + `$Root\scripts` 및 `$Root\scripts\lib` 단일 패스 스테이징) |
| **50~200대 실습실 무대역폭 배포** | 별도 패키징 필요 | **불가** (대규모 NAT IP에서 HTTP 429 발생) | **완벽 지원** (`-Mode ExportCache` + `-CacheDir`로 외부 트래픽 0 MB 배포) |
| **디버깅 및 스택 트레이스** | 파일/줄 번호 표시됨 | **불량** (`Invoke-Expression` 메모리 실행으로 줄번호 유실) | **완벽** (`$Root\scripts`(`+lib`) 스테이징 + AST 검증 후 Dot-Sourcing) |
| **다중 계정(`SYSTEM`/UAC) 복원력** | 낮음 | **불량** (로그오프/별도 관리자 계정에서 복구 실패) | **최상** (`S-1-5-18` 서비스 작업 + `TargetUserSid` 레지스트리 복원) |

### 3.2 v2.0 라이프사이클 모드 (`-Mode`) 동작 흐름
- **`Install` (기본값)**: 사전 점검(`Invoke-PreflightChecks`: 64비트 OS, 드라이브별 여유 공간, 시계 오차, 잔존 `hosts` 임시 해제) → 비동기 병렬 프리페치(`Invoke-ParallelDownloadFiles` / `-CacheDir` 시드) → 8단계 모듈 실행 및 `C:\CPTools\state\install-manifest.json` 기록.
- **`ExportCache`**: 실습실 마스터 PC 1대에서 검증된 설치 파일(`msys2`, `python`, `vscode`), 설치 완료된 VS Code 4종 확장(`vscode-extensions`/`.vsix`), MSYS2 `pacman` 패키지(`msys2-pkg`), 스크립트 사본 및 `cache-manifest.json`을 USB/네트워크 공유 폴더로 내보냅니다.
- **`Status` / `Verify`**: 컴파일러 실행, Python 표준 라이브러리, VS Code(`serviceUrl == 127.0.0.1`, 4종 필수 확장, 비인가 확장 부재, `--locale ko`), 10종 래퍼, `hosts` AI 차단 엔트리 수, `2026-11-23 20:30:00` 예약 작업 상태/트리거를 **비파괴적으로** 즉시 검증하며(`hosts` 변경이나 GUI 팝업 없음), 미비 항목 발견 시 종료코드 `1`을 반환합니다.
- **`DryRun`**: 시스템 변경 없이 시험 일정(KST 정규화), 디스크 여유 공간, 아키텍처를 사전 검증합니다.
- **`Restore`**: `restore-and-cleanup.ps1`을 호출하여 학생 코드 안전 백업 후 전체 환경을 즉시 원상 복구합니다.

```powershell
# 1. 마스터 PC에서 실습실 배포용 완전 오프라인 캐시 생성
.\install-env.ps1 -NoPause
.\install-env.ps1 -Mode ExportCache -CacheDir "D:\ContestCache" -NoPause

# 2. 실습실 50~200대 좌석에서 외부 인터넷 대역폭 0 MB로 초고속 무인 설치
.\install-env.ps1 -CacheDir "D:\ContestCache" -NoPause

# 3. 시험 시작 10분 전(18:50) 비파괴 무결성 검증 (정상 시 ExitCode 0, 이상 시 1)
.\install-env.ps1 -Mode Verify -NoPause
```

---

## 4. 설치 환경 구축 시간 단축 및 대규모 실습실 최적화 분석 (`O1` ~ `O10`)

개인 노트북뿐만 아니라 **동일 캠퍼스 NAT 공인 IP를 공유하는 50~200대 실습실 PC**에서 동시 설치할 때 발생하는 네트워크 병목과 디스크 I/O 병목을 **10가지 핵심 최적화(`O1`~`O10`)**로 해결했습니다.

| 최적화 ID | 병목 구간 | 기존 동작 및 소요 시간 | v2.0 최적화 기법 | 단축 시간 (Cold) | 단축 시간 (Warm / 실습실) |
|---|---|---|---|---:|---:|
| **O1** | **Visual Studio 2022 설치** (`setup-visualstudio.ps1`) | `Community\...\devenv.exe`만 확인하고 7~12GB를 강제 설치 (**10~25분**) | `vswhere.exe` + `cl.exe` 전 에디션 자동 감지, 기본 스킵(`-IncludeVisualStudio` 선택 설치), `--includeRecommended` 제거 | **10 ~ 25분 단축** | **3 ~ 8초 단축** |
| **O2** | **MSYS2 `winget` 스킵 시 60초 대기** (`setup-msys2.ps1`) | `Install-ByWinget` 반환값을 버리고 60초 동안 무조건 폴링 | 반환값이 `$true`일 때만 대기 루프 진입 (프리페치 파일 보유 시 즉시 직접 설치) | **60초 단축** | **0초** |
| **O3** | **MSYS2 유럽 단일 미러 및 순차 동기화** (`setup-msys2.ps1`) | `repo.msys2.org` 단일 서버 및 6개 아키텍처 DB 순차 다운로드 (**2~4분**) | 국내 고속 미러(`ftp.kaist.ac.kr`, `mirror.harukasan.org`) 최우선 배치, `ParallelDownloads = 8`, 활성 DB 2개(`ucrt64`, `msys`)로 축소 | **60 ~ 150초 단축** | **10 ~ 25초 단축** |
| **O4** | **MSYS2 인증서 추출 + 다중 `pacman` 호출** (`setup-msys2.ps1`) | 매번 300개 `.crt` 생성 및 `update-ca-trust` 실행(15~35초) | Fast-Path 멱등 스킵(<0.5초), TLS 오류 시 지연형 단일 PEM 번들 생성, 단일 `--needed -Syu` 트랜잭션 통합 | **30 ~ 60초 단축** | **60 ~ 180초 단축** |
| **O5** | **설치 파일 순차 다운로드 및 캐시 폐기** (`common.ps1`) | MSYS2/Python/VS Code 순차 다운로드 및 재시도 시 캐시 삭제 | `Invoke-ParallelDownloadFiles` 병렬 프리페치, 매직 헤더(`PK\x03\x04`/`MZ`) + 최소 크기 검증 기반 캐시 즉시 재사용 | **30 ~ 90초 단축** | **20 ~ 60초 단축** |
| **O6** | **VS Code 확장 4회 개별 `--force` 설치** (`setup-vscode.ps1`) | 4개 확장을 개별 프로세스에서 재설치 (2회차에는 잠금으로 타임아웃) | 미설치 확장만 필터링하여 단일 배치 명령(`--install-extension ...`)으로 일괄 설치 | **15 ~ 35초 단축** | **45 ~ 120초 단축** |
| **O7** | **하위 스크립트 및 `winget --help` 반복 호출** (`common.ps1`) | 하위 스크립트 재다운로드 및 `winget --help` 반복 실행 | `$Root\scripts` 스테이징 재사용 및 `$Script:WingetHelpCache` 캐싱 | **5 ~ 12초 단축** | **5 ~ 12초 단축** |
| **O8** | **VS Code/Python `.zip` 압축 해제 병목 (`tar.exe` 섀도잉)** (`common.ps1`) | `C:\msys64\usr\bin`의 GNU `tar.exe`가 선택되어 실패 후 진행 표시줄이 켜진 PS 5.1 `Expand-Archive`로 폴백 (**45~240초**) | **3단계 `Expand-ArchiveFast`**: 명시적 `$env:SystemRoot\System32\tar.exe`(2~4초) → `[IO.Compression.ZipFile]::ExtractToDirectory`(3~6초) → `$ProgressPreference='SilentlyContinue'` `Expand-Archive` 폴백 | **40 ~ 180초 단축** | **0초 (스킵)** |
| **O9** | **실습실 100대 동시 설치 시 확장/패키지 38GB 트래픽 및 HTTP 429** (`install-env.ps1`, `common.ps1`, `setup-vscode.ps1`, `setup-msys2.ps1`) | 기본 인스톨러만 캐시되어 좌석당 ~380MB(확장 ~200MB + `pacman` ~180MB) 외부 다운로드 및 마켓플레이스 429 차단 발생 + `HttpClient` 본문 순차 수신 | 1) `CopyToAsync` + `Task.WhenAll` 진정한 동시 본문 스트리밍(`DefaultConnectionLimit >= 16`)<br>2) **`-Mode ExportCache`**: `vscode-extensions`/`.vsix`(`robocopy /MT:16`, ~1.5초) 및 `msys2-pkg` 오프라인 시드 지원 (**외부 인터넷 0 MB**) | **30 ~ 75초 단축** | **실습실 100대 기준 35GB+ 절감 및 좌석당 35~50초 내 완료** |
| **O10** | **원격 이중 스테이징 및 Electron CLI 반복 기동** (`install-env.ps1`, `setup-vscode.ps1`, `setup-wrappers.ps1`) | 원격 모드에서 모듈 2회 다운로드(18회 요청), `code.cmd --list-extensions` 3~4회 기동, `settings.json` 2회 기록, 순차 `-O2` 스모크 테스트 | `$Script:StagedScriptPaths` 단일 패스 캐시(18→10 요청), 확장 목록 메모리 캐시(3→1회), `settings.json` 단일 병합 기록, `-O0` 병렬 컴파일 스모크 테스트 | **10 ~ 25초 단축** | **8 ~ 15초 단축** |

### 종합 소요 시간 비교
- **개인 PC 최초 설치 (Cold Install, 온라인)**: 기존 **15 ~ 35분**(VS2022 포함) / **6 ~ 12분**(VS2022 제외, PS 5.1 압축 해제 포함) ➔ **v2.0 Round 2: 약 1.5 ~ 2.5분** (**80~90% 단축**)
- **50~200대 실습실 대량 배포 (`-Mode ExportCache` + `-CacheDir` USB/LAN)**: 기존 좌석당 **4 ~ 8분**(공유 공인 IP 대역폭 포화 및 HTTP 429 오류 위험) ➔ **v2.0 Round 2: 좌석당 약 35 ~ 55초 (외부 인터넷 트래픽 0 MB)**
- **재실행 / 무결성 검증 (`Warm Re-run` / `-Mode Verify`)**: 기존 **3 ~ 6분** ➔ **v2.0 Round 2: 약 2 ~ 6초** (**97% 이상 단축**)

---

## 5. 검증 체계 및 CI

| 계층 | 도구 | 검증 내용 |
|------|------|-----------|
| 정적 구문 | `[System.Management.Automation.Language.Parser]::ParseFile` (Windows PowerShell 5.1 + PowerShell 7, GitHub Actions `windows-latest`) | 루트 12개 + `lib/` 8개(총 20개) `.ps1` 전부 구문 오류 0건 |
| 계약/구조 | `tests/run_tests.py` + `tests/contestsetup_tests/` Tier 1~3 (`PowerShellInspector`) | 파라미터·`CONTEST_*` 환경 변수 동기화, `Import-ContestLibraryModule` 유효 코드 결합, 스크립트 간 호출 계약, 일정 상수, 인코딩(7-bit ASCII, UTF-8 no-BOM, LF) |
| 동작 모델 | `tests/contestsetup_tests/` Tier 2~4 (`BehavioralSimulator`) | `.ps1`에서 추출한 상수·도메인 목록·22개 브라우저 정책(`lib/browser-policies.ps1`)으로 일정/복구/차단 시나리오 시뮬레이션 |
| 적대적/변이 | `tests/contestsetup_tests/tier5_adversarial.py` (`T5_01`~`T5_34`) | 인자 인용 퍼징, 경로 탈출, StrictMode/PS 5.1 함정, 변이(mutation) 검출, `T5_33` 얕은 스코프 `irm \| iex` 회귀 및 `T5_34` 20개 스크립트 AST 감사 |
| 실엔진 Live E2E | `tests/contestsetup_tests/live_pwsh_e2e.py` (`T5_35`~`T5_41`, `pwsh`) | 실제 `pwsh` 프로세스에서 `common.ps1`+`lib/` 일정·매니페스트·`Invoke-ContestEnvironmentAudit`(`T5_35`), 포터블 VS Code 격리·마켓플레이스 잠금/복원(`T5_36`), `.cmd` 래퍼 생성 및 실제 `g++`(C++14/C++20)·`python3` 컴파일/실행(`T5_37`), 오프라인 캐시/패키지 시딩(`T5_38`), `ai-hosts-block.ps1` 멱등 적용/복원 및 22개 브라우저 정책(`T5_39`), `restore-and-cleanup.ps1` 소스 백업·MSYS2 복원·지연 부팅 종료 억제(`T5_40`), 모듈 크기 상한 및 중복 제로 계약 게이트(`T5_41`) 실행 검증 |

- 실행: 저장소 루트에서 `python3 -B tests/run_tests.py --tier all` (총 **291개 테스트**; CI는 `--strict`로 SKIP을 실패로 처리). 모듈 아키텍처 상세는 [`docs/STRUCTURE.md`](./docs/STRUCTURE.md)를 참고하세요.
- 한계: 관리자 권한·`WindowsPrincipal`·실제 Windows 작업 스케줄러 등록 등 Windows 커널 전용 경로는 Linux에서 직접 호출할 수 없으므로, 시험 전 실제 실습실 PC 1대에서 `-Mode DryRun` → `-Mode Install` → `-Mode Verify` 리허설을 권장합니다.
