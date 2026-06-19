<#
══════════════════════════════════════════════════════════════════════════
  setup-runtimehost-service.ps1  -  SerenRuntimeHost pointed wrapper (.NET/NSSM)

  CONVENTION half for the cluster head on Windows. Knows RuntimeHost's shape
  (positional yaml config, port 6361, /api/v1/system/ping health) and hands
  it to setup-seren-dotnet-service.ps1. Lives in the shared SerenSetupScripts.

  RUN IT: elevated PowerShell, as yourself.
    powershell -ExecutionPolicy Bypass -File .\setup-runtimehost-service.ps1
══════════════════════════════════════════════════════════════════════════
#>
[CmdletBinding()]
param(
  [string] $RepoDir   = "",     # default sibling ..\SerenRuntimeHost
  [string] $DeployDir = "",     # default %USERPROFILE%\seren-runtime-host
  [string] $ConfigPath = "",    # default <deploy>\seren-runtime.yaml
  [string] $Rid       = "win-x64",
  [switch] $NoPublish,
  [switch] $RunAsLocalSystem
)

$ErrorActionPreference = "Stop"
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

if (-not $RepoDir)    { $RepoDir = Find-Upward "SerenRuntimeHost" }
if (-not $DeployDir)  { $DeployDir = "$env:USERPROFILE\seren-runtime-host" }
if (-not $ConfigPath) { $ConfigPath = Join-Path $DeployDir "seren-runtime.yaml" }
if (-not $RepoDir -or -not (Test-Path $RepoDir)) {
  Write-Host "ERROR: SerenRuntimeHost repo not found walking up from this script." -ForegroundColor Red
  Write-Host "       Pass -RepoDir explicitly, or keep this script within the serenDaemon tree." -ForegroundColor Red
  exit 1
}

$core = Find-Upward "Generics\setup-seren-dotnet-service.ps1"
if (-not $core -or -not (Test-Path $core)) {
  Write-Host "ERROR: setup-seren-dotnet-service.ps1 not found walking up from this script." -ForegroundColor Red
  exit 1
}

# config is POSITIONAL for RuntimeHost -> pass as ExecArgs (quoted for spaces).
& $core `
  -ServiceName "seren-runtime-host" `
  -ProjectDir  (Join-Path $RepoDir "SerenRuntimeHost") `
  -ExecName    "SerenRuntimeHost.exe" `
  -ExecArgs    "`"$ConfigPath`"" `
  -DeployDir   $DeployDir `
  -Rid         $Rid `
  -HealthPort  6361 `
  -HealthPath  "/api/v1/system/ping" `
  -Description "SerenRuntimeHost - cluster head (aggregates agent APIs, serves dashboard)" `
  -NoPublish:$NoPublish `
  -RunAsLocalSystem:$RunAsLocalSystem
