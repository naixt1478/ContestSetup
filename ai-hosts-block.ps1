#requires -Version 5.1
# ai-hosts-block.ps1
# ContestSetup v2.0 -- Resilient IPv4 + IPv6 + www AI Hosts & Browser DoH Blocker for Contest Day
#
# Default:
#   Apply the built-in AI blocklist, enforce reversible Browser DoH/Copilot policies,
#   and schedule automatic restore at exam end (or after -DurationHours / at -Until).
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\ai-hosts-block.ps1
#   powershell -ExecutionPolicy Bypass -File .\ai-hosts-block.ps1 -DurationHours 3
#   powershell -ExecutionPolicy Bypass -File .\ai-hosts-block.ps1 -Until "2026-11-23 20:30"
#   powershell -ExecutionPolicy Bypass -File .\ai-hosts-block.ps1 -Apply -NoSchedule -NotAfter "2026-11-23T20:30:00+09:00"
#   powershell -ExecutionPolicy Bypass -File .\ai-hosts-block.ps1 -Restore

[CmdletBinding(DefaultParameterSetName = 'Apply')]
param(
  [Parameter(ParameterSetName = 'Apply')] [switch]$Apply,
  [Parameter(ParameterSetName = 'Apply')] [string]$Until = '',
  [Parameter(ParameterSetName = 'Apply')] [int]$DurationHours = 0,
  [Parameter(ParameterSetName = 'Apply')] [switch]$NoSchedule,
  [Parameter(ParameterSetName = 'Apply')] [string]$NotAfter = '',

  [Parameter(ParameterSetName = 'Restore')] [switch]$Restore,

  [string]$Root = "$env:SystemDrive\CPTools",
  [string]$DomainListPath = '',
  [string]$DomainListUrl = '',
  [Parameter(ParameterSetName = 'Apply')] [string]$BlockListPath = '',
  [Parameter(ParameterSetName = 'Apply')] [string]$BlockListUrl = '',
  [Parameter(ParameterSetName = 'Apply')] [string]$BlockListSha256 = '',
  [Parameter(ParameterSetName = 'Apply')] [switch]$AllowUnverifiedBlockListUrl,
  [switch]$ForceDownload,
  [switch]$SkipBrowserPolicy
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
try { $global:PSNativeCommandUseErrorActionPreference = $false } catch {}

$Script:ScriptBoundParameters = @{}
if (Get-Variable -Name 'PSBoundParameters' -ErrorAction SilentlyContinue)
{
  if ($null -ne $PSBoundParameters)
  {
    foreach ($Key in $PSBoundParameters.Keys)
    {
      $Script:ScriptBoundParameters[$Key] = $PSBoundParameters[$Key]
    }
  }
}

if (-not [string]::IsNullOrWhiteSpace($Root))
{
  $ResolvedRoot = [IO.Path]::GetFullPath($Root.Trim())
  if ($ResolvedRoot -notmatch '^[A-Za-z]:\\$')
  {
    $Root = $ResolvedRoot.TrimEnd('\', '/')
  }
}

$BlockDir = Join-Path $Root 'ai-block'
$AltHoldDir = Join-Path $Root 'ai-hosts-block'
$LogDir = Join-Path $Root 'logs'
$StableScriptPath = Join-Path $BlockDir 'ai-hosts-block.ps1'
$AltStableScriptPath = Join-Path $AltHoldDir 'ai-hosts-block.ps1'
$RootScriptPath = Join-Path $Root 'ai-hosts-block.ps1'
$HostsPath = if (-not [string]::IsNullOrWhiteSpace($env:CONTEST_HOSTS_PATH_OVERRIDE)) {
  $env:CONTEST_HOSTS_PATH_OVERRIDE
} elseif (-not [string]::IsNullOrWhiteSpace($env:SystemRoot)) {
  Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
} else {
  '/etc/hosts'
}
$BackupPath = Join-Path $BlockDir 'hosts.before-ai-block.bak'
$BrowserPolicyBackupPath = Join-Path $BlockDir 'browser-policies.bak.json'
$RawListPath = Join-Path $BlockDir 'ai-block-hosts.txt'
$ParsedListPath = Join-Path $BlockDir 'ai-block-domains.txt'
$TimeStamp = [DateTime]::Now.ToString('yyyyMMdd-HHmmss', [System.Globalization.CultureInfo]::InvariantCulture)
$TaskName = 'ContestSetupRestoreAiHostsBlock'
$BeginMarker = '# >>> CP_CONTEST_AI_BLOCKLIST_BEGIN'
$EndMarker = '# <<< CP_CONTEST_AI_BLOCKLIST_END'
$DefaultExamEndKstIso = '2026-11-23T20:30:00+09:00'
$DefaultBlockDurationHours = 5

$DefaultAiBlockDomains = @(
  # OpenAI / ChatGPT / Codex
  'chat.openai.com',
  'chatgpt.com',
  'chat.com',
  'openai.com',
  'api.openai.com',
  'oaistatic.com',
  'oaiusercontent.com',
  'cdn.openai.com',
  'auth.openai.com',
  'auth0.openai.com',
  'platform.openai.com',
  'sora.com',

  # Anthropic / Claude
  'anthropic.com',
  'claude.ai',
  'claude.com',
  'api.anthropic.com',
  'api.claude.ai',
  'claudeusercontent.com',
  'cdn.claude.ai',
  'console.anthropic.com',

  # Google Gemini / AI Studio / NotebookLM / IDX
  'gemini.google.com',
  'bard.google.com',
  'aistudio.google.com',
  'notebooklm.google.com',
  'idx.google.com',
  'firebase.studio',
  'jules.google.com',
  'generativelanguage.googleapis.com',
  'aisandbox-pa.googleapis.com',
  'makersuite.google.com',

  # xAI / Grok
  'grok.com',
  'x.ai',
  'api.x.ai',
  'accounts.x.ai',
  'console.x.ai',

  # Microsoft / GitHub Copilot
  'copilot.microsoft.com',
  'm365copilot.com',
  'copilot.cloud.microsoft',
  'bing.com',
  'edgeservices.bing.com',
  'sydney.bing.com',
  'api.githubcopilot.com',
  'api.individual.githubcopilot.com',
  'proxy.individual.githubcopilot.com',
  'api.business.githubcopilot.com',
  'api.enterprise.githubcopilot.com',
  'copilot-proxy.githubusercontent.com',
  'copilot-telemetry.githubusercontent.com',
  'githubcopilot.com',
  'copilot.github.com',
  'default.exp-tas.com',

  # Korean AI Platforms -- Wrtn, Naver CLOVA X / Cue, Liner, Estsoft Alan
  'wrtn.ai',
  'api.wrtn.ai',
  'clova-x.naver.com',
  'cue.search.naver.com',
  'liner.com',
  'getliner.com',
  'alan.estsoft.ai',
  'zeta-ai.io',

  # Cursor
  'cursor.com',
  'cursor.sh',
  'api.cursor.sh',
  'api2.cursor.sh',
  'api3.cursor.sh',
  'api4.cursor.sh',
  'repo42.cursor.sh',
  'cursor-cdn.com',
  'marketplace.cursorapi.com',

  # Windsurf / Codeium / Trae / Augment / Amp / JetBrains AI
  'codeium.com',
  'api.codeium.com',
  'server.codeium.com',
  'ide.codeium.com',
  'codeiumdata.com',
  'exafunction.com',
  'windsurf.com',
  'windsurf.ai',
  'api.windsurf.com',
  'trae.ai',
  'api.trae.ai',
  'augmentcode.com',
  'api.augmentcode.com',
  'ampcode.com',
  'jetbrains.ai',
  'api.jetbrains.ai',

  # Tabnine
  'tabnine.com',
  'api.tabnine.com',
  'update.tabnine.com',
  'auth.tabnine.com',

  # Supermaven
  'supermaven.com',
  'api.supermaven.com',

  # Continue.dev
  'continue.dev',
  'api.continue.dev',

  # Sourcegraph Cody
  'sourcegraph.com',
  'cody.sourcegraph.com',
  'api.sourcegraph.com',

  # Amazon Q / CodeWhisperer
  'codewhisperer.us-east-1.amazonaws.com',
  'codewhisperer.api.aws',

  # DeepSeek / Qwen / Kimi / GLM / Doubao
  'deepseek.com',
  'api.deepseek.com',
  'chat.deepseek.com',
  'qwen.ai',
  'chat.qwen.ai',
  'qwenlm.ai',
  'chat.qwenlm.ai',
  'tongyi.aliyun.com',
  'kimi.com',
  'kimi.moonshot.cn',
  'api.moonshot.cn',
  'z.ai',
  'chat.z.ai',
  'chatglm.cn',
  'doubao.com',
  'cici.com',

  # Mistral / Meta AI / Cohere
  'mistral.ai',
  'api.mistral.ai',
  'chat.mistral.ai',
  'lechat.mistral.ai',
  'meta.ai',
  'cohere.com',
  'coral.cohere.com',
  'api.cohere.ai',

  # Inference Clouds & Model Hubs
  'together.ai',
  'api.together.xyz',
  'openrouter.ai',
  'huggingface.co',
  'hf.co',
  'replicate.com',
  'groq.com',
  'api.groq.com',
  'console.groq.com',
  'cerebras.ai',
  'chat.cerebras.ai',
  'inference.cerebras.ai',
  'fireworks.ai',
  'api.fireworks.ai',
  'sambanova.ai',
  'cloud.sambanova.ai',
  'ollama.com',
  'registry.ollama.ai',

  # Zero-Login Aggregators, Search & Cloud Coding Agents
  'lmarena.ai',
  'chat.lmsys.org',
  'duck.ai',
  'perplexity.ai',
  'genspark.ai',
  'manus.im',
  'poe.com',
  'you.com',
  'phind.com',
  'v0.dev',
  'v0.app',
  'bolt.new',
  'lovable.dev',
  'replit.com',

  # Misc IDE Agents
  'bito.ai',
  'api.bito.ai',
  'blackbox.ai',
  'api.blackbox.ai',
  'codegeex.cn',
  'api.codegeex.cn',

  # Analytics / Telemetry / Social
  'events.statsigapi.net',
  'x.com'
)

if (-not (Get-Command Import-ContestLibraryModule -ErrorAction SilentlyContinue))
{
  function Import-ContestLibraryModule
  {
    param(
      [Parameter(Mandatory = $true)] [string]$ModuleName,
      [switch]$Optional
    )
    $Candidates = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot))
    {
      $Candidates.Add((Join-Path (Join-Path $PSScriptRoot 'lib') $ModuleName)) | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace($PSCommandPath))
    {
      $CmdParent = Split-Path -Parent $PSCommandPath
      if (-not [string]::IsNullOrWhiteSpace($CmdParent))
      {
        $Candidates.Add((Join-Path (Join-Path $CmdParent 'lib') $ModuleName)) | Out-Null
      }
    }
    if (-not [string]::IsNullOrWhiteSpace($env:CONTEST_LIB_DIR))
    {
      $Candidates.Add((Join-Path $env:CONTEST_LIB_DIR $ModuleName)) | Out-Null
    }
    $StageVar = Get-Variable -Name 'ScriptStageDir' -ErrorAction SilentlyContinue
    if ($null -ne $StageVar -and -not [string]::IsNullOrWhiteSpace([string]$StageVar.Value))
    {
      $Candidates.Add((Join-Path (Join-Path ([string]$StageVar.Value) 'lib') $ModuleName)) | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace($Root))
    {
      $Candidates.Add((Join-Path (Join-Path $Root 'lib') $ModuleName)) | Out-Null
      $Candidates.Add((Join-Path (Join-Path (Join-Path $Root 'scripts') 'lib') $ModuleName)) | Out-Null
      $Candidates.Add((Join-Path (Join-Path (Join-Path $Root 'ai-block') 'lib') $ModuleName)) | Out-Null
      $Candidates.Add((Join-Path (Join-Path (Join-Path $Root 'ai-hosts-block') 'lib') $ModuleName)) | Out-Null
    }
    try
    {
      $CurLoc = (Get-Location).Path
      if (-not [string]::IsNullOrWhiteSpace($CurLoc))
      {
        $Candidates.Add((Join-Path (Join-Path $CurLoc 'lib') $ModuleName)) | Out-Null
      }
    }
    catch {}

    $ResolvedModule = $null
    foreach ($Candidate in $Candidates)
    {
      if (-not [string]::IsNullOrWhiteSpace($Candidate) -and (Test-Path -LiteralPath $Candidate))
      {
        $ResolvedModule = $Candidate
        break
      }
    }

    if ($null -eq $ResolvedModule -and (-not $Optional))
    {
      try
      {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $TempLibDir = Join-Path (Join-Path ([IO.Path]::GetTempPath()) 'contest-env-installer') 'lib'
        New-Item -ItemType Directory -Force -Path $TempLibDir | Out-Null
        $TempModulePath = Join-Path $TempLibDir $ModuleName
        $OldProg = $ProgressPreference
        try
        {
          $ProgressPreference = 'SilentlyContinue'
          $ReqParams = @{ Uri = "https://raw.githubusercontent.com/naixt1478/ContestSetup/main/lib/$ModuleName"; OutFile = $TempModulePath; ErrorAction = 'Stop' }
          if ($PSVersionTable.PSVersion.Major -le 5) { $ReqParams['UseBasicParsing'] = $true }
          Invoke-WebRequest @ReqParams
          if (Test-Path -LiteralPath $TempModulePath) { $ResolvedModule = $TempModulePath }
        }
        finally
        {
          $ProgressPreference = $OldProg
        }
      }
      catch {}
    }

    if ($null -ne $ResolvedModule)
    {
      . $ResolvedModule
      $Tokens = $null
      $Errors = $null
      $Ast = [System.Management.Automation.Language.Parser]::ParseFile($ResolvedModule, [ref]$Tokens, [ref]$Errors)
      if ($null -ne $Ast -and $null -ne $Ast.EndBlock)
      {
        foreach ($Stmt in $Ast.EndBlock.Statements)
        {
          if ($Stmt -is [System.Management.Automation.Language.FunctionDefinitionAst])
          {
            $FnItem = Get-Item -LiteralPath "Function:\$($Stmt.Name)" -ErrorAction SilentlyContinue
            if ($null -ne $FnItem)
            {
              Set-Item -Path "Function:\script:$($Stmt.Name)" -Value $FnItem.ScriptBlock
            }
          }
        }
      }
      return
    }

    if (-not $Optional)
    {
      throw "Required ContestSetup library module not found: lib/$ModuleName"
    }
  }
}

