<#
══════════════════════════════════════════════════════════════════════════
  seren-agent-setup.ps1  -  one-shot SerenAgent installer (Windows)

  Lives in D:\serenDaemon\SerenSetupScripts. Installs the per-node management
  plane and (optionally) services it via the shared NSSM core.

  The agent FOLLOWS THE LEADER: host/port live in
  %USERPROFILE%\seren-agent\seren-agent.yaml (server: block); the service
  starts with --config. The bearer TOKEN is separate - a safety interlock in
  ~/.seren/secrets.json (run seren-secrets), not a yaml field.

  USAGE
    powershell -ExecutionPolicy Bypass -File .\seren-agent-setup.ps1
    powershell -ExecutionPolicy Bypass -File .\seren-agent-setup.ps1 -Service
    powershell -ExecutionPolicy Bypass -File .\seren-agent-setup.ps1 -Wheel .\seren_agent-1.0.0-py3-none-any.whl
    powershell -ExecutionPolicy Bypass -File .\seren-agent-setup.ps1 -Pypi
══════════════════════════════════════════════════════════════════════════
#>
[CmdletBinding()]
param(
  [int]    $Port      = 7777,
  [string] $AgentHost = "0.0.0.0",   # NOT $Host (reserved automatic var)
  [string] $Wheel     = "",
  [switch] $Pypi,
  [string] $Ref       = "",
  [string] $Repo      = "ChadRoesler/SerenAgent",
  [switch] $Service,
  [string] $Instance  = "",
  [string] $VenvDir   = ""
)

$ErrorActionPreference = "Stop"
function Step($m){ Write-Host "`n==> $m" -ForegroundColor Blue }
function Ok($m)  { Write-Host "  + $m"   -ForegroundColor Green }
function Warn($m){ Write-Host "  ! $m"   -ForegroundColor Yellow }
function Die($m) { Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }

$ScriptDir = $PSScriptRoot

# -- locate a file by walking UP the tree (reorg-robust; injected by fixup) ---
function Find-Upward {
    param([Parameter(Mandatory)] [string] $Rel, [string] $Start = $PSScriptRoot)
    $dir = $Start
    while ($dir) {
        $candidate = Join-Path $dir $Rel
        if (Test-Path $candidate) { return (Resolve-Path $candidate).Path }
        $parent = Split-Path $dir -Parent
        if ($parent -eq $dir) { break }
        $dir = $parent
    }
    return $null
}

if (-not $VenvDir) { $VenvDir = "$env:USERPROFILE\seren-venvs\agent" }
$VenvDir = "$VenvDir$Instance"
$AppDir  = "$env:USERPROFILE\seren-agent$Instance"
$CfgPath = "$AppDir\seren-agent.yaml"
if ($Instance -and $Port -eq 7777) {
  Warn "Instance '$Instance' is using the default port 7777 - give each concurrent instance its own -Port or they'll collide."
}

Write-Host "==========================================" -ForegroundColor Green
Write-Host "  SerenAgent setup (Windows)" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green

Step "Finding a usable Python (3.10-3.12)"
$pyBin = $null
foreach ($cand in @("python", "py -3.12", "py -3.11", "py -3.10")) {
  $parts = $cand.Split(" "); $exe = $parts[0]
  if (Get-Command $exe -ErrorAction SilentlyContinue) {
    try { $ver = & $exe $parts[1..($parts.Length-1)] -c "import sys; print('%d.%d'%sys.version_info[:2])" 2>$null } catch { $ver = "" }
    if ($ver -match '^3\.(10|11|12)$') { $pyBin = $cand; break }
  }
}
if (-not $pyBin) { Die "No Python 3.10-3.12 found. Install from python.org or 'winget install Python.Python.3.12'." }
$pyArr = $pyBin.Split(" "); $pyExe = $pyArr[0]; $pyArgs = $pyArr[1..($pyArr.Length-1)]
$pyVer = & $pyExe $pyArgs -c "import sys; print('%d.%d.%d'%sys.version_info[:3])"
Ok "Using '$pyBin' (Python $pyVer)"

