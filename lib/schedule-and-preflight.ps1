# lib/schedule-and-preflight.ps1
# KST (+09:00) schedule parsing, clock-skew probe, stale hosts cleanup, and pre-flight validation

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
try { $global:PSNativeCommandUseErrorActionPreference = $false } catch {}

function ConvertTo-KstDateTimeOffset
{
  param(
    [Parameter(Mandatory = $true)] [string]$TimestampText,
    [Parameter(Mandatory = $true)] [string]$FieldName
  )
  $Trimmed = $TimestampText.Trim()
  if ([string]::IsNullOrWhiteSpace($Trimmed))
  {
    throw "Invalid $FieldName timestamp format: '$TimestampText'. Expected ISO-8601 format such as '2026-11-23T19:00:00'."
  }
  $HasExplicitOffset = ($Trimmed -match '(?i)(Z|[+-]\d{2}:?\d{2})$')
  $NormalizedIso = if ($HasExplicitOffset) { $Trimmed } else { "$Trimmed+09:00" }
  try
  {
    return [DateTimeOffset]::Parse($NormalizedIso, [System.Globalization.CultureInfo]::InvariantCulture)
  }
  catch
  {
    throw "Invalid $FieldName timestamp format: '$TimestampText'. Expected ISO-8601 format such as '2026-11-23T19:00:00'."
  }
}

function Test-ExamScheduleConfiguration
{
  param(
    [Alias('ExamStartText')]
    [string]$StartText = $ExamStart,
    [Alias('ExamEndText')]
    [string]$EndText = $ExamEnd,
    [Alias('RestoreAtText')]
    [string]$RestoreText = $RestoreAt
  )
  $StartDto = ConvertTo-KstDateTimeOffset -TimestampText $StartText -FieldName 'ExamStart'
  $EndDto = ConvertTo-KstDateTimeOffset -TimestampText $EndText -FieldName 'ExamEnd'
  $RestoreDto = ConvertTo-KstDateTimeOffset -TimestampText $RestoreText -FieldName 'RestoreAt'

  $ParsedStart = $StartDto.LocalDateTime
  $ParsedEnd = $EndDto.LocalDateTime
  $ParsedRestore = $RestoreDto.LocalDateTime

  if ($EndDto -le $StartDto)
  {
    throw "Invalid exam window: ExamEnd ($($EndDto.ToString('o'))) must be later than ExamStart ($($StartDto.ToString('o')))."
  }

  $IsKst = $true
  try
  {
    $Tz = Get-TimeZone -ErrorAction Stop
    $IsKst = ($Tz.BaseUtcOffset -eq [TimeSpan]::FromHours(9))
    if (-not $IsKst)
    {
      Write-Warning "System timezone is '$($Tz.Id)' (UTC offset $($Tz.BaseUtcOffset)), not Korea Standard Time (UTC+09:00). KST (+09:00) schedule converted to local trigger time $($ParsedRestore.ToString('yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture))."
    }
  }
  catch {}

  $KstStart = $StartDto.ToOffset([TimeSpan]::FromHours(9))
  $IsMonday = ($KstStart.DayOfWeek -eq [System.DayOfWeek]::Monday)
  if ($KstStart.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture) -eq '2026-11-23' -and -not $IsMonday)
  {
    Write-Warning "Unexpected day of week for 2026-11-23: $($KstStart.DayOfWeek)"
  }

  $NowDto = [DateTimeOffset]::Now
  $IsPastRestoreTime = ($NowDto -ge $RestoreDto)
  $IsBeforeExamStart = ($NowDto -lt $StartDto)

  return [pscustomobject]@{
    ExamStart         = $ParsedStart
    ExamEnd           = $ParsedEnd
    RestoreAt         = $ParsedRestore
    ExamStartDto      = $StartDto
    ExamEndDto        = $EndDto
    RestoreAtDto      = $RestoreDto
    ExamStartIso      = $StartDto.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
    ExamEndIso        = $EndDto.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
    RestoreAtIso      = $RestoreDto.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
    ExamDuration      = ($EndDto - $StartDto)
    DurationMinutes   = [math]::Round(($EndDto - $StartDto).TotalMinutes, 1)
    DayOfWeek         = $KstStart.DayOfWeek.ToString()
    IsKst             = $IsKst
    IsKstZone         = $IsKst
    IsMonday          = $IsMonday
    IsPastRestoreTime = $IsPastRestoreTime
    IsBeforeExamStart = $IsBeforeExamStart
  }
}