Import-ContestLibraryModule -ModuleName 'core-primitives.ps1'
Import-ContestLibraryModule -ModuleName 'browser-policies.ps1'

function ConvertTo-LocalScheduleTime
{
  param([Parameter(Mandatory = $true)] [string]$Text)
  $Trimmed = $Text.Trim()
  if ($Trimmed -match '^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(:\d{2}(\.\d+)?)?$')
  {
    $IsoKst = ($Trimmed -replace ' ', 'T') + '+09:00'
    return ([DateTimeOffset]::Parse($IsoKst, [System.Globalization.CultureInfo]::InvariantCulture)).LocalDateTime
  }
  try
  {
    return ([DateTimeOffset]::Parse($Trimmed, [System.Globalization.CultureInfo]::InvariantCulture)).LocalDateTime
  }
  catch
  {
    return [datetime]::Parse($Trimmed, [System.Globalization.CultureInfo]::InvariantCulture)
  }
}

function Ensure-Admin
{
  if (Test-IsAdmin) { return }
  if (-not $PSCommandPath) { throw 'Administrator relaunch requires a saved .ps1 file.' }

  $Args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
  if ($Restore)
  {
    $Args += '-Restore'
  }
  else
  {
    $Args += '-Apply'
    if ($NoSchedule) { $Args += '-NoSchedule' }
    if ($DurationHours -gt 0 -or ($null -ne $Script:ScriptBoundParameters -and $Script:ScriptBoundParameters.ContainsKey('DurationHours')))
    {
      $Args += @('-DurationHours', [string]$DurationHours)
    }
    if (-not [string]::IsNullOrWhiteSpace($Until)) { $Args += @('-Until', $Until) }
    if (-not [string]::IsNullOrWhiteSpace($NotAfter)) { $Args += @('-NotAfter', $NotAfter) }
    if (-not [string]::IsNullOrWhiteSpace($BlockListPath)) { $Args += @('-BlockListPath', $BlockListPath) }
    if (-not [string]::IsNullOrWhiteSpace($BlockListUrl)) { $Args += @('-BlockListUrl', $BlockListUrl) }
    if (-not [string]::IsNullOrWhiteSpace($BlockListSha256)) { $Args += @('-BlockListSha256', $BlockListSha256) }
    if ($AllowUnverifiedBlockListUrl) { $Args += '-AllowUnverifiedBlockListUrl' }
  }
  if (-not [string]::IsNullOrWhiteSpace($DomainListPath)) { $Args += @('-DomainListPath', $DomainListPath) }
  if (-not [string]::IsNullOrWhiteSpace($DomainListUrl)) { $Args += @('-DomainListUrl', $DomainListUrl) }
  if ($ForceDownload) { $Args += '-ForceDownload' }
  if ($SkipBrowserPolicy) { $Args += '-SkipBrowserPolicy' }
  if (-not [string]::IsNullOrWhiteSpace($Root)) { $Args += @('-Root', $Root) }

  $ArgumentString = ($Args | ForEach-Object { Quote-ProcessArgument $_ }) -join ' '
  try
  {
    $ElevatedProc = Start-Process -FilePath (Get-PreferredPowerShell) -ArgumentList $ArgumentString -Verb RunAs -Wait -PassThru
  }
  catch [System.ComponentModel.Win32Exception]
  {
    throw "Administrator UAC prompt was cancelled or denied: $($_.Exception.Message)"
  }
  $ExitCode = if ($null -ne $ElevatedProc) { [int]$ElevatedProc.ExitCode } else { 1 }
  exit $ExitCode
}

