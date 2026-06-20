<#
══════════════════════════════════════════════════════════════════════════
  seren-loci-setup.ps1  -  one-shot SerenLoci installer (Windows)

  Lives in D:\serenDaemon\SerenSetupScripts (shared home for setup scripts).
  This script:
    1. Finds a usable Python (3.10-3.12)
    2. Makes a clean venv at %USERPROFILE%\seren-venvs\loci
    3. Installs seren-loci
         - DEFAULT: from PyPI (seren-loci is published)
         - -Wheel FILE   to install a prebuilt wheel
         - -Ref TAG      to pull a wheel from a GitHub release
         - -Mcp          install the [mcp] extra (adds the /mcp route)
         - -Corp         route TLS through the OS trust store (corp proxy)
         - -Vector       install the [vector] extra (sqlite-vec + sentence-
                         transformers) AND enable the embedder in the config
    4. Writes a config at %USERPROFILE%\seren-loci\seren-loci.yaml
    5. Drops a run-seren-loci.ps1 launcher
    6. (optional) installs an NSSM autostart service via setup-loci-service.ps1

  Defaults are SAFE: binds 127.0.0.1 (this machine only), no auth.

  USAGE
    powershell -ExecutionPolicy Bypass -File .\seren-loci-setup.ps1
    powershell -ExecutionPolicy Bypass -File .\seren-loci-setup.ps1 -GenToken
    powershell -ExecutionPolicy Bypass -File .\seren-loci-setup.ps1 -Service
    powershell -ExecutionPolicy Bypass -File .\seren-loci-setup.ps1 -Wheel .\seren_loci-0.1.0-py3-none-any.whl
    powershell -ExecutionPolicy Bypass -File .\seren-loci-setup.ps1 -Mcp
