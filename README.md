# ContestSetup

이 리포지토리는 Windows 환경에서 안전하고 신뢰할 수 있는 **대회용 프로그래밍 환경(Contest Environment)**을 자동으로 구축하고, 대회가 끝난 뒤 자동으로 원래 환경으로 복구해 주는 완벽한 스크립트 모음을 제공합니다.

## 기능 요약
- **독립된 VS Code 환경**: 사용자 설정 및 확장 프로그램이 기존 설정과 충돌하지 않는 완전 독립형(Portable) VS Code 자동 세팅
- **MSYS2 (GCC/GDB) 및 Python 자동 설치**: 최신 UCRT64 기반 GCC 툴체인 및 Python 3.10 설치
- **버전별 컴파일러 래퍼 제공**: `g++14`, `g++17`, `g++20`, `g++`, `gcc`, `gdb`, `python3`, `cat` 등 대회 필수 명령어 자동 구성
- **AI 호스트 차단 (치팅 방지)**: ChatGPT, Copilot, Claude 등 주요 AI 서비스 접속을 Windows `hosts` 수준에서 원천 차단
- **스케줄러 기반 완벽한 자동 복구**: 지정된 시간(**2026년 5월 9일 17시 10분**)에 AI 호스트 차단 해제, 생성된 단축아이콘 삭제, 환경 변수(PATH) 롤백 및 다운로드된 전체 툴셋 폴더(`C:\CPTools`)를 깔끔하게 자동 제거합니다.

---

## 🚀 설치 및 사용 방법

**중요**: 설치를 진행하려면 반드시 **관리자 권한**으로 PowerShell을 실행해야 합니다.

1. `시작` 버튼을 우클릭하거나 `Win + X` 키를 누릅니다.
2. **Windows PowerShell (관리자)** 또는 **터미널 (관리자)**를 선택하여 실행합니다.
3. 아래의 명령어 복사하여 붙여넣고 엔터를 누릅니다.

```powershell
irm https://raw.githubusercontent.com/naixt1478/ContestSetup/main/install-env.ps1 | iex
```

### 설치가 진행되면?
- 화면 상단에 1단계부터 7단계까지 진행 상태 표시줄(Progress Bar)이 나타나며, VS Code, MSYS2, Python, 컴파일러 래퍼, AI 호스트 차단, 그리고 마지막으로 **자동 복구 스케줄러 등록**까지 사람의 개입 없이 한 번에 쭉 진행됩니다.
- 설치가 성공적으로 완료되면, 변경된 환경 변수를 적용하기 위해 **명령 프롬프트(또는 PowerShell)를 껐다 켜 주시기 바랍니다**.

---

## ♻️ 수동 복구 (선택 사항)

시스템에 등록된 자동 복구 스케줄러(2026년 5월 9일 17:10 작동)를 기다리지 않고 **당장** 대회 환경을 지우고 싶으시다면 아래의 명령어를 관리자 권한으로 실행하세요.

```powershell
irm https://raw.githubusercontent.com/naixt1478/ContestSetup/main/restore.ps1 | iex
```
이 명령어는 MSYS2, Python, VS Code, AI 차단 설정, 그리고 환경 변수를 설치 이전 상태로 모두 되돌려 줍니다.