function Write-HostsFileWithRetry
{
  param(
    [Parameter(Mandatory = $true)] [string]$Path,
    [Parameter(Mandatory = $true)] [AllowEmptyString()] [string]$Content,
    [int]$MaxAttempts = 5
  )
  $Encoding = New-Object System.Text.UTF8Encoding($false)
  $LastError = $null
  for ($Attempt = 1; $Attempt -le $MaxAttempts; $Attempt++)
  {
    try
    {
      if (Test-Path -LiteralPath $Path)
      {
        $Item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        if ($Item -and ($Item.Attributes -band [IO.FileAttributes]::ReadOnly))
        {
          $Item.Attributes = $Item.Attributes -bxor [IO.FileAttributes]::ReadOnly
        }
      }
      [IO.File]::WriteAllText($Path, $Content, $Encoding)
      return
    }
    catch
    {
      $LastError = $_
      if ($Attempt -lt $MaxAttempts)
      {
        $DelayMs = 200 * $Attempt
        Write-Warning "hosts file write locked (attempt $Attempt/$MaxAttempts): $($_.Exception.Message). Retrying in ${DelayMs}ms..."
        Start-Sleep -Milliseconds $DelayMs
      }
    }
  }
  throw "Failed to write hosts file '$Path' after $MaxAttempts attempts: $($LastError.Exception.Message)"
}

