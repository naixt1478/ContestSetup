# lib/core-primitives.ps1
# Core UTF-8/JSONC I/O, process quoting, privilege/runtime detection, and path boundary primitives

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
try { $global:PSNativeCommandUseErrorActionPreference = $false } catch {}

function Write-Section
{
  param([Parameter(Mandatory = $true)] [string]$Message)
  Write-Host ''
  Write-Host '============================================================' -ForegroundColor Cyan
  Write-Host $Message -ForegroundColor Cyan
  Write-Host '============================================================' -ForegroundColor Cyan
}

function Test-CommandExists
{
  param([Parameter(Mandatory = $true)] [string]$Command)
  return $null -ne (Get-Command $Command -ErrorAction SilentlyContinue)
}

function Test-IsAdmin
{
  try
  {
    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $Principal = New-Object Security.Principal.WindowsPrincipal($Identity)
    return $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  }
  catch
  {
    return $false
  }
}

function Get-PreferredPowerShell
{
  if (-not [string]::IsNullOrWhiteSpace($env:SystemRoot))
  {
    $WinPs = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $WinPs) { return $WinPs }
  }
  $PwshCandidates = @(Get-Command pwsh.exe -All -ErrorAction SilentlyContinue)
  foreach ($Candidate in $PwshCandidates)
  {
    if ($Candidate -and $Candidate.Source -and ($Candidate.Source -notmatch '\\WindowsApps\\pwsh\.exe$'))
    {
      return $Candidate.Source
    }
  }
  $UnixPwsh = @(Get-Command pwsh -All -ErrorAction SilentlyContinue)
  foreach ($Candidate in $UnixPwsh)
  {
    if ($Candidate -and $Candidate.Source)
    {
      return $Candidate.Source
    }
  }
  if (-not [string]::IsNullOrWhiteSpace($env:SystemRoot))
  {
    return (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
  }
  return 'powershell.exe'
}

function Quote-ProcessArgument
{
  param([AllowNull()] [object]$Value)
  if ($null -eq $Value) { return '""' }
  $Text = [string]$Value
  if ([string]::IsNullOrEmpty($Text)) { return '""' }
  if ($Text -notmatch '[\s"]') { return $Text }
  $Escaped = $Text -replace '(\\*)"', '$1$1\"'
  $Escaped = $Escaped -replace '(\\+)$', '$1$1'
  return '"' + $Escaped + '"'
}

function Write-TextUtf8NoBom
{
  param(
    [Parameter(Mandatory = $true)] [string]$Path,
    [Parameter(Mandatory = $true)] [AllowEmptyString()] [string]$Content
  )
  $Directory = [IO.Path]::GetDirectoryName($Path)
  if (-not [string]::IsNullOrWhiteSpace($Directory))
  {
    New-Item -ItemType Directory -Force -Path $Directory | Out-Null
  }
  $Encoding = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Content, $Encoding)
}

