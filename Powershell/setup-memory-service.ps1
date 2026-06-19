<#
══════════════════════════════════════════════════════════════════════════
  setup-memory-service.ps1  -  SerenMemory pointed wrapper (Windows/NSSM)

  The CONVENTION half of the generic-core / pointed-wrapper split. Knows what
  a SerenMemory install looks like and hands it to setup-seren-service.ps1,
  which does the NSSM mechanics. Lives alongside the core in
  D:\serenDaemon\SerenSetupScripts.

  INSTANCE CONVENTION (mirrors seren-memory-setup.ps1):
    -Instance "Test" suffixes everything:
      Service:  SerenMemoryTest
      Venv:     %USERPROFILE%\seren-venvs\memoryTest
      AppDir:   %USERPROFILE%\seren-memoryTest
      Config:   %USERPROFILE%\seren-memoryTest\seren-memory.yaml
    Run the installer with -Instance Test FIRST, then this with the same.

  The health-check port reads from the config yaml (server.port), so whatever
  -Port the installer used is the port that gets checked. No drift.

  RUN IT: elevated PowerShell, as yourself.
    powershell -ExecutionPolicy Bypass -File .\setup-memory-service.ps1
    powershell -ExecutionPolicy Bypass -File .\setup-memory-service.ps1 -Instance Test
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
$ServiceName = "SerenMemory$Instance"
$ModuleName  = "seren_memory"
if (-not $VenvDir)    { $VenvDir    = "$env:USERPROFILE\seren-venvs\memory$Instance" }
if (-not $AppDir)     { $AppDir     = "$env:USERPROFILE\seren-memory$Instance" }
if (-not $ConfigPath) { $ConfigPath = "$AppDir\seren-memory.yaml" }

# -- delegate to the shared generic core --------------------------------------
$core = Find-Upward "Generics\setup-seren-service.ps1"
if (-not $core -or -not (Test-Path $core)) {
  Write-Host "ERROR: setup-seren-service.ps1 not found walking up from this script." -ForegroundColor Red
  Write-Host "       The wrapper is just conventions - the core does the work. Keep the shared scripts together." -ForegroundColor Red
  exit 1
}

& $core `
  -ServiceName $ServiceName `
  -ModuleName  $ModuleName `
  -VenvDir     $VenvDir `
  -AppDir      $AppDir `
  -ConfigPath  $ConfigPath `
  -LogDir      $LogDir `
  -HealthPort  $HealthPort `
  -DisplayName $ServiceName `
  -Description "SerenMemory$Instance local memory service (three-tier Halls of Memory)" `
  -ExtraEnv    @("PYTHONUTF8=1", "SEREN_SUPERVISED=1") `
  -RunAsLocalSystem:$RunAsLocalSystem