function Invoke-DnsCacheFlush
{
  try
  {
    if (Get-Command Clear-DnsClientCache -ErrorAction SilentlyContinue)
    {
      Clear-DnsClientCache -ErrorAction SilentlyContinue
    }
  }
  catch {}
  try { ipconfig.exe /flushdns | Out-Null } catch {}
}

function Invoke-DownloadFile
{
  param(
    [Parameter(Mandatory = $true)] [string]$Url,
    [Parameter(Mandatory = $true)] [string]$OutFile,
    [int]$MaxAttempts = 3
  )
  try
  {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  }
  catch {}
  New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($OutFile)) | Out-Null
  $LastErr = $null
  for ($Attempt = 1; $Attempt -le $MaxAttempts; $Attempt++)
  {
    try
    {
      $OldProgressPref = $ProgressPreference
      try
      {
        $ProgressPreference = 'SilentlyContinue'
        $Params = @{ Uri = $Url; OutFile = $OutFile; ErrorAction = 'Stop' }
        if ($PSVersionTable.PSVersion.Major -le 5) { $Params['UseBasicParsing'] = $true }
        Invoke-WebRequest @Params
        return
      }
      finally
      {
        $ProgressPreference = $OldProgressPref
      }
    }
    catch
    {
      $LastErr = $_
      if ($Attempt -lt $MaxAttempts) { Start-Sleep -Seconds 2 }
    }
  }
  throw "Failed to download $Url after $MaxAttempts attempts: $($LastErr.Exception.Message)"
}

function Assert-FileSha256
{
  param(
    [Parameter(Mandatory = $true)] [string]$Path,
    [Parameter(Mandatory = $true)] [AllowEmptyString()] [string]$ExpectedSha256
  )
  if ([string]::IsNullOrWhiteSpace($ExpectedSha256)) { return }
  $Actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
  if ($Actual -ine $ExpectedSha256)
  {
    throw "SHA256 mismatch for $Path. Expected $ExpectedSha256, actual $Actual"
  }
}

function Remove-ManagedHostsSectionFromText
{
  param(
    [Parameter(Mandatory = $true)] [Alias('Content')] [AllowEmptyString()] [AllowNull()] [string]$HostsText
  )
  if ([string]::IsNullOrEmpty($HostsText)) { return '' }
  $Pattern = "(?s)\r?\n?" + [regex]::Escape($BeginMarker) + '.*?' + [regex]::Escape($EndMarker) + "\r?\n?"
  $Stripped = [regex]::Replace($HostsText, $Pattern, "`r`n")
  if ($Stripped -like "*$BeginMarker*")
  {
    $OrphanPattern = "(?s)\r?\n?" + [regex]::Escape($BeginMarker) + ".*\z"
    $Stripped = [regex]::Replace($Stripped, $OrphanPattern, "`r`n")
  }
  return $Stripped.TrimEnd()
}

function Set-ContestBrowserPolicies
{
  if ($SkipBrowserPolicy)
  {
    Write-Host 'Browser DoH/Copilot policy lockdown skipped by -SkipBrowserPolicy.' -ForegroundColor Yellow
    return
  }

  $Specs = @((Get-BrowserPolicySpecifications) + (Get-ExtendedBrowserPolicySpecifications))

  # Preserve original pre-exam registry state on first run; never overwrite an existing backup on re-run
  if (-not (Test-Path -LiteralPath $BrowserPolicyBackupPath))
  {
    $BackupEntries = New-Object System.Collections.Generic.List[object]
    foreach ($Spec in $Specs)
    {
      $KeyExisted = Test-Path -LiteralPath $Spec.KeyPath
      $ValExisted = $false
      $PriorValue = $null
      if ($KeyExisted)
      {
        try
        {
          $ItemProps = Get-ItemProperty -LiteralPath $Spec.KeyPath -ErrorAction SilentlyContinue
          if ($null -ne $ItemProps -and $null -ne $ItemProps.PSObject.Properties[$Spec.Name])
          {
            $ValExisted = $true
            $PriorValue = $ItemProps.PSObject.Properties[$Spec.Name].Value
          }
        }
        catch {}
      }
      $BackupEntries.Add([ordered]@{
        KeyPath      = $Spec.KeyPath
        KeyExisted   = $KeyExisted
        ValueName    = $Spec.Name
        ValueType    = $Spec.Type
        ValueExisted = $ValExisted
        PriorValue   = $PriorValue
      }) | Out-Null
    }
    Write-JsonUtf8NoBom -Path $BrowserPolicyBackupPath -InputObject @($BackupEntries.ToArray()) -Depth 10
  }

  foreach ($Spec in $Specs)
  {
    try
    {
      if (-not (Test-Path -LiteralPath $Spec.KeyPath))
      {
        New-Item -Path $Spec.KeyPath -Force -ErrorAction SilentlyContinue | Out-Null
      }
      New-ItemProperty -LiteralPath $Spec.KeyPath -Name $Spec.Name -Value $Spec.Value -PropertyType $Spec.Type -Force -ErrorAction Stop | Out-Null
    }
    catch
    {
      Write-Warning "Could not apply browser policy $($Spec.KeyPath)\$($Spec.Name): $($_.Exception.Message)"
    }
  }
  Write-Host 'Applied reversible Browser DoH (Chrome/Edge/Brave/Whale/Firefox) and Copilot lockdown policies.' -ForegroundColor Green
}