function Write-LinesUtf8NoBom
{
  param(
    [Parameter(Mandatory = $true)] [string]$Path,
    [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [AllowEmptyString()] [string[]]$Lines
  )
  $Content = ($Lines -join [Environment]::NewLine) + [Environment]::NewLine
  Write-TextUtf8NoBom -Path $Path -Content $Content
}

function Write-JsonUtf8NoBom
{
  param(
    [Parameter(Mandatory = $true)] [string]$Path,
    [Parameter(Mandatory = $true)] [AllowNull()] [AllowEmptyCollection()] [object]$InputObject,
    [int]$Depth = 30
  )
  # Use -InputObject instead of pipeline so 0-element and 1-element arrays are preserved
  $Json = ConvertTo-Json -InputObject $InputObject -Depth $Depth
  if ([string]::IsNullOrWhiteSpace($Json))
  {
    if (($InputObject -is [System.Collections.IEnumerable]) -and -not ($InputObject -is [string]) -and -not ($InputObject -is [System.Collections.IDictionary]))
    {
      $Json = '[]'
    }
    elseif ($null -eq $InputObject)
    {
      $Json = '[]'
    }
  }
  Write-TextUtf8NoBom -Path $Path -Content ($Json + [Environment]::NewLine)
}

function Read-TextUtf8
{
  param([Parameter(Mandatory = $true)] [string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return '' }
  return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

function Read-LinesUtf8
{
  param([Parameter(Mandatory = $true)] [string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return @() }
  return @([System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8))
}

function Strip-JsonComments
{
  param(
    [AllowNull()] [AllowEmptyString()] [string]$Json
  )
  if ([string]::IsNullOrWhiteSpace($Json)) { return '' }
  $Text = $Json.TrimStart([char]0xFEFF, ' ', "`t", "`r", "`n")
  if ([string]::IsNullOrWhiteSpace($Text)) { return '' }

  # Pass 1: strip // and /* */ comments outside double-quoted JSON strings
  $NoCommentsBuilder = New-Object System.Text.StringBuilder ($Text.Length)
  $InString = $false
  $Idx = 0
  $Len = $Text.Length
  while ($Idx -lt $Len)
  {
    $Ch = $Text[$Idx]
    if ($InString)
    {
      [void]$NoCommentsBuilder.Append($Ch)
      if ($Ch -eq '\' -and ($Idx + 1) -lt $Len)
      {
        [void]$NoCommentsBuilder.Append($Text[$Idx + 1])
        $Idx += 2
        continue
      }
      if ($Ch -eq '"')
      {
        $InString = $false
      }
      $Idx++
      continue
    }

    if ($Ch -eq '"')
    {
      $InString = $true
      [void]$NoCommentsBuilder.Append($Ch)
      $Idx++
      continue
    }

    if ($Ch -eq '/' -and ($Idx + 1) -lt $Len -and $Text[$Idx + 1] -eq '/')
    {
      $Idx += 2
      while ($Idx -lt $Len -and $Text[$Idx] -ne "`n" -and $Text[$Idx] -ne "`r")
      {
        $Idx++
      }
      continue
    }

    if ($Ch -eq '/' -and ($Idx + 1) -lt $Len -and $Text[$Idx + 1] -eq '*')
    {
      $Idx += 2
      while ($Idx -lt $Len)
      {
        if ($Text[$Idx] -eq '*' -and ($Idx + 1) -lt $Len -and $Text[$Idx + 1] -eq '/')
        {
          $Idx += 2
          break
        }
        $Idx++
      }
      continue
    }

    [void]$NoCommentsBuilder.Append($Ch)
    $Idx++
  }

  # Pass 2: strip trailing commas before closing object or array delimiters outside double-quoted JSON strings
  $Pass1 = $NoCommentsBuilder.ToString()
  $CleanBuilder = New-Object System.Text.StringBuilder ($Pass1.Length)
  $InString = $false
  $Idx = 0
  $Len = $Pass1.Length
  while ($Idx -lt $Len)
  {
    $Ch = $Pass1[$Idx]
    if ($InString)
    {
      [void]$CleanBuilder.Append($Ch)
      if ($Ch -eq '\' -and ($Idx + 1) -lt $Len)
      {
        [void]$CleanBuilder.Append($Pass1[$Idx + 1])
        $Idx += 2
        continue
      }
      if ($Ch -eq '"')
      {
        $InString = $false
      }
      $Idx++
      continue
    }

    if ($Ch -eq '"')
    {
      $InString = $true
      [void]$CleanBuilder.Append($Ch)
      $Idx++
      continue
    }

    if ($Ch -eq ',')
    {
      $LookAhead = $Idx + 1
      while ($LookAhead -lt $Len -and ($Pass1[$LookAhead] -eq ' ' -or $Pass1[$LookAhead] -eq "`t" -or $Pass1[$LookAhead] -eq "`r" -or $Pass1[$LookAhead] -eq "`n"))
      {
        $LookAhead++
      }
      if ($LookAhead -lt $Len -and ($Pass1[$LookAhead] -eq ([char]125) -or $Pass1[$LookAhead] -eq ']'))
      {
        $Idx++
        continue
      }
    }

    [void]$CleanBuilder.Append($Ch)
    $Idx++
  }

  return $CleanBuilder.ToString().Trim()
}

function ConvertFrom-JsonSafe
{
  param(
    [Parameter(Mandatory = $true)] [AllowNull()] [AllowEmptyString()] [string]$Json
  )
  $CleanJson = Strip-JsonComments -Json $Json
  if ([string]::IsNullOrWhiteSpace($CleanJson)) { return $null }
  return (ConvertFrom-Json -InputObject $CleanJson -ErrorAction Stop)
}

function ConvertFrom-JsonArray
{
  param(
    [Parameter(Mandatory = $true)] [AllowNull()] [AllowEmptyString()] [string]$Json
  )
  if ([string]::IsNullOrWhiteSpace($Json)) { return @() }
  $Parsed = ConvertFrom-JsonSafe -Json $Json
  if ($null -eq $Parsed) { return @() }
  if ($Parsed -is [System.Array]) { return $Parsed }
  return @($Parsed)
}

function Set-ObjectProperty
{
  param(
    [Parameter(Mandatory = $true)] [object]$Object,
    [Parameter(Mandatory = $true)] [string]$Name,
    [AllowNull()] [object]$Value
  )
  $ExistingProp = $Object.PSObject.Properties[$Name]
  if ($null -ne $ExistingProp)
  {
    $ExistingProp.Value = $Value
  }
  else
  {
    Add-Member -InputObject $Object -MemberType NoteProperty -Name $Name -Value $Value -Force
  }
}

function Resolve-VSCodeProductJsonPath
{
  param(
    [AllowNull()] [AllowEmptyString()] [string]$VSCodeRoot
  )
  if ([string]::IsNullOrWhiteSpace($VSCodeRoot) -or (-not (Test-Path -LiteralPath $VSCodeRoot)))
  {
    return $null
  }

  # 1. Legacy flat win32-x64-archive layout: vscode\resources\app\product.json
  $LegacyFlat = Join-Path $VSCodeRoot 'resources\app\product.json'
  if (Test-Path -LiteralPath $LegacyFlat)
  {
    return $LegacyFlat
  }

  # 2. Active versioned subdir referenced inside vscode\bin\code.cmd (<commit>\resources\app\out\cli.js)
  $CodeCmdFile = Join-Path $VSCodeRoot 'bin\code.cmd'
  if (Test-Path -LiteralPath $CodeCmdFile)
  {
    try
    {
      $CmdText = Read-TextUtf8 -Path $CodeCmdFile
      if (-not [string]::IsNullOrWhiteSpace($CmdText))
      {
        $CliMatch = [regex]::Match($CmdText, '(?i)(?:%~dp0\.\.[\\/])?([A-Za-z0-9._-]+)[\\/]resources[\\/]app[\\/]out[\\/]cli\.js')
        if ($CliMatch.Success)
        {
          $RefSubDir = $CliMatch.Groups[1].Value
          $RefProductJson = Join-Path (Join-Path $VSCodeRoot $RefSubDir) 'resources\app\product.json'
          if (Test-Path -LiteralPath $RefProductJson)
          {
            return $RefProductJson
          }
        }
      }
    }
    catch {}
  }

  # 3. Scan immediate child directories sorted by LastWriteTime descending (excluding non-version folders)
  $ExcludedChildNames = @('data', 'bin', 'tools', 'policies', 'appx')
  $ChildDirs = @(Get-ChildItem -LiteralPath $VSCodeRoot -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
  foreach ($ChildDir in $ChildDirs)
  {
    if ($ExcludedChildNames -contains $ChildDir.Name.ToLowerInvariant())
    {
      continue
    }
    $CandidateProductJson = Join-Path $ChildDir.FullName 'resources\app\product.json'
    if (Test-Path -LiteralPath $CandidateProductJson)
    {
      return $CandidateProductJson
    }
  }

  # 4. Root fallback: vscode\product.json
  $RootProductJson = Join-Path $VSCodeRoot 'product.json'
  if (Test-Path -LiteralPath $RootProductJson)
  {
    return $RootProductJson
  }

  return $null
}

function Test-PathInside
{
  param(
    [AllowNull()] [AllowEmptyString()] [string]$ChildPath,
    [AllowNull()] [AllowEmptyString()] [string]$ParentPath
  )
  if ([string]::IsNullOrWhiteSpace($ChildPath) -or [string]::IsNullOrWhiteSpace($ParentPath))
  {
    return $false
  }
  $Sep = [System.IO.Path]::DirectorySeparatorChar
  $ChildCandidate = $ChildPath.Trim()
  $ParentCandidate = $ParentPath.Trim()
  try
  {
    if ([System.IO.Path]::IsPathRooted($ChildCandidate))
    {
      $ChildCandidate = [System.IO.Path]::GetFullPath($ChildCandidate)
    }
  }
  catch {}
  try
  {
    if ([System.IO.Path]::IsPathRooted($ParentCandidate))
    {
      $ParentCandidate = [System.IO.Path]::GetFullPath($ParentCandidate)
    }
  }
  catch {}
  $Child = ($ChildCandidate -replace [regex]::Escape([string]$Sep), '\' -replace '/', '\').TrimEnd('\')
  $Parent = ($ParentCandidate -replace [regex]::Escape([string]$Sep), '\' -replace '/', '\').TrimEnd('\')
  if ([string]::IsNullOrWhiteSpace($Child) -or [string]::IsNullOrWhiteSpace($Parent))
  {
    return $false
  }
  return ($Child -ieq $Parent) -or $Child.StartsWith("$Parent\", [System.StringComparison]::OrdinalIgnoreCase)
}

function Convert-ToForwardSlashPath
{
  param([Parameter(Mandatory = $true)] [string]$Path)
  return ($Path -replace '\\', '/')
}

function Normalize-PathForCompare
{
  param([Parameter(Mandatory = $true)] [string]$Path)
  return ($Path -replace '/', '\').Trim().TrimEnd('\').ToLowerInvariant()
}