══════════════════════════════════════════════════════════════════════════
#>
[CmdletBinding()]
param(
  [int]    $Port      = 7422,
  [string] $LociHost = "127.0.0.1",   # NOT $Host - that's a reserved automatic var
  [string] $Token     = "",
  [switch] $GenToken,
  [string] $Wheel     = "",
  [string] $Ref       = "",
  [string] $Repo      = "",
  [switch] $Service,
  [switch] $Mcp,
  [switch] $Corp,
  [switch] $Vector,
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

if (-not $VenvDir) { $VenvDir = "$env:USERPROFILE\seren-venvs\loci" }

$VenvDir = "$VenvDir$Instance"
$AppDir  = "$env:USERPROFILE\seren-loci$Instance"
$CfgPath = "$AppDir\seren-loci.yaml"
if ($Instance -and $Port -eq 7422) {
  Warn "Instance '$Instance' is using the default port 7422 - give each concurrent instance its own -Port or they'll collide."
}

Write-Host "==========================================" -ForegroundColor Green
Write-Host "  SerenLoci setup (Windows)" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green

# -- 1. find a usable Python ------------------------------------------------
Step "Finding a usable Python (3.10-3.12)"
$pyBin = $null
foreach ($cand in @("python", "py -3.12", "py -3.11", "py -3.10")) {
  $parts = $cand.Split(" ")
  $exe = $parts[0]
  if (Get-Command $exe -ErrorAction SilentlyContinue) {
    try {
      $ver = & $exe $parts[1..($parts.Length-1)] -c "import sys; print('%d.%d'%sys.version_info[:2])" 2>$null
    } catch { $ver = "" }
    if ($ver -match '^3\.(10|11|12)$') { $pyBin = $cand; break }
  }
}
if (-not $pyBin) { Die "No Python 3.10-3.12 found. Install from python.org or 'winget install Python.Python.3.12'. (Avoid 3.13+ - the optional [vector] extra pulls torch, which has no 3.13 wheels yet; the dep-free floor would run on 3.13.)" }
$pyArr = $pyBin.Split(" ")
$pyExe = $pyArr[0]; $pyArgs = $pyArr[1..($pyArr.Length-1)]
$pyVer = & $pyExe $pyArgs -c "import sys; print('%d.%d.%d'%sys.version_info[:3])"
Ok "Using '$pyBin' (Python $pyVer)"

if ($Ref -and -not $Repo) { $Repo = "ChadRoesler/SerenLoci" }

# -- 2. resolve what to install ---------------------------------------------
# Precedence: -Wheel > -Repo/-Ref (GitHub) > PyPI (default)
$wheelSrc = $null
$cleanupWheel = $false
if ($Wheel) {
  if (-not (Test-Path $Wheel)) { Die "wheel not found: $Wheel" }
  $wheelSrc = (Resolve-Path $Wheel).Path
  Ok "Installing from local wheel: $(Split-Path $wheelSrc -Leaf)"
} elseif ($Repo) {
  Step "Resolving the SerenLoci release from GitHub ($Repo)"
  $api = if ($Ref) { "https://api.github.com/repos/$Repo/releases/tags/$Ref" }
         else      { "https://api.github.com/repos/$Repo/releases/latest" }
  try { $rel = Invoke-RestMethod -Uri $api -Headers @{ "User-Agent" = "seren-loci-setup" } }
  catch { Die "GitHub API request failed ($api). Check the repo/tag and your network." }
  $asset = $rel.assets | Where-Object { $_.name -like "*.whl" } | Select-Object -First 1
  if (-not $asset) { Die "No .whl asset in release '$($rel.tag_name)'. Use -Wheel instead." }
  Ok "Release $($rel.tag_name)  ($($asset.name))"
  $wheelSrc = Join-Path $env:TEMP $asset.name
  $cleanupWheel = $true
  Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $wheelSrc -UseBasicParsing
  Ok "Downloaded"
} else {
  $wheelSrc = "seren-loci"
  Ok "No wheel or GitHub ref specified - will install the latest from PyPI"
}

# -- 3. venv + install ------------------------------------------------------
Step "Creating venv at $VenvDir"
if (Test-Path "$VenvDir\Scripts\python.exe") {
  Warn "venv already exists - reusing it (will upgrade the package)"
} else {
  & $pyExe $pyArgs -m venv $VenvDir
  if (-not (Test-Path "$VenvDir\Scripts\python.exe")) { Die "venv creation failed" }
  Ok "venv created"
}
$vpy = "$VenvDir\Scripts\python.exe"

# [mcp]/[corp]/[vector] extras must be glued to the spec with no space. Build the suffix
# ([mcp], [corp], [vector], [mcp,corp], [mcp,vector], [corp,vector], [mcp,corp,vector], or none) then append it to the wheel/PyPI name.
$extras = if ($Mcp -and $Corp -and $Vector) { "[mcp,corp,vector]" }
          elseif ($Mcp -and $Corp)        { "[mcp,corp]" }
          elseif ($Mcp -and $Vector)      { "[mcp,vector]" }
          elseif ($Corp -and $Vector)     { "[corp,vector]" }
          elseif ($Mcp)                   { "[mcp]" }
          elseif ($Corp)                  { "[corp]" }
          elseif ($Vector)                { "[vector]" }
          else                            { "" }
$installSpec = "$wheelSrc$extras"
# When -Corp: pip 24.2+ can use the OS trust store for its OWN TLS during the
# install (so fetching through a corp TLS-intercepting proxy works). Older pip
# lacks the feature - we just skip the flag.
$corpArgs = @()
if ($Corp) {
  $pipVerRaw = (& $vpy -m pip --version) 2>$null
  if ($pipVerRaw -match '(\d+)\.(\d+)') {
    $maj = [int]$Matches[1]; $min = [int]$Matches[2]
    if ($maj -gt 24 -or ($maj -eq 24 -and $min -ge 2)) { $corpArgs += '--use-feature=truststore' }
  }
}
Step ("Installing seren-loci" + $extras)
& $vpy -m pip install -q --upgrade pip
& $vpy -m pip install -q --upgrade @corpArgs $installSpec
if ($LASTEXITCODE -ne 0) { Die "pip install failed - see output above" }
Ok "Installed"
if ($cleanupWheel) { Remove-Item -Force $wheelSrc -ErrorAction SilentlyContinue }

# -- 4. sanity check (import + the viewer asset that's bitten us before) -----
Step "Sanity-checking the install"
$check = & $vpy -c @"
import pathlib
try:
    import seren_loci
except Exception as e:
    print(f'IMPORT_FAILED: {e}'); raise SystemExit
v = pathlib.Path(seren_loci.__file__).parent / 'viewer' / 'loci.html'
print('OK' if v.exists() else 'VIEWER_MISSING')
"@
switch -Wildcard ($check) {
  "OK"             { Ok "Package imports and the Halls viewer asset is present" }
  "VIEWER_MISSING" { Warn "Installed but loci.html is missing - /viewer will 404" }
  default          { Die "Install looks broken: $check" }
}

# -- 5. config --------------------------------------------------------------
Step "Writing config at $CfgPath"
New-Item -ItemType Directory -Force -Path $AppDir | Out-Null
if ($GenToken) { $Token = & $vpy -c "import secrets; print(secrets.token_urlsafe(32))" }
if (Test-Path $CfgPath) {
  $bak = "$CfgPath.bak.$([int][double]::Parse((Get-Date -UFormat %s)))"
  Copy-Item $CfgPath $bak
  Warn "Existing config backed up to $(Split-Path $bak -Leaf)"
}
$dbInstance = $Instance
@"
# SerenLoci config - generated by seren-loci-setup.ps1
# Full reference: see seren-loci.yaml.sample in the repo.
server:
  host: $LociHost          # 127.0.0.1 = this machine only; 0.0.0.0 = the LAN
  port: $Port
  bearer_token: "$Token"

storage:
  # THIS is your left brain - one sqlite file. Back it up; it survives upgrades.
  db_path: ~/.seren-loci$dbInstance/loci.db$(if ($Vector) {"`n  # Vector finder ON (-Vector). Comment these two out for the embedding-free floor.`n  embedding_model: sentence-transformers/all-MiniLM-L6-v2`n  embedding_device: cpu"})$(if ($Corp) {"`ntls:`n  # Route outbound TLS through the OS trust store (corp proxy boxes).`n  # Requires the [corp] extra (truststore). Logged at startup when active.`n  trust_system_store: true"})
"@ | Set-Content -Path $CfgPath -Encoding UTF8
Ok "Config written"

# -- 5b. launcher -----------------------------------------------------------
$launcher = "$AppDir\run-seren-loci.ps1"
"& `"$vpy`" -m seren_loci --config `"$CfgPath`"" | Set-Content -Path $launcher -Encoding UTF8
Ok "Launcher written: $launcher"

# -- 6. optional autostart ----------------------------------------------------
if ($Service) {
  Step "Installing the autostart service"
  $wrapper = Join-Path $ScriptDir "setup-loci-service.ps1"
  $core = Find-Upward "Generics\setup-seren-service.ps1"
  if ((Test-Path $wrapper) -and $core -and (Test-Path $core)) {
    & $wrapper -Instance $Instance
  } else {
    Warn "setup-loci-service.ps1 + setup-seren-service.ps1 not found in $ScriptDir."
    Warn "Keep the shared setup scripts together and run (elevated):"
    Warn "  .\setup-loci-service.ps1 -Instance '$Instance'"
  }
}

# -- done -------------------------------------------------------------------
$connectHost = if ($LociHost -eq "0.0.0.0") { "127.0.0.1" } else { $LociHost }
Write-Host ""
Write-Host "==========================================" -ForegroundColor Green
Write-Host "  SerenLoci is set up +" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green
if (-not $Service) {
  Write-Host "  Start it:        $launcher" -ForegroundColor Blue
  Write-Host "  (or directly:    $vpy -m seren_loci --config $CfgPath)" -ForegroundColor Blue
}
Write-Host "  Viewer:          http://${connectHost}:$Port/viewer" -ForegroundColor Blue
Write-Host "  VSCode plugin:   set serenLoci.endpoint to http://${connectHost}:$Port" -ForegroundColor Blue
if ($Token)  { Write-Host "  Bearer token:    $Token" -ForegroundColor Yellow }
if ($Mcp)    { Write-Host "  MCP endpoint:    http://${connectHost}:$Port/mcp/" -ForegroundColor Blue }
if ($Vector) { Write-Host "  Finder:          vector (sqlite-vec + all-MiniLM-L6-v2)" -ForegroundColor Blue }
if ($Corp)   { Write-Host "  TLS:             OS trust store (truststore injected at startup)" -ForegroundColor Blue }
Write-Host "Rip it and win. 🌭🔧" -ForegroundColor Green
