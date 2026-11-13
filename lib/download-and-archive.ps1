# lib/download-and-archive.ps1
# Fast 3-tier archive extraction, native process invocation, verified downloads, parallel prefetch, and winget helpers

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
try { $global:PSNativeCommandUseErrorActionPreference = $false } catch {}

function Expand-ArchiveFast {
  param(
    [Parameter(Mandatory = $true)] [string]$ArchivePath,
    [Parameter(Mandatory = $true)] [string]$DestinationPath
  )
  if (-not (Test-Path -LiteralPath $ArchivePath)) {
    throw "Archive not found for extraction: $ArchivePath"
  }
  New-Item -ItemType Directory -Force -Path $DestinationPath | Out-Null

  # Tier 1: Explicit Windows System32 bsdtar (never Get-Command 'tar.exe', avoiding MSYS2/Git GNU tar shadowing)
  $SysTar = if (-not [string]::IsNullOrWhiteSpace($env:SystemRoot)) { Join-Path $env:SystemRoot 'System32\tar.exe' } else { '' }
  if (-not [string]::IsNullOrWhiteSpace($SysTar) -and (Test-Path -LiteralPath $SysTar)) {
    try {
      $TarRes = Invoke-NativeCommand -FilePath $SysTar -ArgumentList @('-xf', $ArchivePath, '-C', $DestinationPath) -Quiet
      if ($TarRes.ExitCode -eq 0) {
        return
      }
      Write-Warning "System32 tar.exe exited with code $($TarRes.ExitCode). Falling back to .NET ZipFile extraction..."
    } catch {
      Write-Warning "System32 tar.exe failed ($($_.Exception.Message)). Falling back to .NET ZipFile extraction..."
    }
  }

  # Tier 2: .NET System.IO.Compression.ZipFile::ExtractToDirectory
  try {
    Get-ChildItem -LiteralPath $DestinationPath -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    [System.IO.Compression.ZipFile]::ExtractToDirectory($ArchivePath, $DestinationPath)
    return
  } catch {
    Write-Warning ".NET ZipFile extraction failed ($($_.Exception.Message)). Falling back to silent Expand-Archive..."
  }

  # Tier 3: Clean partial files and run Expand-Archive -LiteralPath with silenced progress bar
  $OldProgressPref = $ProgressPreference
  try {
    Get-ChildItem -LiteralPath $DestinationPath -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    $ProgressPreference = 'SilentlyContinue'
    Expand-Archive -LiteralPath $ArchivePath -DestinationPath $DestinationPath -Force
  } finally {
    $ProgressPreference = $OldProgressPref
  }
}

