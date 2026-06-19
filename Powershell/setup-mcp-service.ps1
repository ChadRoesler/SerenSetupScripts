<#
══════════════════════════════════════════════════════════════════════════
  setup-mcp-service.ps1  -  SerenMcpServer pointed wrapper (.NET/NSSM)

  CONVENTION half for the MCP server on Windows. Knows MCP's shape (no
  positional config, env-driven bind + downstreams, port 6362, /health) and
  hands it to setup-seren-dotnet-service.ps1. Lives in SerenSetupScripts.

  RUN IT: elevated PowerShell, as yourself.
    powershell -ExecutionPolicy Bypass -File .\setup-mcp-service.ps1
══════════════════════════════════════════════════════════════════════════
#>
[CmdletBinding()]
param(
  [string] $RepoDir    = "",    # default sibling ..\SerenMcp
  [string] $DeployDir  = "",    # default %USERPROFILE%\seren-mcp-server
  [string] $Rid        = "win-x64",
  [string] $RuntimeUrl = "http://localhost:6361",
  [string] $SearxngUrl = "http://localhost:8080",
  [string] $MemoryUrl  = "http://localhost:7420",
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

if (-not $RepoDir)   { $RepoDir = Find-Upward "SerenMcp" }
if (-not $DeployDir) { $DeployDir = "$env:USERPROFILE\seren-mcp-server" }
if (-not $RepoDir -or -not (Test-Path $RepoDir)) {
  Write-Host "ERROR: SerenMcp repo not found walking up from this script." -ForegroundColor Red
  Write-Host "       Pass -RepoDir explicitly, or keep this script within the serenDaemon tree." -ForegroundColor Red
  exit 1
}

$core = Find-Upward "Generics\setup-seren-dotnet-service.ps1"
if (-not $core -or -not (Test-Path $core)) {
  Write-Host "ERROR: setup-seren-dotnet-service.ps1 not found walking up from this script." -ForegroundColor Red
  exit 1
}

# No positional config. Pin bind + downstream URLs as env so the deployed
# service is explicit rather than relying on the hardcoded defaults.
$envVars = @{
  "ASPNETCORE_URLS"        = "http://0.0.0.0:6362"
  "SEREN_RUNTIME_HOST_URL" = $RuntimeUrl
  "SEREN_SEARXNG_URL"      = $SearxngUrl
  "SEREN_MEMORY_URL"       = $MemoryUrl
}

& $core `
  -ServiceName "seren-mcp-server" `
  -ProjectDir  (Join-Path $RepoDir "SerenMcpServer") `
  -ExecName    "SerenMcpServer.exe" `
  -DeployDir   $DeployDir `
  -Rid         $Rid `
  -EnvVars     $envVars `
  -HealthPort  6362 `
  -HealthPath  "/health" `
  -Description "SerenMcpServer - MCP tool server for the Seren stack" `
  -NoPublish:$NoPublish `
  -RunAsLocalSystem:$RunAsLocalSystem