$wheelSrc = $null; $cleanupWheel = $false
if ($Wheel) {
  if (-not (Test-Path $Wheel)) { Die "wheel not found: $Wheel" }
  $wheelSrc = (Resolve-Path $Wheel).Path; Ok "Installing from local wheel: $(Split-Path $wheelSrc -Leaf)"
} elseif ($Pypi) {
  $wheelSrc = "seren-agent"; Ok "Installing the latest seren-agent from PyPI"
} else {
  Step "Resolving the seren-agent release from GitHub ($Repo)"
  $api = if ($Ref) { "https://api.github.com/repos/$Repo/releases/tags/$Ref" } else { "https://api.github.com/repos/$Repo/releases/latest" }
  try { $rel = Invoke-RestMethod -Uri $api -Headers @{ "User-Agent" = "seren-agent-setup" } } catch { Die "GitHub API request failed ($api)." }
  $asset = $rel.assets | Where-Object { $_.name -like "*.whl" } | Select-Object -First 1
  if (-not $asset) { Die "No .whl asset in release '$($rel.tag_name)'. Use -Wheel instead." }
  Ok "Release $($rel.tag_name)  ($($asset.name))"
  $wheelSrc = Join-Path $env:TEMP $asset.name; $cleanupWheel = $true
  Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $wheelSrc -UseBasicParsing; Ok "Downloaded"
}

Step "Creating venv at $VenvDir"
if (Test-Path "$VenvDir\Scripts\python.exe") { Warn "venv already exists - reusing it" }
else { & $pyExe $pyArgs -m venv $VenvDir; if (-not (Test-Path "$VenvDir\Scripts\python.exe")) { Die "venv creation failed" }; Ok "venv created" }
$vpy = "$VenvDir\Scripts\python.exe"

Step "Installing seren-agent"
& $vpy -m pip install -q --upgrade pip
& $vpy -m pip install -q --upgrade $wheelSrc
if ($LASTEXITCODE -ne 0) { Die "pip install failed - see output above" }
Ok "Installed"
if ($cleanupWheel) { Remove-Item -Force $wheelSrc -ErrorAction SilentlyContinue }

Step "Sanity-checking the install"
$check = & $vpy -c "import seren_agent; print('OK: v'+seren_agent.__version__)" 2>&1
if ("$check" -like "OK:*") { Ok "Package imports cleanly ($check)" } else { Die "Install looks broken: $check" }

Step "Writing config at $CfgPath"
New-Item -ItemType Directory -Force -Path $AppDir | Out-Null
if (Test-Path $CfgPath) { $bak = "$CfgPath.bak.$([int][double]::Parse((Get-Date -UFormat %s)))"; Copy-Item $CfgPath $bak; Warn "Backed up to $(Split-Path $bak -Leaf)" }
@"
# SerenAgent config - generated by seren-agent-setup.ps1
# host/port only. The bearer TOKEN is NOT here - it's a safety interlock in
# ~/.seren/secrets.json (run seren-secrets). See the repo's yaml sample.
server:
  host: $AgentHost          # 0.0.0.0 = reachable across the trusted LAN (cluster plane)
  port: $Port
"@ | Set-Content -Path $CfgPath -Encoding UTF8
Ok "Config written"

$launcher = "$AppDir\run-seren-agent.ps1"
"& `"$vpy`" -m seren_agent --config `"$CfgPath`"" | Set-Content -Path $launcher -Encoding UTF8
Ok "Launcher written: $launcher"

if ($Service) {
  Step "Installing the autostart service"
  $wrapper = Join-Path $ScriptDir "setup-agent-service.ps1"; $core = Find-Upward "Generics\setup-seren-service.ps1"
  if ((Test-Path $wrapper) -and (Test-Path $core)) { & $wrapper -Instance $Instance }
  else { Warn "setup-agent-service.ps1 + setup-seren-service.ps1 not found in $ScriptDir."; Warn "Run (elevated):  .\setup-agent-service.ps1 -Instance '$Instance'" }
}

$connectHost = if ($AgentHost -eq "0.0.0.0") { "127.0.0.1" } else { $AgentHost }
Write-Host ""
Write-Host "==========================================" -ForegroundColor Green
Write-Host "  SerenAgent is set up +" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green
if (-not $Service) {
  Write-Host "  Start it:        $launcher" -ForegroundColor Blue
  Write-Host "  (or directly:    $vpy -m seren_agent --config $CfgPath)" -ForegroundColor Blue
}
Write-Host "  Ping:            http://${connectHost}:$Port/api/v1/system/ping" -ForegroundColor Blue
Write-Host "  Docs:            http://${connectHost}:$Port/docs" -ForegroundColor Blue
Write-Host ""
Write-Host "  Token is a safety interlock: run seren-secrets to write ~/.seren/secrets.json." -ForegroundColor Yellow
Write-Host "  Until then the agent fails CLOSED on service-management endpoints." -ForegroundColor Yellow
Write-Host "Rip it and win. 🌭🔧" -ForegroundColor Green