function Restore-ContestBrowserPolicies
{
  if ($SkipBrowserPolicy) { return }

  $RestoredFromBackup = $false
  if (Test-Path -LiteralPath $BrowserPolicyBackupPath)
  {
    try
    {
      $RawJson = Read-TextUtf8 -Path $BrowserPolicyBackupPath
      $Entries = @(ConvertFrom-JsonArray -Json $RawJson)
      $CreatedKeys = New-Object System.Collections.Generic.List[string]
      foreach ($Entry in $Entries)
      {
        if ($null -eq $Entry) { continue }
        $KeyPathProp = $Entry.PSObject.Properties['KeyPath']
        $NameProp = $Entry.PSObject.Properties['ValueName']
        if ($null -eq $KeyPathProp -or $null -eq $NameProp) { continue }
        $KeyPath = [string]$KeyPathProp.Value
        $ValName = [string]$NameProp.Value
        $ValType = if ($null -ne $Entry.PSObject.Properties['ValueType']) { [string]$Entry.ValueType } else { 'String' }
        $ValExisted = ($null -ne $Entry.PSObject.Properties['ValueExisted']) -and ([bool]$Entry.ValueExisted)
        $KeyExisted = ($null -ne $Entry.PSObject.Properties['KeyExisted']) -and ([bool]$Entry.KeyExisted)

        if ($ValExisted)
        {
          if (-not (Test-Path -LiteralPath $KeyPath))
          {
            New-Item -Path $KeyPath -Force -ErrorAction SilentlyContinue | Out-Null
          }
          $Prior = if ($null -ne $Entry.PSObject.Properties['PriorValue']) { $Entry.PriorValue } else { '' }
          New-ItemProperty -LiteralPath $KeyPath -Name $ValName -Value $Prior -PropertyType $ValType -Force -ErrorAction SilentlyContinue | Out-Null
        }
        elseif (Test-Path -LiteralPath $KeyPath)
        {
          Remove-ItemProperty -LiteralPath $KeyPath -Name $ValName -Force -ErrorAction SilentlyContinue
        }

        if (-not $KeyExisted -and -not $CreatedKeys.Contains($KeyPath))
        {
          $CreatedKeys.Add($KeyPath) | Out-Null
        }
      }

      foreach ($CandidateKey in $CreatedKeys)
      {
        try
        {
          if (Test-Path -LiteralPath $CandidateKey)
          {
            $RegKey = Get-Item -LiteralPath $CandidateKey -ErrorAction SilentlyContinue
            if ($null -ne $RegKey -and $RegKey.ValueCount -eq 0 -and $RegKey.SubKeyCount -eq 0)
            {
              Remove-Item -LiteralPath $CandidateKey -Force -ErrorAction SilentlyContinue
            }
          }
        }
        catch {}
      }

      Remove-Item -LiteralPath $BrowserPolicyBackupPath -Force -ErrorAction SilentlyContinue
      $RestoredFromBackup = $true
      Write-Host 'Restored Browser DoH and Copilot policies from backup.' -ForegroundColor Green
    }
    catch
    {
      Write-Warning "Browser policy backup restore encountered an error: $($_.Exception.Message). Running surgical policy cleanup..."
    }
  }

  if (-not $RestoredFromBackup)
  {
    foreach ($Spec in @((Get-BrowserPolicySpecifications) + (Get-ExtendedBrowserPolicySpecifications)))
    {
      try
      {
        if (Test-Path -LiteralPath $Spec.KeyPath)
        {
          $ItemProps = Get-ItemProperty -LiteralPath $Spec.KeyPath -ErrorAction SilentlyContinue
          if ($null -ne $ItemProps -and $null -ne $ItemProps.PSObject.Properties[$Spec.Name])
          {
            $CurVal = $ItemProps.PSObject.Properties[$Spec.Name].Value
            if ([string]$CurVal -eq [string]$Spec.Value)
            {
              Remove-ItemProperty -LiteralPath $Spec.KeyPath -Name $Spec.Name -Force -ErrorAction SilentlyContinue
            }
          }
          $RegKey = Get-Item -LiteralPath $Spec.KeyPath -ErrorAction SilentlyContinue
          if ($null -ne $RegKey -and $RegKey.ValueCount -eq 0 -and $RegKey.SubKeyCount -eq 0)
          {
            Remove-Item -LiteralPath $Spec.KeyPath -Force -ErrorAction SilentlyContinue
          }
        }
      }
      catch {}
    }
  }
}