function Invoke-NativeCommand {
  param(
    [Parameter(Mandatory = $true)] [string]$FilePath,
    [string[]]$ArgumentList = @(),
    [switch]$Quiet,
    [switch]$StreamOutput
  )

  $CmdObj = Get-Command $FilePath -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $CmdObj -and -not (Test-Path -LiteralPath $FilePath)) {
    throw "Native command not found: $FilePath"
  }
  $ResolvedPath = if (Test-Path -LiteralPath $FilePath) { $FilePath } elseif ($CmdObj -and $CmdObj.Source) { $CmdObj.Source } else { $FilePath }
  if (-not $Quiet) { Write-Host ("{0} {1}" -f $FilePath, ($ArgumentList -join ' ')) -ForegroundColor DarkGray }

  $Ext = [IO.Path]::GetExtension($ResolvedPath).ToLowerInvariant()
  if (($Ext -in @('.cmd', '.bat')) -and (-not [string]::IsNullOrWhiteSpace($env:ComSpec)) -and (Test-Path -LiteralPath $env:ComSpec)) {
    # PS 5.1 mangles quotes when & invokes a .cmd/.bat file and both FilePath and arguments contain spaces.
    # Use cmd.exe /d /s /c "<QuotedCmdLine>" via ProcessStartInfo so Win32 CreateProcess receives exact quotes.
    $QuotedParts = @((Quote-ProcessArgument $ResolvedPath))
    foreach ($ArgItem in $ArgumentList) {
      $QuotedParts += (Quote-ProcessArgument $ArgItem)
    }
    $InnerCmdLine = $QuotedParts -join ' '
    $Psi = New-Object System.Diagnostics.ProcessStartInfo
    $Psi.FileName = $env:ComSpec
    $Psi.Arguments = "/d /s /c `"$InnerCmdLine`""
    $Psi.UseShellExecute = $false
    $Psi.CreateNoWindow = $true
    $Psi.RedirectStandardOutput = $true
    $Psi.RedirectStandardError = $true
    try {
      $Psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
      $Psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    } catch {}

    $Proc = [System.Diagnostics.Process]::Start($Psi)
    try {
      $StdOutTask = $Proc.StandardOutput.ReadToEndAsync()
      $StdErrTask = $Proc.StandardError.ReadToEndAsync()
      $Proc.WaitForExit()
      $StdOutText = $StdOutTask.GetAwaiter().GetResult()
      $StdErrText = $StdErrTask.GetAwaiter().GetResult()
      $ExitCode = [int]$Proc.ExitCode
    } finally {
      if ($Proc) { $Proc.Dispose() }
    }

    $CombinedLines = New-Object System.Collections.Generic.List[string]
    foreach ($Chunk in @($StdOutText, $StdErrText)) {
      if (-not [string]::IsNullOrEmpty($Chunk)) {
        foreach ($SplitLine in ($Chunk -split "\r?\n")) {
          if ($SplitLine.Length -gt 0) { $CombinedLines.Add($SplitLine) | Out-Null }
        }
      }
    }
    $Output = $CombinedLines.ToArray()
    if (-not $Quiet) {
      foreach ($Line in $Output) { Write-Host $Line }
    }
    return [pscustomobject]@{ ExitCode = $ExitCode; Output = @($Output) }
  }

  $OldErrorActionPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    if ($StreamOutput -and -not $Quiet) {
      $OutputList = New-Object System.Collections.Generic.List[string]
      & $FilePath @ArgumentList 2>&1 | ForEach-Object {
        if ($null -ne $_) {
          $Line = if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { $_.ToString() }
          $OutputList.Add($Line) | Out-Null
          Write-Host $Line
        }
      }
      $ExitCode = [int]$LASTEXITCODE
      $Output = $OutputList.ToArray()
    } else {
      $RawOutput = & $FilePath @ArgumentList 2>&1
      $ExitCode = [int]$LASTEXITCODE
      $Output = @($RawOutput | ForEach-Object {
        if ($null -ne $_) {
          if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { $_.ToString() }
        }
      })
    }
  } finally {
    $ErrorActionPreference = $OldErrorActionPreference
  }

  if ((-not $Quiet) -and (-not $StreamOutput)) {
    foreach ($Line in $Output) { if ($null -ne $Line) { Write-Host $Line } }
  }
  return [pscustomobject]@{ ExitCode = $ExitCode; Output = @($Output) }
}

function Invoke-NativeChecked {
  param(
    [Parameter(Mandatory = $true)] [string]$FilePath,
    [string[]]$ArgumentList = @(),
    [int[]]$SuccessExitCodes = @(0),
    [switch]$Quiet,
    [switch]$StreamOutput
  )
  $Result = Invoke-NativeCommand -FilePath $FilePath -ArgumentList $ArgumentList -Quiet:$Quiet -StreamOutput:$StreamOutput
  if ($SuccessExitCodes -notcontains $Result.ExitCode) {
    $OutputText = ($Result.Output | Where-Object { $null -ne $_ } | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
    $Message = "Native command failed with exit code $($Result.ExitCode): $FilePath $($ArgumentList -join ' ')"
    if (-not [string]::IsNullOrWhiteSpace($OutputText)) {
      $Message += [Environment]::NewLine + [Environment]::NewLine + 'Command output:' + [Environment]::NewLine + $OutputText
    }
    throw $Message
  }
  return $Result
}

function Test-ValidCachedInstallerFile {
  param(
    [Parameter(Mandatory = $true)] [string]$Path,
    [long]$MinBytes = 10485760
  )
  if (-not (Test-Path -LiteralPath $Path)) { return $false }
  try {
    $Item = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($Item.Length -lt $MinBytes) { return $false }

    $Ext = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    $Stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
      $Header = New-Object byte[] 4
      $ReadCount = $Stream.Read($Header, 0, 4)
      if ($ReadCount -lt 4) { return $false }
      if ($Ext -in @('.zip', '.nupkg', '.vsix')) {
        # PK\x03\x04 magic bytes
        return ($Header[0] -eq 0x50 -and $Header[1] -eq 0x4B -and $Header[2] -eq 0x03 -and $Header[3] -eq 0x04)
      } elseif ($Ext -eq '.exe') {
        # MZ magic bytes
        return ($Header[0] -eq 0x4D -and $Header[1] -eq 0x5A)
      }
      return $true
    } finally {
      $Stream.Dispose()
    }
  } catch {
    return $false
  }
}

function Copy-FromCacheDirIfPresent {
  param([Parameter(Mandatory = $true)] [string]$OutFile, [long]$MinBytes = 1024)
  if ([string]::IsNullOrWhiteSpace($CacheDir)) { return $false }
  if (-not (Test-Path -LiteralPath $CacheDir)) { return $false }
  $LeafName = [IO.Path]::GetFileName($OutFile)
  $SearchRoots = @($CacheDir)
  $InstallersSubDir = Join-Path $CacheDir 'installers'
  if (Test-Path -LiteralPath $InstallersSubDir) { $SearchRoots += $InstallersSubDir }

  $MatchedSource = $null
  foreach ($SearchRoot in $SearchRoots) {
    $ExactCandidate = Join-Path $SearchRoot $LeafName
    if ((Test-Path -LiteralPath $ExactCandidate) -and (Test-ValidCachedInstallerFile -Path $ExactCandidate -MinBytes $MinBytes)) {
      $MatchedSource = $ExactCandidate
      break
    }
  }

  if (-not $MatchedSource) {
    $FallbackGlobs = @()
    if ($LeafName -ieq 'vscode-win32-x64-archive.zip') {
      $FallbackGlobs = @('VSCode-win32-x64*.zip', 'vscode-win32-x64*.zip')
    } elseif ($LeafName -ieq 'msys2-x86_64-latest.exe') {
      $FallbackGlobs = @('msys2-x86_64-*.exe')
    } elseif ($LeafName -imatch '^python-.*-amd64\.exe$') {
      $FallbackGlobs = @("python-$PythonVersion*amd64.exe", "python-$PyMajor.$PyMinor.*-amd64.exe")
    } elseif ($LeafName -imatch '^python-.*-nuget\.zip$') {
      $FallbackGlobs = @("python.$PythonVersion.nupkg", "python-$PythonVersion*nuget.zip", "python.$PyMajor.$PyMinor.*.nupkg")
    }

    foreach ($SearchRoot in $SearchRoots) {
      foreach ($GlobPattern in $FallbackGlobs) {
        $GlobHits = @(Get-ChildItem -Path $SearchRoot -Filter $GlobPattern -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
        foreach ($Hit in $GlobHits) {
          if (Test-ValidCachedInstallerFile -Path $Hit.FullName -MinBytes $MinBytes) {
            $MatchedSource = $Hit.FullName
            break
          }
        }
        if ($MatchedSource) { break }
      }
      if ($MatchedSource) { break }
    }
  }

  if ($MatchedSource) {
    New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($OutFile)) | Out-Null
    if ([IO.Path]::GetFullPath($MatchedSource) -ine [IO.Path]::GetFullPath($OutFile)) {
      Copy-Item -LiteralPath $MatchedSource -Destination $OutFile -Force
      Write-Host "Copied installer from CacheDir: $MatchedSource -> $OutFile" -ForegroundColor Green
    }
    return $true
  }
  return $false
}

function Invoke-DownloadFile {
  param([Parameter(Mandatory = $true)] [string]$Url, [Parameter(Mandatory = $true)] [string]$OutFile, [int]$MaxAttempts = 3)
  New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($OutFile)) | Out-Null
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    [Net.ServicePointManager]::DefaultConnectionLimit = [Math]::Max([Net.ServicePointManager]::DefaultConnectionLimit, 16)
  } catch {}

  if (-not $ForceUpdate -and (Copy-FromCacheDirIfPresent -OutFile $OutFile)) {
    return
  }

  $TempOutFile = "$OutFile.part"
  $LastError = $null
  for ($Attempt = 1; $Attempt -le $MaxAttempts; $Attempt++) {
    try {
      Write-Host "Downloading ($Attempt/$MaxAttempts): $Url"
      if (Test-Path -LiteralPath $TempOutFile) { Remove-Item -LiteralPath $TempOutFile -Force -ErrorAction SilentlyContinue }
      $ExpectedLength = $null
      try {
        $Handler = $null; $Client = $null; $Response = $null; $InputStream = $null; $OutputStream = $null
        Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
        $Handler = New-Object System.Net.Http.HttpClientHandler
        $Handler.AllowAutoRedirect = $true
        $Client = New-Object System.Net.Http.HttpClient($Handler)
        $Client.Timeout = [TimeSpan]::FromMinutes(60)
        try { $Client.DefaultRequestHeaders.UserAgent.ParseAdd('ContestSetup/2.0') } catch {}
        $Response = $Client.GetAsync($Url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        if (-not $Response.IsSuccessStatusCode) { throw "HTTP $([int]$Response.StatusCode) $($Response.ReasonPhrase)" }
        $ExpectedLength = $Response.Content.Headers.ContentLength
        $InputStream = $Response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        try { if ($InputStream.CanTimeout) { $InputStream.ReadTimeout = 120000 } } catch {}
        $OutputStream = [System.IO.File]::Open($TempOutFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
          $Buffer = New-Object byte[] (1024 * 1024)
          while (($BytesRead = $InputStream.Read($Buffer, 0, $Buffer.Length)) -gt 0) { $OutputStream.Write($Buffer, 0, $BytesRead) }
        } finally {
          if ($OutputStream) { $OutputStream.Dispose() }
          if ($InputStream) { $InputStream.Dispose() }
          if ($Response) { $Response.Dispose() }
          if ($Client) { $Client.Dispose() }
          if ($Handler) { $Handler.Dispose() }
        }
      } catch {
        Write-Warning "Fast download path failed. Falling back to Invoke-WebRequest. $($_.Exception.Message)"
        $Params = @{ Uri = $Url; OutFile = $TempOutFile; ErrorAction = 'Stop' }
        if ($PSVersionTable.PSVersion.Major -le 5) { $Params['UseBasicParsing'] = $true }
        $OldProgressPref = $ProgressPreference
        try { $ProgressPreference = 'SilentlyContinue'; Invoke-WebRequest @Params }
        finally { $ProgressPreference = $OldProgressPref }
      }

      if (-not (Test-Path -LiteralPath $TempOutFile)) { throw "Download did not create file: $TempOutFile" }
      $ActualLength = (Get-Item -LiteralPath $TempOutFile).Length
      if ($ActualLength -le 0) { throw "Downloaded file is empty: $TempOutFile" }
      if ($null -ne $ExpectedLength -and $ExpectedLength -gt 0 -and $ActualLength -ne $ExpectedLength) {
        throw "Downloaded file size mismatch for $OutFile (expected $ExpectedLength bytes, actual $ActualLength bytes)."
      }
      Move-Item -LiteralPath $TempOutFile -Destination $OutFile -Force
      if (-not (Test-Path -LiteralPath $OutFile)) { throw "Download did not create file: $OutFile" }
      return
    } catch {
      $LastError = $_
      if (Test-Path -LiteralPath $TempOutFile) { Remove-Item -LiteralPath $TempOutFile -Force -ErrorAction SilentlyContinue }
      if ($Attempt -lt $MaxAttempts) { Write-Warning "Download failed. Retrying... $($_.Exception.Message)"; Start-Sleep -Seconds 2 }
    }
  }
  throw "Download failed after $MaxAttempts attempts: $Url - $($LastError.Exception.Message)"
}

function Assert-FileSha256 {
  param([Parameter(Mandatory = $true)] [string]$Path, [AllowEmptyString()] [string]$ExpectedSha256)
  if ([string]::IsNullOrWhiteSpace($ExpectedSha256)) { return }
  $HashObj = Get-FileHash -LiteralPath $Path -Algorithm SHA256
  $Actual = if ($null -ne $HashObj) { [string]$HashObj.Hash } else { '' }
  if ($Actual -ine $ExpectedSha256) { throw "SHA256 mismatch for $Path. Expected $ExpectedSha256, actual $Actual" }
  Write-Host "SHA256 verified: $Path" -ForegroundColor Green
}

function Assert-AuthenticodeValid {
  param([Parameter(Mandatory = $true)] [string]$Path, [string[]]$AllowedPublisherKeywords = @())
  if ($SkipSignatureCheck) { Write-Warning "Skipping Authenticode check by -SkipSignatureCheck: $Path"; return }
  $Extension = [IO.Path]::GetExtension($Path).ToLowerInvariant()
  if ($Extension -notin @('.exe', '.msi', '.msixbundle', '.appx', '.appxbundle')) { return }
  $Signature = Get-AuthenticodeSignature -LiteralPath $Path
  if ($null -eq $Signature -or $Signature.Status -ne 'Valid') {
    $StatusLabel = if ($null -ne $Signature) { [string]$Signature.Status } else { 'NullSignature' }
    throw "Invalid Authenticode signature: $Path ($StatusLabel)"
  }
  if ($AllowedPublisherKeywords.Count -gt 0) {
    $Subj = if ($null -ne $Signature.SignerCertificate) { [string]$Signature.SignerCertificate.Subject } else { '' }
    $Iss = if ($null -ne $Signature.SignerCertificate) { [string]$Signature.SignerCertificate.Issuer } else { '' }
    $Combined = "$Subj $Iss"
    $Ok = $false
    foreach ($Keyword in $AllowedPublisherKeywords) { if ($Combined -like "*$Keyword*") { $Ok = $true; break } }
    if (-not $Ok) { throw "Unexpected signer for ${Path}: $Subj" }
  }
  Write-Host "Authenticode signature verified: $Path" -ForegroundColor Green
}

function Download-VerifiedFile {
  param(
    [string]$Url,
    [string]$OutFile,
    [string]$ExpectedSha256 = '',
    [string[]]$AllowedPublisherKeywords = @(),
    [switch]$SkipAuthenticodeCheck,
    [long]$MinValidBytes = 10485760
  )
  if (-not $ForceUpdate) {
    Copy-FromCacheDirIfPresent -OutFile $OutFile -MinBytes $MinValidBytes | Out-Null
  }

  $HasValidHeaderAndSize = Test-ValidCachedInstallerFile -Path $OutFile -MinBytes $MinValidBytes
  $CanReuseExisting = (-not $ForceUpdate) -and $HasValidHeaderAndSize

  if ($CanReuseExisting -and (Test-Path -LiteralPath $OutFile) -and ((Get-Item -LiteralPath $OutFile).Length -gt 0)) {
    try {
      if (-not (Test-ValidCachedInstallerFile -Path $OutFile -MinBytes $MinValidBytes)) {
        throw "Cached file header or size validation failed: $OutFile"
      }
      Assert-FileSha256 -Path $OutFile -ExpectedSha256 $ExpectedSha256
      if (-not $SkipAuthenticodeCheck) {
        Assert-AuthenticodeValid -Path $OutFile -AllowedPublisherKeywords $AllowedPublisherKeywords
      }
      Write-Host "Using existing verified download: $OutFile" -ForegroundColor Green
      return
    } catch {
      Write-Warning "Existing download could not be verified. Re-downloading. $($_.Exception.Message)"
      Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
    }
  }

  Invoke-DownloadFile -Url $Url -OutFile $OutFile
  if (-not (Test-ValidCachedInstallerFile -Path $OutFile -MinBytes $MinValidBytes)) {
    Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
    throw "Downloaded file failed binary header or minimum size validation ($MinValidBytes bytes): $OutFile"
  }
  Assert-FileSha256 -Path $OutFile -ExpectedSha256 $ExpectedSha256
  if ($SkipAuthenticodeCheck) {
    Write-Warning "Skipping Authenticode check for this unsigned installer: $OutFile"
  } else {
    Assert-AuthenticodeValid -Path $OutFile -AllowedPublisherKeywords $AllowedPublisherKeywords
  }
}

function Invoke-ParallelDownloadFiles {
  param(
    [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]]$Downloads
  )
  if ($Downloads.Count -eq 0) { return }

  New-Item -ItemType Directory -Force -Path $DownloadDir | Out-Null
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    [Net.ServicePointManager]::DefaultConnectionLimit = [Math]::Max([Net.ServicePointManager]::DefaultConnectionLimit, 16)
  } catch {}

  $Pending = New-Object System.Collections.Generic.List[object]
  foreach ($Item in $Downloads) {
    $OutFile = [string]$Item.OutFile
    $MinBytes = if ($Item.PSObject.Properties['MinBytes'] -and $Item.MinBytes) { [long]$Item.MinBytes } else { 10485760L }
    if (-not $ForceUpdate) {
      Copy-FromCacheDirIfPresent -OutFile $OutFile -MinBytes $MinBytes | Out-Null
      if (Test-ValidCachedInstallerFile -Path $OutFile -MinBytes $MinBytes) {
        Write-Host "Prefetch cache hit: $OutFile" -ForegroundColor Green
        continue
      }
    }
    $Pending.Add($Item) | Out-Null
  }

  if ($Pending.Count -eq 0) {
    Write-Host 'All required installers are already cached locally.' -ForegroundColor Green
    return
  }

  Write-Section ("Parallel Prefetch ({0} installer(s))" -f $Pending.Count)
  Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
  $Handler = New-Object System.Net.Http.HttpClientHandler
  $Handler.AllowAutoRedirect = $true
  $Client = New-Object System.Net.Http.HttpClient($Handler)
  $Client.Timeout = [TimeSpan]::FromMinutes(60)
  try { $Client.DefaultRequestHeaders.UserAgent.ParseAdd('ContestSetup/2.0') } catch {}

  $Tasks = New-Object System.Collections.Generic.List[object]
  try {
    # Phase 1: Issue concurrent HTTP GET requests across distinct origins
    foreach ($Item in $Pending) {
      $Url = [string]$Item.Url
      $OutFile = [string]$Item.OutFile
      $MinBytes = if ($Item.PSObject.Properties['MinBytes'] -and $Item.MinBytes) { [long]$Item.MinBytes } else { 10485760L }
      $TempFile = "$OutFile.part"
      if (Test-Path -LiteralPath $TempFile) { Remove-Item -LiteralPath $TempFile -Force -ErrorAction SilentlyContinue }
      Write-Host "Starting concurrent prefetch: $($Item.Name) ($Url)" -ForegroundColor Cyan
      $HttpTask = $Client.GetAsync($Url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead)
      $Tasks.Add([pscustomobject]@{
        Item = $Item; Url = $Url; OutFile = $OutFile; MinBytes = $MinBytes; TempFile = $TempFile
        HeaderTask = $HttpTask; Response = $null; InStream = $null; OutStream = $null
        CopyTask = $null; ExpectedLen = $null; FailedError = $null
      }) | Out-Null
    }

    # Phase 2: Start asynchronous body stream CopyToAsync for all responses concurrently
    $ActiveCopyTasks = New-Object System.Collections.Generic.List[System.Threading.Tasks.Task]
    foreach ($Entry in $Tasks) {
      try {
        $Response = $Entry.HeaderTask.GetAwaiter().GetResult()
        $Entry.Response = $Response
        if (-not $Response.IsSuccessStatusCode) { throw "HTTP $([int]$Response.StatusCode) $($Response.ReasonPhrase)" }
        $Entry.ExpectedLen = $Response.Content.Headers.ContentLength
        $InStream = $Response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        try { if ($InStream.CanTimeout) { $InStream.ReadTimeout = 120000 } } catch {}
        $Entry.InStream = $InStream
        $OutStream = [System.IO.File]::Open($Entry.TempFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $Entry.OutStream = $OutStream
        $CopyTask = $InStream.CopyToAsync($OutStream, 1048576)
        $Entry.CopyTask = $CopyTask
        $ActiveCopyTasks.Add($CopyTask) | Out-Null
      } catch {
        $Entry.FailedError = $_.Exception.Message
      }
    }

    # Phase 3: Wait concurrently for all active CopyToAsync tasks
    if ($ActiveCopyTasks.Count -gt 0) {
      try { [System.Threading.Tasks.Task]::WhenAll($ActiveCopyTasks.ToArray()).GetAwaiter().GetResult() | Out-Null } catch {}
    }

    # Phase 4: Finalize streams, validate sizes & headers, and sequentially retry any failed download
    foreach ($Entry in $Tasks) {
      try {
        if (-not [string]::IsNullOrWhiteSpace($Entry.FailedError)) { throw $Entry.FailedError }
        if ($null -ne $Entry.CopyTask) { $Entry.CopyTask.GetAwaiter().GetResult() | Out-Null }
        if ($null -ne $Entry.OutStream) { $Entry.OutStream.Flush(); $Entry.OutStream.Dispose(); $Entry.OutStream = $null }

        $ActualLen = (Get-Item -LiteralPath $Entry.TempFile).Length
        if ($null -ne $Entry.ExpectedLen -and $Entry.ExpectedLen -gt 0 -and $ActualLen -ne $Entry.ExpectedLen) {
          throw "Content-Length mismatch (expected $($Entry.ExpectedLen), actual $ActualLen)"
        }
        Move-Item -LiteralPath $Entry.TempFile -Destination $Entry.OutFile -Force
        if (-not (Test-ValidCachedInstallerFile -Path $Entry.OutFile -MinBytes $Entry.MinBytes)) {
          Remove-Item -LiteralPath $Entry.OutFile -Force -ErrorAction SilentlyContinue
          throw "Prefetched file failed binary header or minimum size validation ($($Entry.MinBytes) bytes)"
        }
        Write-Host "Prefetched: $($Entry.Item.Name) ($([math]::Round($ActualLen / 1MB, 1)) MB)" -ForegroundColor Green
      } catch {
        Write-Warning "Parallel prefetch for $($Entry.Item.Name) encountered an error ($($_.Exception.Message)); falling back to sequential retry..."
        if ($null -ne $Entry.OutStream) { try { $Entry.OutStream.Dispose() } catch {}; $Entry.OutStream = $null }
        if (Test-Path -LiteralPath $Entry.TempFile) { Remove-Item -LiteralPath $Entry.TempFile -Force -ErrorAction SilentlyContinue }
        Invoke-DownloadFile -Url $Entry.Url -OutFile $Entry.OutFile
        if (-not (Test-ValidCachedInstallerFile -Path $Entry.OutFile -MinBytes $Entry.MinBytes)) {
          Remove-Item -LiteralPath $Entry.OutFile -Force -ErrorAction SilentlyContinue
          throw "Sequential fallback download failed binary header or minimum size validation ($($Entry.MinBytes) bytes): $($Entry.OutFile)"
        }
      } finally {
        if ($null -ne $Entry.OutStream) { try { $Entry.OutStream.Dispose() } catch {} }
        if ($null -ne $Entry.InStream) { try { $Entry.InStream.Dispose() } catch {} }
        if ($null -ne $Entry.Response) { try { $Entry.Response.Dispose() } catch {} }
      }
    }
  } finally {
    if ($Client) { $Client.Dispose() }
    if ($Handler) { $Handler.Dispose() }
  }
}

function Test-WingetHelpSupports {
  param([Parameter(Mandatory = $true)] [string]$Command, [Parameter(Mandatory = $true)] [string]$Option)
  try {
    if (-not (Get-Variable -Name 'WingetHelpCache' -Scope Script -ErrorAction SilentlyContinue) -or -not ($Script:WingetHelpCache -is [hashtable])) {
      $Script:WingetHelpCache = @{}
    }
    if (-not $Script:WingetHelpCache.ContainsKey($Command)) {
      $Script:WingetHelpCache[$Command] = ((& winget $Command --help 2>$null) -join "`n")
    }
    $HelpText = [string]$Script:WingetHelpCache[$Command]
    return $HelpText -match [regex]::Escape($Option)
  } catch { return $false }
}

