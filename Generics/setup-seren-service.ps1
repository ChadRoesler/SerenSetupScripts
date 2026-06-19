<#
══════════════════════════════════════════════════════════════════════════
  setup-seren-service.ps1  -  GENERIC NSSM service installer for any
  Python-module-shaped seren service (SerenMemory, SerenMargin, whatever
  joins the constellation next).

  This is the MECHANISM half of the generic-core / pointed-wrapper split.
  It knows NSSM, absolute paths, run-as-you identity, log wiring, and
  health checks. It deliberately knows NOTHING about any specific service's
  conventions - that's the wrapper's job (see setup-service.ps1 for the
  SerenMemory wrapper as the reference example).

  Carries forward the two hard-won fixes from the original SerenMemory
  service script:
    1. ABSOLUTE paths. Services launch via CreateProcess, which does NOT
       expand %USERPROFILE% (no shell involved). This script resolves real
       absolute paths before nssm ever sees them.
    2. Runs AS YOU, not LocalSystem. As LocalSystem, '~' resolves to the
       system profile, so a config like persist_dir: ~/.seren-memory/chroma
       points at a DIFFERENT, empty store. Running as your user makes ~,
       data dirs, and model caches resolve exactly as they did during setup.

  New in the generic version:
    3. Health-check port reads from the service's OWN yaml config by
       default (dotted key, default 'server.port') using the venv's python.
       One source of truth - the config the service actually loads. Pass
       -HealthPort to override, or it warns-and-skips if the read fails
       (lenient by design: not every service's schema will match).
    4. Log filenames derive from -ServiceName, so multiple services and
       instances namespace their logs for free.

  USAGE (normally you don't call this directly - the wrapper does):
    powershell -ExecutionPolicy Bypass -File .\setup-seren-service.ps1 `
      -ServiceName SerenMemory `
      -ModuleName  seren_memory `
      -VenvDir     "$env:USERPROFILE\seren-venvs\memory" `
      -AppDir      "$env:USERPROFILE\seren-memory" `
      -ConfigPath  "$env:USERPROFILE\seren-memory\seren-memory.yaml"

  RUN IT: elevated PowerShell, as yourself.
══════════════════════════════════════════════════════════════════════════
#>
[CmdletBinding()]
param(
  # -- identity of the thing being installed (wrapper supplies these) -------
  [Parameter(Mandatory)] [string] $ServiceName,
  [Parameter(Mandatory)] [string] $ModuleName,        # python -m <this>
  [Parameter(Mandatory)] [string] $VenvDir,
  [Parameter(Mandatory)] [string] $AppDir,            # working directory
  [Parameter(Mandatory)] [string] $ConfigPath,

  # -- presentation -----------------------------------------------------------
  [string] $DisplayName  = "",                        # defaults to $ServiceName
  [string] $Description  = "",

  # -- logging ----------------------------------------------------------------
  [string] $LogDir       = "D:\serenDaemon\logs",

  # -- health check -----------------------------------------------------------
  [int]    $HealthPort    = 0,                        # 0 = read from config
  [string] $ConfigPortKey = "server.port",            # dotted path into yaml
  [string] $HealthPath    = "/health",
  [switch] $NoHealthCheck,

  # -- identity (the run-as) ----------------------------------------------------
  [switch] $RunAsLocalSystem,   # NOT recommended - see the warning it prints

  # -- inline env vars ----------------------------------------------------------
  # Injected into the NSSM service via AppEnvironmentExtra. The wrapper supplies
  # the per-service vars (e.g. PYTHONUTF8=1 to be explicit about UTF-8 I/O,
  # SEREN_SUPERVISED=1 so the service's /migrate/restart may self-exit knowing
  # NSSM's AppExit Default Restart will revive it). Pass -ExtraEnv @("K=V","K2=V2").
  # (Named ExtraEnv, not Env, to avoid visual collision with the $env: drive.)
  [string[]] $ExtraEnv = @()
)

$ErrorActionPreference = "Stop"
function Step($m){ Write-Host "`n==> $m" -ForegroundColor Blue }
function Ok($m)  { Write-Host "  + $m"   -ForegroundColor Green }
function Warn($m){ Write-Host "  ! $m"   -ForegroundColor Yellow }
function Die($m) { Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }

if (-not $DisplayName) { $DisplayName = $ServiceName }
if (-not $Description) { $Description = "$ServiceName - seren constellation service" }

# -- must be elevated (service install needs admin) -------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal]`
            [Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Die "Run this in an ELEVATED PowerShell (right-click -> Run as administrator), but as your own user." }

# -- find nssm --------------------------------------------------------------
$nssm = (Get-Command nssm -ErrorAction SilentlyContinue).Source
if (-not $nssm) { $nssm = "$env:LOCALAPPDATA\Microsoft\WinGet\Links\nssm.exe" }
if (-not (Test-Path $nssm)) { Die "nssm not found. Install it: winget install nssm" }
Ok "nssm: $nssm"

# -- resolve ABSOLUTE paths (hard-won fix #1) --------------------------------
$Python = Join-Path $VenvDir "Scripts\python.exe"
if (-not (Test-Path $Python)) { Die "python.exe not found at $Python  (check -VenvDir)" }
$Python = (Resolve-Path $Python).Path
if (-not (Test-Path $AppDir)) { Die "AppDir not found: $AppDir  (run the installer for this service first)" }
$AppDir = (Resolve-Path $AppDir).Path
if (Test-Path $ConfigPath) {
  $ConfigPath = (Resolve-Path $ConfigPath).Path
} else {
  Warn "config not found at $ConfigPath - the service will fail until it exists"
}
Ok "python:  $Python"
Ok "module:  $ModuleName"
Ok "appdir:  $AppDir"
Ok "config:  $ConfigPath"

# -- resolve the health-check port -------------------------------------------
# One source of truth: the yaml the service actually loads. We use the venv's
# own python (pyyaml rides along with these services' deps) to walk a dotted
# key path. Lenient on purpose - if the schema doesn't match, we warn and skip
# the health check rather than refusing to install.
if (-not $NoHealthCheck -and $HealthPort -eq 0 -and (Test-Path $ConfigPath)) {
  Step "Reading health-check port from config ($ConfigPortKey)"
  # Here-string into a variable FIRST - a closing "@ followed by more args on
  # the same line is a parser footgun. And pipe through Out-String/Trim since
  # & python hands back an array of lines, not a scalar.
  $portScript = @"
import sys
try:
    import yaml
    cfg = yaml.safe_load(open(sys.argv[1], encoding='utf-8')) or {}
    node = cfg
    for part in sys.argv[2].split('.'):
        node = node[part]
    print(int(node))
except Exception as e:
    print(f'READ_FAILED: {e}')
"@
  $portRead = (& $Python -c $portScript $ConfigPath $ConfigPortKey 2>$null | Out-String).Trim()
  if ($portRead -match '^\d+$') {
    $HealthPort = [int]$portRead
    Ok "Port $HealthPort (from config)"
  } else {
    Warn "Couldn't read '$ConfigPortKey' from the config ($portRead)."
    Warn "Pass -HealthPort to enable the post-start health check; skipping it this run."
  }
}

# -- ensure the log dir exists (nssm won't create it) -----------------------
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
# Log names derive from ServiceName so services + instances namespace freely.
$OutLog = Join-Path $LogDir "$ServiceName.out.log"
$ErrLog = Join-Path $LogDir "$ServiceName.err.log"
Ok "logs:    $OutLog / $(Split-Path $ErrLog -Leaf)"

# -- clean reinstall if a service by this name exists ------------------------
$exists = (& sc.exe query $ServiceName) 2>$null | Select-String "SERVICE_NAME"
if ($exists) {
  Step "Existing '$ServiceName' found - stopping and removing for a clean reinstall"
  & $nssm stop   $ServiceName 2>$null | Out-Null
  Start-Sleep -Seconds 2
  & $nssm remove $ServiceName confirm | Out-Null
  Start-Sleep -Seconds 2
  Ok "old service removed"
}

# -- install + configure ------------------------------------------------------
Step "Installing $ServiceName"
& $nssm install $ServiceName $Python | Out-Null
& $nssm set $ServiceName AppParameters  "-m $ModuleName --config `"$ConfigPath`"" | Out-Null
& $nssm set $ServiceName AppDirectory   $AppDir | Out-Null
& $nssm set $ServiceName AppStdout       $OutLog | Out-Null
& $nssm set $ServiceName AppStderr       $ErrLog | Out-Null
& $nssm set $ServiceName AppExit Default Restart | Out-Null
& $nssm set $ServiceName AppRestartDelay 3000 | Out-Null   # 3s between restarts - don't hammer on a crash-loop
& $nssm set $ServiceName Start SERVICE_AUTO_START | Out-Null
& $nssm set $ServiceName DisplayName $DisplayName | Out-Null
& $nssm set $ServiceName Description $Description | Out-Null
# Inline env vars -> NSSM AppEnvironmentExtra (KEY=VALUE list). NSSM APPENDS
# these to the process environment (doesn't replace it), which is what we want.
if ($ExtraEnv.Count -gt 0) {
  & $nssm set $ServiceName AppEnvironmentExtra @ExtraEnv | Out-Null
  Ok "env:     $($ExtraEnv -join ', ')"
}
Ok "configured"

# -- identity (hard-won fix #2) -----------------------------------------------
if ($RunAsLocalSystem) {
  Warn "Running as LocalSystem: '~' and caches resolve to the SYSTEM profile, NOT your user."
  Warn "Only safe if your config uses ABSOLUTE paths AND nothing caches under ~."
  Warn "Otherwise your data store will look empty."
  & $nssm set $ServiceName ObjectName LocalSystem | Out-Null
} else {
  Step "Setting the service to run as you (so ~, data dirs, and caches resolve to your profile)"
  $cred  = Get-Credential -UserName ".\$env:USERNAME" `
            -Message "Your Windows password - stored as the service logon so it runs as you."
  $plain = $cred.GetNetworkCredential().Password
  & $nssm set $ServiceName ObjectName "$($cred.UserName)" "$plain" | Out-Null
  $plain = $null   # don't leave it lying around
  Ok "service will run as $($cred.UserName)"
}

# -- start + health check + show the error if it sulks ------------------------
Step "Starting $ServiceName"
& $nssm start $ServiceName 2>$null | Out-Null
Start-Sleep -Seconds 6
if ($NoHealthCheck -or $HealthPort -eq 0) {
  Warn "Health check skipped. Eyeball it yourself:"
  & sc.exe query $ServiceName | Select-String "STATE" | ForEach-Object { Write-Host "    $_" }
} else {
  try {
    $h = Invoke-RestMethod -Uri "http://127.0.0.1:$HealthPort$HealthPath" -TimeoutSec 10
    if ($h.ok) { Ok "Up and healthy on http://127.0.0.1:$HealthPort" }
    else       { Warn "Started but $HealthPath returned: $($h | ConvertTo-Json -Compress)" }
  } catch {
    Warn "Health check didn't answer yet. Most recent stderr (the real error lives here now):"
    if (Test-Path $ErrLog) { Get-Content $ErrLog -Tail 25 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkYellow } }
    else { Warn "no stderr log at $ErrLog yet - service may not have launched the binary at all" }
    Write-Host "  service state:" -ForegroundColor Yellow
    & sc.exe query $ServiceName | Select-String "STATE" | ForEach-Object { Write-Host "    $_" }
  }
}

Write-Host "`nManage it:" -ForegroundColor Green
Write-Host "  nssm restart $ServiceName"
Write-Host "  nssm edit    $ServiceName            # GUI config"
Write-Host "  Get-Content `"$ErrLog`" -Tail 40 -Wait   # watch logs live"
Write-Host "`nRip it and win. 🌭🔧" -ForegroundColor Green