function Get-BlockDomains
{
  $DomainListPathVal = if (Get-Variable -Name 'DomainListPath' -ErrorAction SilentlyContinue) { [string]$DomainListPath } else { '' }
  $BlockListPathVal = if (Get-Variable -Name 'BlockListPath' -ErrorAction SilentlyContinue) { [string]$BlockListPath } elseif (Get-Variable -Name 'BlocklistFile' -ErrorAction SilentlyContinue) { [string]$BlocklistFile } else { '' }
  $DomainListUrlVal = if (Get-Variable -Name 'DomainListUrl' -ErrorAction SilentlyContinue) { [string]$DomainListUrl } else { '' }
  $BlockListUrlVal = if (Get-Variable -Name 'BlockListUrl' -ErrorAction SilentlyContinue) { [string]$BlockListUrl } elseif (Get-Variable -Name 'BlocklistUrl' -ErrorAction SilentlyContinue) { [string]$BlocklistUrl } else { '' }
  $BlockListSha256 = if (Get-Variable -Name 'BlockListSha256' -ErrorAction SilentlyContinue) { [string]$BlockListSha256 } else { '' }
  $AllowUnverifiedBlockListUrl = if (Get-Variable -Name 'AllowUnverifiedBlockListUrl' -ErrorAction SilentlyContinue) { [bool]$AllowUnverifiedBlockListUrl } else { $false }
  $ForceDownload = if (Get-Variable -Name 'ForceDownload' -ErrorAction SilentlyContinue) { [bool]$ForceDownload } else { $false }
  $EffectiveRawListPath = if (Get-Variable -Name 'RawListPath' -ErrorAction SilentlyContinue) {
    [string]$RawListPath
  } elseif (Get-Variable -Name 'Root' -ErrorAction SilentlyContinue) {
    Join-Path (Join-Path ([string]$Root) 'ai-block') 'ai-block-hosts.txt'
  } else {
    Join-Path ([IO.Path]::GetTempPath()) 'ai-block-hosts.txt'
  }

  $EffectiveListPath = if (-not [string]::IsNullOrWhiteSpace($DomainListPathVal)) { $DomainListPathVal } else { $BlockListPathVal }
  $EffectiveListUrl = if (-not [string]::IsNullOrWhiteSpace($DomainListUrlVal)) { $DomainListUrlVal } else { $BlockListUrlVal }

  if (-not [string]::IsNullOrWhiteSpace($EffectiveListPath))
  {
    if (-not (Test-Path -LiteralPath $EffectiveListPath)) { throw "Blocklist file not found: $EffectiveListPath" }
    New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($EffectiveRawListPath)) | Out-Null
    Copy-Item -LiteralPath $EffectiveListPath -Destination $EffectiveRawListPath -Force
  }
  elseif (-not [string]::IsNullOrWhiteSpace($EffectiveListUrl))
  {
    if ([string]::IsNullOrWhiteSpace($BlockListSha256) -and (-not $AllowUnverifiedBlockListUrl) -and (-not $ForceDownload))
    {
      throw 'Remote blocklist requires -BlockListSha256. Use -AllowUnverifiedBlockListUrl only for temporary testing.'
    }
    if ($ForceDownload -or (-not (Test-Path -LiteralPath $EffectiveRawListPath)))
    {
      Invoke-DownloadFile -Url $EffectiveListUrl -OutFile $EffectiveRawListPath
    }
    Assert-FileSha256 -Path $EffectiveRawListPath -ExpectedSha256 $BlockListSha256
  }
  else
  {
    Write-LinesUtf8NoBom -Path $EffectiveRawListPath -Lines ([string[]]($DefaultAiBlockDomains | Sort-Object -Unique | ForEach-Object { "0.0.0.0 $_" }))
  }

  $RawContent = Read-TextUtf8 -Path $EffectiveRawListPath
  $Domains = New-Object System.Collections.Generic.List[string]
  foreach ($Line in ($RawContent -split "`r`n|`n|`r"))
  {
    $Clean = ($Line -replace '#.*$', '').Trim().ToLowerInvariant()
    if (-not $Clean) { continue }
    foreach ($Part in ($Clean -split '\s+'))
    {
      if ($Part -match '^[a-z0-9][a-z0-9.-]*\.[a-z]{2,}$' -and $Part -notmatch '[/*\\]')
      {
        $Domains.Add($Part) | Out-Null
        # Automatically include www.<domain> for 2-label apex domains (chatgpt.com) and 3-label ccSLDs (.co.kr, etc.)
        $LabelCount = ($Part.Split('.')).Count
        $IsCcSldApex = ($LabelCount -eq 3) -and ($Part -match '^[a-z0-9-]+\.(co|or|ac|ne|go|com|org|net)\.[a-z]{2}$')
        if (($Part -notmatch '^www\.') -and (($LabelCount -eq 2) -or $IsCcSldApex))
        {
          $Domains.Add("www.$Part") | Out-Null
        }
      }
    }
  }
  return @($Domains | Sort-Object -Unique)
}

function Copy-SelfToStablePath
{
  if (-not $PSCommandPath) { return }
  New-Item -ItemType Directory -Force -Path $BlockDir, $AltHoldDir | Out-Null
  $SourcePath = [IO.Path]::GetFullPath($PSCommandPath)
  foreach ($TargetPath in @($StableScriptPath, $AltStableScriptPath, $RootScriptPath))
  {
    $DestFull = [IO.Path]::GetFullPath($TargetPath)
    if ($SourcePath -ine $DestFull)
    {
      Copy-Item -LiteralPath $PSCommandPath -Destination $TargetPath -Force -ErrorAction SilentlyContinue
    }
  }

  $SourceDir = Split-Path -Parent $SourcePath
  $LibSearchDirs = @(
    (Join-Path $SourceDir 'lib'),
    (Join-Path (Join-Path $Root 'scripts') 'lib'),
    (Join-Path $Root 'lib')
  )
  if (-not [string]::IsNullOrWhiteSpace($env:CONTEST_LIB_DIR)) { $LibSearchDirs += $env:CONTEST_LIB_DIR }
  foreach ($LibModule in @('core-primitives.ps1', 'browser-policies.ps1'))
  {
    $LibSource = $null
    foreach ($LibCandDir in $LibSearchDirs)
    {
      $CandFile = Join-Path $LibCandDir $LibModule
      if (Test-Path -LiteralPath $CandFile)
      {
        $LibSource = $CandFile
        break
      }
    }
    if ($null -ne $LibSource)
    {
      foreach ($DestBaseDir in @($BlockDir, $AltHoldDir, $Root))
      {
        $DestLibDir = Join-Path $DestBaseDir 'lib'
        New-Item -ItemType Directory -Force -Path $DestLibDir -ErrorAction SilentlyContinue | Out-Null
        $DestLibFile = Join-Path $DestLibDir $LibModule
        if ([IO.Path]::GetFullPath($LibSource) -ine [IO.Path]::GetFullPath($DestLibFile))
        {
          Copy-Item -LiteralPath $LibSource -Destination $DestLibFile -Force -ErrorAction SilentlyContinue
        }
      }
    }
  }
}

