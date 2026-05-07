# setup-ai-hosts.ps1

Write-Section 'Setup AI Hosts Block'
$PA = "[$Global:SetupStepCurrent/$Global:SetupStepTotal] AI Hosts Block"
Write-Progress -Activity $PA -Status "Downloading AI Hosts Block Script..." -PercentComplete 10

$AiScriptUrl = "$RawBase/ai-hosts-block.ps1"
$AiScriptPath = Join-Path $Root 'ai-hosts-block.ps1'

# Create root directory if needed
New-Item -ItemType Directory -Force -Path $Root | Out-Null

Invoke-WebRequest -Uri $AiScriptUrl -OutFile $AiScriptPath -UseBasicParsing
if (-not (Test-Path $AiScriptPath)) { throw "Failed to download $AiScriptPath" }

Write-Progress -Activity $PA -Status "Applying Blocklist..." -PercentComplete 50

# Apply the hosts block without its own scheduled task
$PowerShellExe = Get-Command pwsh.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -First 1
if (-not $PowerShellExe) { $PowerShellExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" }

$ForwardArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $AiScriptPath, '-Apply', '-NoSchedule', '-Root', $Root)

& $PowerShellExe @ForwardArgs

if ($LASTEXITCODE -ne 0) { throw "AI Hosts block application failed. Exit code: $LASTEXITCODE" }

Write-Host "AI hosts block applied for contest environment." -ForegroundColor Green
Write-Progress -Activity $PA -Completed