function Invoke-Winget {
  param([Parameter(Mandatory = $true)] [string[]]$Arguments)
  return (Invoke-NativeCommand -FilePath 'winget.exe' -ArgumentList $Arguments).ExitCode
}

function Install-ByWinget {
  param([Parameter(Mandatory = $true)] [string]$Id, [Parameter(Mandatory = $true)] [string]$NameForLog)
  if (-not (Test-CommandExists 'winget')) { Write-Warning "winget not found. Fallback will be used for $NameForLog."; return $false }
  Write-Host "Installing by winget: $NameForLog"
  $WingetLogPath = Join-Path (Join-Path $LogDir 'winget') (($NameForLog -replace '[\\/:*?"<>| ]', '_') + "-install.log")
  New-Item -ItemType Directory -Force -Path (Split-Path $WingetLogPath -Parent) | Out-Null
  $Args = @('install', '--id', $Id, '--exact', '--source', 'winget', '--silent', '--accept-package-agreements', '--accept-source-agreements', '--log', $WingetLogPath)
  if (Test-WingetHelpSupports -Command 'install' -Option '--disable-interactivity') { $Args += '--disable-interactivity' }
  try {
    $ExitCode = Invoke-Winget -Arguments $Args
    if ($ExitCode -eq 0) { Write-Host "$NameForLog installed by winget." -ForegroundColor Green; return $true }
    if ((& winget list --id $Id --exact --accept-source-agreements 2>$null) -join "`n" -match [regex]::Escape($Id)) {
      Write-Host "$NameForLog appears to be already installed. Continuing." -ForegroundColor Green; return $true
    }
  } catch { Write-Warning "winget failed for $NameForLog." }
  return $false
}

