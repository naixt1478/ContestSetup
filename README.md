# ContestSetup

This repository provides modular PowerShell scripts to quickly set up and tear down a safe, reliable contest environment on Windows.

## Installation & Usage

You can execute the primary scripts directly from the web using the `irm <url> | iex` (Invoke-RestMethod | Invoke-Expression) pattern.

### 1. Install Contest Environment
Installs VS Code, MSYS2 (GCC), Python, and applies contest-safe settings.
```powershell
irm https://raw.githubusercontent.com/naixt1478/ContestSetup/main/install-env.ps1 | iex
```

### 2. Block AI Hosts (Optional)
Applies a temporary block to AI domains (e.g., ChatGPT, Copilot) via the `hosts` file. Automatically restores after a set duration (default: 5 hours).
```powershell
irm https://raw.githubusercontent.com/naixt1478/ContestSetup/main/install-ai-hosts.ps1 | iex
```

### 3. Restore/Uninstall Environment
Removes the contest environment, including MSYS2, Python, VS Code extensions, and path variables.
```powershell
irm https://raw.githubusercontent.com/naixt1478/ContestSetup/main/restore.ps1 | iex
```

## File Structure Overview

### Main Entry Points (`irm ... | iex` targets)
* `install-env.ps1`: Main bootstrap script to set up the entire contest environment.
* `install-ai-hosts.ps1`: Bootstrap script to download and apply the AI host blocklist.
* `restore.ps1`: Main restorer script to clean up the environment.

### Setup Modules
* `common.ps1`: Common utilities, logging, and PATH backups.
* `setup-vscode.ps1`: Installs VS Code and contest-specific extensions.
* `setup-msys2.ps1`: Installs MSYS2 and GCC toolchain.
* `setup-python.ps1`: Installs Python 3.10.
* `setup-visualstudio.ps1`: (Optional) Visual Studio setup logic.
* `setup-wrappers.ps1`: Creates versioned command wrappers (e.g., `g++17`).

### Restore Modules
* `restore-common.ps1`: Common utilities for restoration.
* `restore-vscode.ps1`: Removes VS Code / extensions.
* `restore-msys2.ps1`: Removes MSYS2.
* `restore-python.ps1`: Removes Python.
* `restore-path.ps1`: Restores the system and user PATH variables.
* `restore-hosts.ps1`: Removes the AI blocklist from the hosts file.

### Standalone Utilities
* `ai-hosts-block.ps1`: Core logic for applying and scheduling the AI blocklist (invoked by `install-ai-hosts.ps1`).


& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/naixt1478/ContestSetup/main/Restore-LegacyVSCodeFromOldBackups.ps1'))) -ListOnly -NoPause

$Merged = 'C:\CPTools\backup\vscode-merged-manual'
New-Item -ItemType Directory -Force -Path $Merged | Out-Null

robocopy 'C:\CPTools\backup\vscode-20260504-175616\Code-AAAAAAAAAAAA' "$Merged\Code-AAAAAAAAAAAA" /E /COPY:DAT /DCOPY:DAT /XJ /R:2 /W:1
robocopy 'C:\CPTools\backup\vscode-20260504-181000\.vscode-BBBBBBBBBBBB' "$Merged\.vscode-BBBBBBBBBBBB" /E /COPY:DAT /DCOPY:DAT /XJ /R:2 /W:1

& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/naixt1478/ContestSetup/main/Restore-LegacyVSCodeFromOldBackups.ps1'))) -BackupRoot 'C:\CPTools\backup\vscode-merged-manual' -RemoveContestArtifacts -NoPause


irm https://raw.githubusercontent.com/naixt1478/ContestSetup/main/Restore-LegacyVSCodeFromOldBackups.ps1 | iex

$RestoreBackupRoot = $null

iex "& { $(irm 'https://raw.githubusercontent.com/naixt1478/ContestSetup/main/restore.ps1') } -SkipVSCode -SkipMSYS2 -SkipPython -SkipHosts -NoPause"
