<#
══════════════════════════════════════════════════════════════════════════
  setup-corpus-callosum-service.ps1  -  SerenCorpusCallosum pointed wrapper (Windows/NSSM)

  The CONVENTION half of the generic-core / pointed-wrapper split. Knows what
  a SerenCorpusCallosum install looks like and hands it to setup-seren-service.ps1,
  which does the NSSM mechanics. Lives alongside the core in
  D:\serenDaemon\SerenSetupScripts.

  INSTANCE CONVENTION (mirrors seren-corpus-callosum-setup.ps1):
    -Instance "Test" suffixes everything:
      Service:  SerenCorpusCallosumTest
      Venv:     %USERPROFILE%\seren-venvs\callosumTest
      AppDir:   %USERPROFILE%\seren-corpus-callosumTest
      Config:   %USERPROFILE%\seren-corpus-callosumTest\seren-corpus-callosum.yaml
    Run the installer with -Instance Test FIRST, then this with the same.

  The health-check port reads from the config yaml (server.port), so whatever
  -Port the installer used is the port that gets checked. No drift.

  RUN IT: elevated PowerShell, as yourself.
    powershell -ExecutionPolicy Bypass -File .\setup-corpus-callosum-service.ps1
    powershell -ExecutionPolicy Bypass -File .\setup-corpus-callosum-service.ps1 -Instance Test
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
# These MUST match seren-corpus-callosum-setup.ps1 exactly, or the service ends
# up pointed at a venv/appdir/config the installer never created.
$ServiceName = "SerenCorpusCallosum$Instance"
$ModuleName  = "seren_corpus_callosum"
if (-not $VenvDir)    { $VenvDir    = "$env:USERPROFILE\seren-venvs\callosum$Instance" }
if (-not $AppDir)     { $AppDir     = "$env:USERPROFILE\seren-corpus-callosum$Instance" }
if (-not $ConfigPath) { $ConfigPath = "$AppDir\seren-corpus-callosum.yaml" }

# -- delegate to the shared generic core --------------------------------------
$core = Find-Upward "Generics\setup-seren-service.ps1"
if (-not $core -or -not (Test-Path $core)) {
  Write-Host "ERROR: setup-seren-service.ps1 not found walking up from this script." -ForegroundColor Red
  Write-Host "       The wrapper is just conventions - the core does the work. Keep the shared scripts together." -ForegroundColor Red
  exit 1
}

# NOTE like the loci wrapper: no SEREN_SUPERVISED. That flag lets the right
# brain's /migrate/restart self-exit knowing the service revives it. The
# callosum embeds NOTHING (RRF reads only rank ordering) - no embedder, no
# migration, no self-restart - so there's nothing to supervise. Just
# PYTHONUTF8=1, to be explicit about UTF-8 I/O.
& $core `
  -ServiceName $ServiceName `
  -ModuleName  $ModuleName `
  -VenvDir     $VenvDir `
  -AppDir      $AppDir `
  -ConfigPath  $ConfigPath `
  -LogDir      $LogDir `
  -HealthPort  $HealthPort `
  -DisplayName $ServiceName `
  -Description "SerenCorpusCallosum$Instance local memory federation (the callosum - fans every store, RRF-merged)" `
  -ExtraEnv    @("PYTHONUTF8=1") `
  -RunAsLocalSystem:$RunAsLocalSystem