function Uninstall-WingetPackageIfExists {
  param([Parameter(Mandatory = $true)] [string]$Id, [Parameter(Mandatory = $true)] [string]$NameForLog)
  if (-not (Test-CommandExists 'winget')) { return }
  try {
    if ((& winget list --id $Id --exact --accept-source-agreements 2>$null) -join "`n" -notmatch [regex]::Escape($Id)) { return }
  } catch { return }
  $Args = @('uninstall', '--id', $Id, '--exact', '--silent')
  if (Test-WingetHelpSupports -Command 'uninstall' -Option '--source') { $Args += '--source'; $Args += 'winget' }
  if (Test-WingetHelpSupports -Command 'uninstall' -Option '--accept-source-agreements') { $Args += '--accept-source-agreements' }
  if (Test-WingetHelpSupports -Command 'uninstall' -Option '--disable-interactivity') { $Args += '--disable-interactivity' }
  Write-Host "Uninstalling: $NameForLog"
  try { Invoke-Winget -Arguments $Args | Out-Null } catch {}
}

function Update-WingetClient {
  Write-Section 'Update winget / App Installer'
  if (-not (Test-CommandExists 'winget')) { Write-Warning 'winget not found.'; return }
  $Args = @('upgrade', 'Microsoft.AppInstaller', '--silent', '--accept-package-agreements', '--accept-source-agreements')
  if (Test-WingetHelpSupports -Command 'upgrade' -Option '--disable-interactivity') { $Args += '--disable-interactivity' }
  try {
    $Exit = Invoke-Winget -Arguments $Args
    if ($Exit -eq 0) { Write-Host 'winget update completed.' -ForegroundColor Green }
  } catch {}
}