function Clear-StaleAiHostsSectionBeforeInstall
{
  if ([string]::IsNullOrWhiteSpace($env:SystemRoot)) { return }
  $HostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
  if (-not (Test-Path -LiteralPath $HostsPath)) { return }
  $BeginMarker = '# >>> CP_CONTEST_AI_BLOCKLIST_BEGIN'
  $EndMarker = '# <<< CP_CONTEST_AI_BLOCKLIST_END'
  try
  {
    $CurrentHosts = Read-TextUtf8 -Path $HostsPath
    if ($null -ne $CurrentHosts -and $CurrentHosts -like "*$BeginMarker*" -and $CurrentHosts -like "*$EndMarker*")
    {
      Write-Host 'Detected active AI blocklist in hosts file from a prior run. Temporarily clearing during setup downloads...' -ForegroundColor Yellow
      $Pattern = "(?s)\r?\n?" + [regex]::Escape($BeginMarker) + '.*?' + [regex]::Escape($EndMarker) + "\r?\n?"
      $Cleaned = ([regex]::Replace($CurrentHosts, $Pattern, "`r`n")).TrimEnd()
      $HostItem = Get-Item -LiteralPath $HostsPath -Force -ErrorAction SilentlyContinue
      if ($HostItem -and ($HostItem.Attributes -band [IO.FileAttributes]::ReadOnly))
      {
        $HostItem.Attributes = $HostItem.Attributes -bxor [IO.FileAttributes]::ReadOnly
      }
      Write-TextUtf8NoBom -Path $HostsPath -Content ($Cleaned + "`r`n")
      try { ipconfig.exe /flushdns | Out-Null } catch {}
    }
  }
  catch
  {
    Write-Warning "Could not clear existing AI hosts section prior to install: $($_.Exception.Message)"
  }
}

function Test-SystemClockSkewHttps
{
  param([int]$TimeoutSeconds = 3)
  try
  {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
    Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
    $Handler = New-Object System.Net.Http.HttpClientHandler
    $Handler.AllowAutoRedirect = $true
    $Client = New-Object System.Net.Http.HttpClient($Handler)
    $Client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
    try
    {
      $Req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Head, 'https://www.microsoft.com')
      $Resp = $Client.SendAsync($Req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
      try
      {
        if ($null -ne $Resp.Headers.Date)
        {
          $ServerUtc = [DateTimeOffset]$Resp.Headers.Date.Value
          $LocalUtc = [DateTimeOffset]::UtcNow
          $SkewMinutes = [math]::Round(($LocalUtc - $ServerUtc).TotalMinutes, 1)
          if ([math]::Abs($SkewMinutes) -gt 5.0)
          {
            Write-Warning "System clock skew detected: local UTC differs from HTTPS Date header by $SkewMinutes minutes (> 5 min threshold). Attempting non-blocking clock resync..."
            if (Test-IsAdmin)
            {
              try { & w32tm.exe /resync /nowait 2>$null | Out-Null } catch {}
            }
          }
          else
          {
            Write-Host ("Clock Sync   : Verified within {0} min of HTTPS UTC reference" -f [math]::Abs($SkewMinutes)) -ForegroundColor Green
          }
        }
      }
      finally
      {
        if ($Resp) { $Resp.Dispose() }
        if ($Req) { $Req.Dispose() }
      }
    }
    finally
    {
      if ($Client) { $Client.Dispose() }
      if ($Handler) { $Handler.Dispose() }
    }
  }
  catch
  {
    # Non-blocking best-effort check (offline/USB environments continue seamlessly)
  }
}

