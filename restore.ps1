# restore.ps1
# Modular Contest Environment Restore
# No-cache, fresh-download version.

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$Root = "$env:SystemDrive\CPTools",
    [string]$MsysRoot = "$env:SystemDrive\msys64",
    [string]$PythonVersion = '3.10.11',
    [switch]$SkipVSCode,
    [switch]$SkipMSYS2,
    [switch]$SkipPython,
    [switch]$SkipPath,
    [switch]$SkipHosts,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'

$RepoOwner = "naixt1478"
$RepoName  = "ContestSetup"
$Branch    = "main"
$RawBase   = "https://raw.githubusercontent.com/$RepoOwner/$RepoName/$Branch"
$RunId     = Get-Date -Format 'yyyyMMdd-HHmmss'
$RunNonce  = [guid]::NewGuid().ToString('N')

function Test-IsAdmin {
    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $Principal = New-Object Security.Principal.WindowsPrincipal($Identity)
    return $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-PreferredPowerShell {
    $Pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($Pwsh) { return $Pwsh.Source }
    return "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
}

function ConvertTo-PSQuotedString {
    param([AllowNull()] [string]$Value)
    if ($null -eq $Value) { return "''" }
    return "'" + ($Value -replace "'", "''") + "'"
}

function Get-ForwardedArgumentArray {
    $Forwarded = @()
    if ($SkipVSCode) { $Forwarded += '-SkipVSCode' }
    if ($SkipMSYS2) { $Forwarded += '-SkipMSYS2' }
    if ($SkipPython) { $Forwarded += '-SkipPython' }
    if ($SkipPath) { $Forwarded += '-SkipPath' }
    if ($SkipHosts) { $Forwarded += '-SkipHosts' }
    if ($NoPause) { $Forwarded += '-NoPause' }
    if ($WhatIfPreference) { $Forwarded += '-WhatIf' }
    if ($Root) { $Forwarded += @('-Root', $Root) }
    if ($MsysRoot) { $Forwarded += @('-MsysRoot', $MsysRoot) }
    if ($PythonVersion) { $Forwarded += @('-PythonVersion', $PythonVersion) }
    return $Forwarded
}

function Get-NoCacheHeaders {
    return @{
        'Cache-Control' = 'no-cache, no-store, max-age=0'
        'Pragma'        = 'no-cache'
        'Expires'       = '0'
    }
}

function Add-NoCacheQuery {
    param(
        [Parameter(Mandatory = $true)] [string]$Uri,
        [Parameter(Mandatory = $true)] [string]$Key
    )

    $Separator = '?'
    if ($Uri.Contains('?')) { $Separator = '&' }
    $Stamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    return "$Uri${Separator}cb=$RunNonce-$Key-$Stamp"
}

function Clear-ContestRestoreStaleCache {
    $TempRoot = [System.IO.Path]::GetTempPath()
    if ([string]::IsNullOrWhiteSpace($TempRoot) -or -not (Test-Path -LiteralPath $TempRoot -PathType Container)) { return }

    $CurrentScriptPath = $MyInvocation.MyCommand.Path
    if ([string]::IsNullOrWhiteSpace($CurrentScriptPath)) { $CurrentScriptPath = $PSCommandPath }

    # Older installer versions reused this folder, so removing it prevents a stale local restore file from being re-used.
    # Do not remove it if the currently executing script itself lives inside that folder.
    foreach ($Path in @(Join-Path $TempRoot 'contest-env-installer')) {
        try {
            $ShouldSkip = $false
            if (-not [string]::IsNullOrWhiteSpace($CurrentScriptPath)) {
                $FolderNorm = [System.IO.Path]::GetFullPath($Path).TrimEnd([char[]]@('\', '/')) + '\'
                $ScriptNorm = [System.IO.Path]::GetFullPath($CurrentScriptPath)
                if ($ScriptNorm.StartsWith($FolderNorm, [System.StringComparison]::OrdinalIgnoreCase)) { $ShouldSkip = $true }
            }
            if (-not $ShouldSkip -and (Test-Path -LiteralPath $Path)) {
                Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        catch {}
    }

    # Keep only recent restore folders. This avoids touching the current run and prevents temp buildup.
    try {
        Get-ChildItem -LiteralPath $TempRoot -Directory -Filter 'contest-restore-*' -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-2) } |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
    catch {}
}

function Save-FreshRestoreModule {
    param(
        [Parameter(Mandatory = $true)] [string]$ModuleName,
        [Parameter(Mandatory = $true)] [string]$DestinationDirectory
    )

    if ([string]::IsNullOrWhiteSpace($ModuleName)) { throw 'ModuleName is empty.' }
    if ([string]::IsNullOrWhiteSpace($DestinationDirectory)) { throw 'DestinationDirectory is empty.' }

    if (-not (Test-Path -LiteralPath $DestinationDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $DestinationDirectory -Force | Out-Null
    }

    $RawUri = "$RawBase/$ModuleName"
    $FreshUri = Add-NoCacheQuery -Uri $RawUri -Key ($ModuleName -replace '[^a-zA-Z0-9_.-]', '_')
    $LocalPath = Join-Path $DestinationDirectory $ModuleName

    Write-Host "Downloading fresh module: $ModuleName" -ForegroundColor DarkGray
    Invoke-WebRequest -Uri $FreshUri -Headers (Get-NoCacheHeaders) -UseBasicParsing -OutFile $LocalPath -ErrorAction Stop

    if (-not (Test-Path -LiteralPath $LocalPath -PathType Leaf)) {
        throw "Downloaded module was not created: $LocalPath"
    }

    $FileItem = Get-Item -LiteralPath $LocalPath -ErrorAction Stop
    if ($FileItem.Length -le 0) {
        throw "Downloaded module is empty: $ModuleName"
    }

    try {
        $Hash = Get-FileHash -Algorithm SHA256 -LiteralPath $LocalPath
        Write-Host "Loaded $ModuleName SHA256=$($Hash.Hash)" -ForegroundColor DarkGray
    }
    catch {
        Write-Host "Loaded $ModuleName from $LocalPath" -ForegroundColor DarkGray
    }

    return $LocalPath
}

function Remove-StaleRestoreModuleFunctions {
    param([Parameter(Mandatory = $true)] [string]$ModuleName)

    $FunctionNames = @()
    switch ($ModuleName) {
        'restore-msys2.ps1' {
            $FunctionNames = @(
                'Restore-MSYS2',
                'Get-ContestStringVariable',
                'Get-DefaultMSYS2Root',
                'Get-PathStringSafe',
                'ConvertTo-FullPathSafe',
                'Normalize-PathForCompare',
                'Get-LeafNameSafe',
                'ConvertTo-SafeBackupLeaf',
                'Stop-MSYS2Processes',
                'Get-MSYS2SourceFromManifest',
                'Find-MSYS2BackupSource',
                'Invoke-MSYS2RobocopyMirror'
            )
        }
        default { $FunctionNames = @() }
    }

    foreach ($Name in $FunctionNames) {
        try { Remove-Item -LiteralPath "Function:\$Name" -ErrorAction SilentlyContinue } catch {}
    }
}

function Invoke-RestoreModuleFromRaw {
    param(
        [Parameter(Mandatory = $true)] [string]$ModuleName,
        [Parameter(Mandatory = $true)] [bool]$Critical,
        [Parameter(Mandatory = $true)] [string]$ModuleDirectory
    )

    Write-Host "Running $ModuleName..." -ForegroundColor Yellow
    try {
        Remove-StaleRestoreModuleFunctions -ModuleName $ModuleName
        $LocalPath = Save-FreshRestoreModule -ModuleName $ModuleName -DestinationDirectory $ModuleDirectory
        . $LocalPath
        return $true
    }
    catch {
        if ($Critical) { throw }
        Write-Warning "Module failed but restore will continue: $ModuleName"
        Write-Warning $_.Exception.Message
        return $false
    }
}

if (-not (Test-IsAdmin)) {
    Write-Host "Requesting administrator permission..." -ForegroundColor Yellow

    $ForwardedArgs = @(Get-ForwardedArgumentArray)
    $ScriptPath = $MyInvocation.MyCommand.Path

    if (-not [string]::IsNullOrWhiteSpace($ScriptPath) -and (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
        $RelaunchArgs = @('-NoExit', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath)
        $RelaunchArgs += $ForwardedArgs
        Start-Process -FilePath (Get-PreferredPowerShell) -ArgumentList $RelaunchArgs -Verb RunAs -Wait
        exit
    }

    # When started through irm ... | iex, there is no reliable local -File path.
    # Download a fresh restore.ps1 to a new temp folder and relaunch that file as Administrator.
    # This avoids passing a null -File path and avoids stale temp copies from older installer versions.
    try { Clear-ContestRestoreStaleCache } catch {}

    $BootstrapDir = Join-Path ([System.IO.Path]::GetTempPath()) ("contest-restore-bootstrap-$RunId-$RunNonce")
    New-Item -ItemType Directory -Path $BootstrapDir -Force | Out-Null
    $BootstrapScript = Save-FreshRestoreModule -ModuleName 'restore.ps1' -DestinationDirectory $BootstrapDir

    if ([string]::IsNullOrWhiteSpace($BootstrapScript) -or -not (Test-Path -LiteralPath $BootstrapScript -PathType Leaf)) {
        throw "Failed to prepare elevated restore script: $BootstrapScript"
    }

    $RelaunchArgs = @('-NoExit', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $BootstrapScript)
    $RelaunchArgs += $ForwardedArgs
    Start-Process -FilePath (Get-PreferredPowerShell) -ArgumentList $RelaunchArgs -Verb RunAs -Wait
    exit
}

try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

Clear-ContestRestoreStaleCache

$ModuleCacheRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("contest-restore-$RunId-$RunNonce")
New-Item -ItemType Directory -Path $ModuleCacheRoot -Force | Out-Null

Write-Host "Contest Environment Restore (Modular / NoCache)" -ForegroundColor Cyan
Write-Host "Repository : $RepoOwner/$RepoName"
Write-Host "Branch     : $Branch"
Write-Host "RunId      : $RunId"
Write-Host "Module dir : $ModuleCacheRoot"
Write-Host ""

$CriticalModules = @('common.ps1', 'restore-common.ps1')
$RestoreModules = @()
if (-not $SkipHosts) { $RestoreModules += 'restore-hosts.ps1' }
if (-not $SkipVSCode) { $RestoreModules += 'restore-vscode.ps1' }
if (-not $SkipMSYS2) { $RestoreModules += 'restore-msys2.ps1' }
if (-not $SkipPython) { $RestoreModules += 'restore-python.ps1' }
if (-not $SkipPath) { $RestoreModules += 'restore-path.ps1' }

$Total = $CriticalModules.Count + $RestoreModules.Count
$Step = 1
$FailedModules = New-Object System.Collections.Generic.List[string]

try {
    foreach ($Module in $CriticalModules) {
        Write-Host "[$Step/$Total] " -NoNewline
        Invoke-RestoreModuleFromRaw -ModuleName $Module -Critical $true -ModuleDirectory $ModuleCacheRoot | Out-Null
        $Step++
    }

    foreach ($Module in $RestoreModules) {
        Write-Host "[$Step/$Total] " -NoNewline
        $Ok = Invoke-RestoreModuleFromRaw -ModuleName $Module -Critical $false -ModuleDirectory $ModuleCacheRoot
        if (-not $Ok) { $FailedModules.Add($Module) | Out-Null }
        $Step++
    }

    Write-Host ""
    if ($FailedModules.Count -eq 0) {
        Write-Host "All restores completed successfully." -ForegroundColor Green
    }
    else {
        Write-Host "Restore completed with partial failures." -ForegroundColor Yellow
        Write-Host "Failed modules: $($FailedModules -join ', ')" -ForegroundColor Yellow
        Write-Host "The modules after the failed one were still attempted." -ForegroundColor Yellow
    }
    Write-Host "Important: restart PowerShell and VS Code to reload PATH." -ForegroundColor Yellow
} catch {
    Write-Host ""
    Write-Host "FATAL ERROR during $Module" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
} finally {
    if (-not $NoPause) {
        Write-Host "Press Enter to close this window..." -ForegroundColor Yellow
        try { Read-Host | Out-Null } catch {}
    }
}