function Get-RestoreTime
{
  if (-not [string]::IsNullOrWhiteSpace($Until))
  {
    return (ConvertTo-LocalScheduleTime -Text $Until)
  }

  $ExplicitDuration = ($null -ne $Script:ScriptBoundParameters) -and $Script:ScriptBoundParameters.ContainsKey('DurationHours')
  if ($ExplicitDuration)
  {
    if ($DurationHours -lt 1) { throw '-DurationHours must be at least 1.' }
    return (Get-Date).AddHours($DurationHours)
  }
  if ($DurationHours -ge 1)
  {
    return (Get-Date).AddHours($DurationHours)
  }

  $DefaultExamEnd = ConvertTo-LocalScheduleTime -Text $DefaultExamEndKstIso
  if ((Get-Date).AddMinutes(2) -lt $DefaultExamEnd)
  {
    return $DefaultExamEnd
  }
  $FallbackHours = if (Get-Variable -Name 'DefaultBlockDurationHours' -ErrorAction SilentlyContinue) { [int]$DefaultBlockDurationHours } else { 5 }
  return (Get-Date).AddHours($FallbackHours)
}

function Register-AutoRestore
{
  param([datetime]$PlannedRestoreTime = [datetime]::MinValue)

  Copy-SelfToStablePath
  if ($NoSchedule)
  {
    Write-Host 'Auto-restore schedule skipped by -NoSchedule.' -ForegroundColor Yellow
    return
  }

  $RestoreTime = if ($PlannedRestoreTime -ne [datetime]::MinValue) { $PlannedRestoreTime } else { Get-RestoreTime }
  if ($RestoreTime -le (Get-Date).AddMinutes(1))
  {
    throw 'Restore time must be at least 1 minute in the future.'
  }

  $Ps = Get-PreferredPowerShell
  $ArgList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $StableScriptPath, '-Restore', '-Root', $Root)
  if ($SkipBrowserPolicy) { $ArgList += '-SkipBrowserPolicy' }
  $TaskArgs = ($ArgList | ForEach-Object { Quote-ProcessArgument $_ }) -join ' '

  $Action = New-ScheduledTaskAction -Execute $Ps -Argument $TaskArgs
  $Trigger = New-ScheduledTaskTrigger -Once -At $RestoreTime
  $Settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -WakeToRun `
    -ExecutionTimeLimit (New-TimeSpan -Hours 1)

  $Registered = $false
  try
  {
    $SystemPrincipal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Principal $SystemPrincipal -Settings $Settings -Force | Out-Null
    $Registered = $true
  }
  catch
  {
    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $CurrentSid = if ($Identity -and $Identity.User) { $Identity.User.Value } else { '' }
    if ($CurrentSid -ne 'S-1-5-18')
    {
      $FallbackPrincipal = New-ScheduledTaskPrincipal -UserId $Identity.Name -LogonType Interactive -RunLevel Highest
      Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Principal $FallbackPrincipal -Settings $Settings -Force | Out-Null
      $Registered = $true
    }
    else
    {
      throw
    }
  }

  if ($Registered)
  {
    Write-Host "Auto-restore scheduled: $RestoreTime" -ForegroundColor Green
    Write-Host "Task name: $TaskName"
  }
}

function Unregister-AutoRestore
{
  try { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue } catch {}
  try { schtasks.exe /Delete /TN $TaskName /F 2>$null | Out-Null } catch {}
}

function Apply-AiHostsBlock
{
  if (-not [string]::IsNullOrWhiteSpace($NotAfter))
  {
    $NotAfterLocal = ConvertTo-LocalScheduleTime -Text $NotAfter
    if ((Get-Date) -ge $NotAfterLocal)
    {
      Write-Warning ("Skipping AI hosts block because current time ({0}) is at or past -NotAfter ({1})." -f ([DateTimeOffset]::Now.ToString('o')), $NotAfter)
      return
    }
  }

  # Validate auto-restore schedule BEFORE mutating hosts or browser policies
  $PlannedRestoreTime = [datetime]::MinValue
  if (-not $NoSchedule)
  {
    $PlannedRestoreTime = Get-RestoreTime
    if ($PlannedRestoreTime -le (Get-Date).AddMinutes(1))
    {
      throw 'Restore time must be at least 1 minute in the future.'
    }
  }

  Write-Section 'Apply AI hosts block (IPv4 + IPv6 + www + Browser DoH Policy)'
  New-Item -ItemType Directory -Force -Path $BlockDir, $AltHoldDir, $LogDir | Out-Null
  Copy-SelfToStablePath
  if (-not (Test-Path -LiteralPath $HostsPath)) { throw "hosts file not found: $HostsPath" }

  $CurrentHosts = Read-TextUtf8 -Path $HostsPath
  $AlreadyApplied = ($CurrentHosts -like "*$BeginMarker*") -and ($CurrentHosts -like "*$EndMarker*")
  if (-not (Test-Path -LiteralPath $BackupPath))
  {
    Copy-Item -LiteralPath $HostsPath -Destination $BackupPath -Force
    Write-Host "Backup created: $BackupPath" -ForegroundColor Green
  }
  elseif (-not $AlreadyApplied)
  {
    Copy-Item -LiteralPath $HostsPath -Destination (Join-Path $BlockDir "hosts.before-ai-block.$TimeStamp.bak") -Force
  }
  else
  {
    Write-Host 'Original hosts backup already exists. Skipping duplicate backup.' -ForegroundColor Gray
  }

  $Domains = @(Get-BlockDomains)
  if ($Domains.Count -eq 0) { throw 'No AI domains were parsed from the blocklist.' }
  Write-LinesUtf8NoBom -Path $ParsedListPath -Lines ([string[]]$Domains)

  $BaseHosts = Remove-ManagedHostsSectionFromText -HostsText $CurrentHosts
  $BlockLines = New-Object System.Collections.Generic.List[string]
  $BlockLines.Add($BeginMarker) | Out-Null
  $BlockLines.Add("# Applied: $([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture))") | Out-Null
  $BlockLines.Add("# Restore: powershell -ExecutionPolicy Bypass -File `"$StableScriptPath`" -Restore") | Out-Null
  foreach ($Domain in $Domains)
  {
    $BlockLines.Add("0.0.0.0 $Domain") | Out-Null
    $BlockLines.Add(":: $Domain") | Out-Null
  }
  $BlockLines.Add($EndMarker) | Out-Null

  $NewHostsContent = if ([string]::IsNullOrWhiteSpace($BaseHosts)) {
    ($BlockLines.ToArray() -join "`r`n") + "`r`n"
  } else {
    $BaseHosts + "`r`n" + ($BlockLines.ToArray() -join "`r`n") + "`r`n"
  }

  Write-HostsFileWithRetry -Path $HostsPath -Content $NewHostsContent
  $PostWriteHosts = Read-TextUtf8 -Path $HostsPath
  if ((-not ($PostWriteHosts -like "*$BeginMarker*")) -or (-not ($PostWriteHosts -like "*$EndMarker*")))
  {
    Write-Warning 'Post-write hosts verification detected missing blocklist markers (possible AV/Defender HostsFileHijack interference); retrying write...'
    Start-Sleep -Milliseconds 300
    Write-HostsFileWithRetry -Path $HostsPath -Content $NewHostsContent
    $PostWriteHosts = Read-TextUtf8 -Path $HostsPath
    if ((-not ($PostWriteHosts -like "*$BeginMarker*")) -or (-not ($PostWriteHosts -like "*$EndMarker*")))
    {
      throw "Post-write hosts verification failed: '$HostsPath' does not contain managed AI blocklist markers after write (possible antivirus/Defender interference)."
    }
  }
  Set-ContestBrowserPolicies
  Invoke-DnsCacheFlush

  try
  {
    Register-AutoRestore -PlannedRestoreTime $PlannedRestoreTime
  }
  catch
  {
    $RevertContent = if ([string]::IsNullOrWhiteSpace($BaseHosts)) { "`r`n" } else { $BaseHosts + "`r`n" }
    try { Write-HostsFileWithRetry -Path $HostsPath -Content $RevertContent } catch {}
    try { Restore-ContestBrowserPolicies } catch {}
    Invoke-DnsCacheFlush
    throw
  }

  Write-Host "AI hosts block applied (IPv4 + IPv6). Domains blocked: $($Domains.Count)" -ForegroundColor Green
}