function Invoke-PreflightChecks
{
  param([switch]$DryRunOnly)
  Write-Section 'Pre-flight System & Schedule Checks'

  if (-not [Environment]::Is64BitOperatingSystem)
  {
    throw 'ContestSetup v2.0 requires a 64-bit Windows operating system.'
  }
  Write-Host 'Architecture : 64-bit OS verified' -ForegroundColor Green

  if ($MsysRoot -match '\s')
  {
    Write-Warning "MsysRoot ('$MsysRoot') contains spaces. MSYS2/GNU tools strongly recommend a space-free path such as C:\msys64."
  }

  $ScheduleInfo = Test-ExamScheduleConfiguration -StartText $ExamStart -EndText $ExamEnd -RestoreText $RestoreAt
  Write-Host ("Exam Window  : {0} ({1}) ~ {2} ({3} mins)" -f $ScheduleInfo.ExamStart.ToString('yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture), $ScheduleInfo.DayOfWeek, $ScheduleInfo.ExamEnd.ToString('yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture), $ScheduleInfo.DurationMinutes) -ForegroundColor Green
  Write-Host ("Auto Restore : {0} (ISO: {1})" -f $ScheduleInfo.RestoreAt.ToString('yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture), $ScheduleInfo.RestoreAtIso) -ForegroundColor Green

  try
  {
    $RootDrive = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($Root))
    $MsysDrive = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($MsysRoot))
    $MsysInstalled = (Test-Path -LiteralPath $MsysBash)

    if ($RootDrive -ieq $MsysDrive)
    {
      $DriveInfo = New-Object System.IO.DriveInfo($RootDrive)
      $FreeGb = [math]::Round($DriveInfo.AvailableFreeSpace / 1GB, 2)
      $MinRequiredGb = if ($MsysInstalled) { 0.5 } else { 2.5 }
      if ($FreeGb -lt $MinRequiredGb)
      {
        Write-Warning "Low free disk space on $RootDrive ($FreeGb GB available, recommended >= $MinRequiredGb GB)."
      }
      else
      {
        Write-Host "Disk Space   : $FreeGb GB available on $RootDrive" -ForegroundColor Green
      }
    }
    else
    {
      $RootDriveInfo = New-Object System.IO.DriveInfo($RootDrive)
      $RootFreeGb = [math]::Round($RootDriveInfo.AvailableFreeSpace / 1GB, 2)
      $RootMinGb = 0.8
      if ($RootFreeGb -lt $RootMinGb)
      {
        Write-Warning "Low free disk space on Root drive $RootDrive ($RootFreeGb GB available, recommended >= $RootMinGb GB)."
      }
      else
      {
        Write-Host "Disk Space   : $RootFreeGb GB available on Root drive $RootDrive" -ForegroundColor Green
      }

      $MsysDriveInfo = New-Object System.IO.DriveInfo($MsysDrive)
      $MsysFreeGb = [math]::Round($MsysDriveInfo.AvailableFreeSpace / 1GB, 2)
      $MsysMinGb = if ($MsysInstalled) { 0.3 } else { 1.8 }
      if ($MsysFreeGb -lt $MsysMinGb)
      {
        Write-Warning "Low free disk space on MsysRoot drive $MsysDrive ($MsysFreeGb GB available, recommended >= $MsysMinGb GB)."
      }
      else
      {
        Write-Host "Disk Space   : $MsysFreeGb GB available on MsysRoot drive $MsysDrive" -ForegroundColor Green
      }
    }
  }
  catch {}

  Test-SystemClockSkewHttps -TimeoutSeconds 3

  if ((-not $DryRunOnly) -and ($Mode -eq 'Install'))
  {
    Clear-StaleAiHostsSectionBeforeInstall
  }

  return $ScheduleInfo
}
