<#
══════════════════════════════════════════════════════════════════════════
  setup-agent-service.ps1  -  SerenAgent pointed wrapper (Windows/NSSM)

  CONVENTION half for the per-node agent on Windows. Knows SerenAgent's shape
  and hands it to setup-seren-service.ps1 (the Python NSSM core). Lives in the
  shared SerenSetupScripts dir.

  The agent FOLLOWS THE LEADER: host/port come from
  %USERPROFILE%\seren-agent\seren-agent.yaml via --config, same as Memory.
  The bearer token is NOT here - it's a safety interlock in
  ~/.seren/secrets.json (run seren-secrets), loaded separately. So this
  wrapper passes no token env.

  INSTANCE CONVENTION (mirrors seren-agent-setup.ps1):
    -Instance "Test" suffixes everything:
      Service:  SerenAgentTest
      Venv:     %USERPROFILE%\seren-venvs\agentTest
      AppDir:   %USERPROFILE%\seren-agentTest
      Config:   %USERPROFILE%\seren-agentTest\seren-agent.yaml

  RUN IT: elevated PowerShell, as yourself.
══════════════════════════════════════════════════════════════════════════
#>
[CmdletBinding()]
param(
  [string] $Instance    = "",
  [string] $VenvDir     = "",
  [string] $AppDir      = "",
  [string] $ConfigPath  = "",
  [string] $LogDir      = "D:\serenDaemon\logs",
  [int]    $HealthPort  = 0,
  [switch] $RunAsLocalSystem
)


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

$ErrorActionPreference = "Stop"

# -- the four identity lines (the whole point of this wrapper) ----------------
$ServiceName = "SerenAgent$Instance"
$ModuleName  = "seren_agent"
if (-not $VenvDir)    { $VenvDir    = "$env:USERPROFILE\seren-venvs\agent$Instance" }
if (-not $AppDir)     { $AppDir     = "$env:USERPROFILE\seren-agent$Instance" }
if (-not $ConfigPath) { $ConfigPath = "$AppDir\seren-agent.yaml" }

# -- delegate to the shared generic core --------------------------------------
$core = Find-Upward "Generics\setup-seren-service.ps1"
if (-not $core -or -not (Test-Path $core)) {
  Write-Host "ERROR: setup-seren-service.ps1 not found walking up from this script." -ForegroundColor Red
  Write-Host "       The wrapper is just conventions - the core does the work. Keep the shared scripts together." -ForegroundColor Red
  exit 1
}

# Agent's public liveness path is /api/v1/system/ping (NOT /health). Port reads
# from server.port in the config (core default --config-port-key server.port).
& $core `
  -ServiceName $ServiceName `
  -ModuleName  $ModuleName `
  -VenvDir     $VenvDir `
  -AppDir      $AppDir `
  -ConfigPath  $ConfigPath `
  -LogDir      $LogDir `
  -HealthPort  $HealthPort `
  -HealthPath  "/api/v1/system/ping" `
  -DisplayName $ServiceName `
  -Description "SerenAgent$Instance - per-node management plane" `
  -RunAsLocalSystem:$RunAsLocalSystem