function Restore-AiHostsBlock
{
  Write-Section 'Restore AI hosts block'
  if (Test-Path -LiteralPath $HostsPath)
  {
    $CurrentHosts = Read-TextUtf8 -Path $HostsPath
    $RestoredHosts = Remove-ManagedHostsSectionFromText -HostsText $CurrentHosts
    $FinalContent = if ([string]::IsNullOrWhiteSpace($RestoredHosts)) { "`r`n" } else { $RestoredHosts + "`r`n" }
    Write-HostsFileWithRetry -Path $HostsPath -Content $FinalContent
  }
  Restore-ContestBrowserPolicies
  Invoke-DnsCacheFlush
  Unregister-AutoRestore
  Write-Host 'AI hosts block removed.' -ForegroundColor Green
}

Ensure-Admin

$AiMutex = $null
$AiMutexAcquired = $false
$MutexHeld = $false
try
{
  try
  {
    $AiMutex = New-Object System.Threading.Mutex($false, 'Global\ContestSetupEnvironmentMutex')
    $OwnerPid = 0
    $ParentHoldsMutex = $false
    if ((-not [string]::IsNullOrWhiteSpace($env:CONTEST_MUTEX_OWNER_PID)) -and [int]::TryParse($env:CONTEST_MUTEX_OWNER_PID.Trim(), [ref]$OwnerPid))
    {
      if ($OwnerPid -gt 0 -and $OwnerPid -ne $PID -and ($null -ne (Get-Process -Id $OwnerPid -ErrorAction SilentlyContinue)))
      {
        $ParentHoldsMutex = $true
      }
    }

    if ($ParentHoldsMutex)
    {
      Write-Host "Parent ContestSetup process (PID $OwnerPid) already holds Global\ContestSetupEnvironmentMutex; skipping mutex wait." -ForegroundColor Gray
      $AiMutexAcquired = $false
      $MutexHeld = $false
      try { $AiMutex.Dispose() } catch {}
      $AiMutex = $null
    }
    else
    {
      try
      {
        $AiMutexAcquired = $AiMutex.WaitOne([TimeSpan]::FromSeconds(60))
      }
      catch [System.Threading.AbandonedMutexException]
      {
        $AiMutexAcquired = $true
      }
      $MutexHeld = $AiMutexAcquired
      if (-not $AiMutexAcquired)
      {
        try { $AiMutex.Dispose() } catch {}
        $AiMutex = $null
      }
    }
  }
  catch
  {
    if ($null -ne $AiMutex)
    {
      try { $AiMutex.Dispose() } catch {}
    }
    $AiMutex = $null
    $AiMutexAcquired = $false
    $MutexHeld = $false
  }

  if ($Restore)
  {
    Restore-AiHostsBlock
  }
  else
  {
    Apply-AiHostsBlock
  }
}
catch
{
  Write-Host ''
  Write-Host 'FATAL ERROR' -ForegroundColor Red
  Write-Host $_.Exception.Message -ForegroundColor Red
  exit 1
}
finally
{
  if ($null -ne $AiMutex)
  {
    if ($AiMutexAcquired)
    {
      try { $AiMutex.ReleaseMutex() } catch {}
    }
    try { $AiMutex.Dispose() } catch {}
  }
}
