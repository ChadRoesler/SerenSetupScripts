<#
══════════════════════════════════════════════════════════════════════════
  seren-margin-setup.ps1  -  one-shot SerenMargin installer (Windows)

  Lives in D:\serenDaemon\SerenSetupScripts (shared home for setup scripts).
  This script:
    1. Finds a usable Python (3.10-3.12)
    2. Makes a clean venv at %USERPROFILE%\seren-venvs\margin
    3. Installs seren-margin
         - DEFAULT: builds a wheel from the SerenMargin repo checkout
           (Margin isn't on PyPI yet)
         - -Wheel FILE   to install a prebuilt wheel
         - -Pypi         to pull from PyPI once published
         - -Ref TAG      to pull a wheel from a GitHub release
    4. Writes a config at %USERPROFILE%\seren-margin\seren-margin.yaml
    5. Drops a run-seren-margin.ps1 launcher
    6. (optional) installs an NSSM autostart service via setup-margin-service.ps1

  Defaults are SAFE: binds 127.0.0.1 (localhost only). Margin is PRIVATE
  notes - it does NOT default to the LAN like Memory.

  USAGE
    powershell -ExecutionPolicy Bypass -File .\seren-margin-setup.ps1
    powershell -ExecutionPolicy Bypass -File .\seren-margin-setup.ps1 -Service
    powershell -ExecutionPolicy Bypass -File .\seren-margin-setup.ps1 -Wheel .\seren_margin-0.1.0-py3-none-any.whl
    powershell -ExecutionPolicy Bypass -File .\seren-margin-setup.ps1 -Pypi
══════════════════════════════════════════════════════════════════════════
#>
[CmdletBinding()]
param(
  [int]    $Port      = 7421,
  [string] $MarginHost = "127.0.0.1",   # NOT $Host - that's a reserved automatic var
  [string] $RepoDir   = "",             # SerenMargin checkout; default sibling ..\SerenMargin
  [string] $Wheel     = "",
  [switch] $Pypi,
  [string] $Ref       = "",
  [string] $Repo      = "",
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

if (-not $RepoDir) { $RepoDir = Find-Upward "SerenMargin" }
if (-not $VenvDir) { $VenvDir = "$env:USERPROFILE\seren-venvs\margin" }

$VenvDir = "$VenvDir$Instance"
$AppDir  = "$env:USERPROFILE\seren-margin$Instance"
$CfgPath = "$AppDir\seren-margin.yaml"
if ($Instance -and $Port -eq 7421) {
  Warn "Instance '$Instance' is using the default port 7421 - give each concurrent instance its own -Port or they'll collide."
}

Write-Host "==========================================" -ForegroundColor Green
Write-Host "  SerenMargin setup (Windows)" -ForegroundColor Green
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
if (-not $pyBin) { Die "No Python 3.10-3.12 found. Install from python.org or 'winget install Python.Python.3.12'." }
$pyArr = $pyBin.Split(" ")
$pyExe = $pyArr[0]; $pyArgs = $pyArr[1..($pyArr.Length-1)]
$pyVer = & $pyExe $pyArgs -c "import sys; print('%d.%d.%d'%sys.version_info[:3])"
Ok "Using '$pyBin' (Python $pyVer)"

if ($Ref -and -not $Repo) { $Repo = "ChadRoesler/SerenMargin" }

# -- 2. resolve what to install ---------------------------------------------
# Precedence: -Wheel > -Repo/-Ref (GitHub) > -Pypi > local build (default)
$wheelSrc = $null
$cleanupWheel = $false
if ($Wheel) {
  if (-not (Test-Path $Wheel)) { Die "wheel not found: $Wheel" }
  $wheelSrc = (Resolve-Path $Wheel).Path
  Ok "Installing from local wheel: $(Split-Path $wheelSrc -Leaf)"
} elseif ($Repo) {
  Step "Resolving the SerenMargin release from GitHub ($Repo)"
  $api = if ($Ref) { "https://api.github.com/repos/$Repo/releases/tags/$Ref" }
         else      { "https://api.github.com/repos/$Repo/releases/latest" }
  try { $rel = Invoke-RestMethod -Uri $api -Headers @{ "User-Agent" = "seren-margin-setup" } }
  catch { Die "GitHub API request failed ($api). Check the repo/tag and your network." }
  $asset = $rel.assets | Where-Object { $_.name -like "*.whl" } | Select-Object -First 1
  if (-not $asset) { Die "No .whl asset in release '$($rel.tag_name)'. Use -Wheel instead." }
  Ok "Release $($rel.tag_name)  ($($asset.name))"
  $wheelSrc = Join-Path $env:TEMP $asset.name
  $cleanupWheel = $true
  Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $wheelSrc -UseBasicParsing
  Ok "Downloaded"
} elseif ($Pypi) {
  $wheelSrc = "seren-margin"
  Ok "Installing the latest seren-margin from PyPI"
} else {
  # DEFAULT: build a wheel from the repo checkout.
  Step "Building a wheel from the SerenMargin checkout"
  $pkgDir = Join-Path $RepoDir "SerenMargin"   # nested package dir
  if (-not (Test-Path (Join-Path $pkgDir "pyproject.toml"))) {
    Die "SerenMargin checkout not found at $pkgDir`n  Point -RepoDir at your SerenMargin repo, or use -Wheel / -Pypi / -Ref."
  }
  $buildVenv = Join-Path ([System.IO.Path]::GetTempPath()) ("seren-build-" + [guid]::NewGuid().ToString("N").Substring(0,8))
  & $pyExe $pyArgs -m venv $buildVenv
  & "$buildVenv\Scripts\python.exe" -m pip install -q --upgrade pip build
  Get-ChildItem (Join-Path $pkgDir "dist\*.whl") -ErrorAction SilentlyContinue | Remove-Item -Force
  & "$buildVenv\Scripts\python.exe" -m build --wheel $pkgDir
  Remove-Item -Recurse -Force $buildVenv
  $wheelSrc = (Get-ChildItem (Join-Path $pkgDir "dist\*.whl") | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
  if (-not $wheelSrc) { Die "build completed but no wheel found in $pkgDir\dist\" }
  Ok "Built $(Split-Path $wheelSrc -Leaf)"
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

Step "Installing seren-margin"
& $vpy -m pip install -q --upgrade pip
& $vpy -m pip install -q --upgrade $wheelSrc
if ($LASTEXITCODE -ne 0) { Die "pip install failed - see output above" }
Ok "Installed"
if ($cleanupWheel) { Remove-Item -Force $wheelSrc -ErrorAction SilentlyContinue }

# -- 4. sanity check --------------------------------------------------------
Step "Sanity-checking the install"
$check = & $vpy -c @"
import pathlib
try:
    import seren_margin
except Exception as e:
    print(f'IMPORT_FAILED: {e}'); raise SystemExit
m = pathlib.Path(seren_margin.__file__).parent / 'mcp-manifest.yaml'
print('OK' if m.exists() else 'MANIFEST_MISSING')
"@
switch -Wildcard ($check) {
  "OK"               { Ok "Package imports and the MCP manifest asset is present" }
  "MANIFEST_MISSING" { Warn "Installed but mcp-manifest.yaml is missing - /mcp-manifest will 500" }
  default            { Die "Install looks broken: $check" }
}

# -- 5. config --------------------------------------------------------------
Step "Writing config at $CfgPath"
New-Item -ItemType Directory -Force -Path $AppDir | Out-Null
if (Test-Path $CfgPath) {
  $bak = "$CfgPath.bak.$([int][double]::Parse((Get-Date -UFormat %s)))"
  Copy-Item $CfgPath $bak
  Warn "Existing config backed up to $(Split-Path $bak -Leaf)"
}
$dbInstance = $Instance
@"
# SerenMargin config - generated by seren-margin-setup.ps1
# Full reference: see seren-margin.yaml.sample in the repo.
#
# Lego framing: 'server:' is what SerenMargin reads. A future 'tools:' block
# is reserved for the plug-and-play MCP tool layer (a different reader).
server:
  host: $MarginHost          # 127.0.0.1 = localhost only (private notes default)
  port: $Port
  db_path: ~/.seren-margin$dbInstance/notes.db
"@ | Set-Content -Path $CfgPath -Encoding UTF8
Ok "Config written"

# -- 5b. launcher -----------------------------------------------------------
$launcher = "$AppDir\run-seren-margin.ps1"
"& `"$vpy`" -m seren_margin --config `"$CfgPath`"" | Set-Content -Path $launcher -Encoding UTF8
Ok "Launcher written: $launcher"

# -- 6. optional autostart ----------------------------------------------------
if ($Service) {
  Step "Installing the autostart service"
  $wrapper = Join-Path $ScriptDir "setup-margin-service.ps1"
  $core = Find-Upward "Generics\setup-seren-service.ps1"
  if ((Test-Path $wrapper) -and (Test-Path $core)) {
    & $wrapper -Instance $Instance
  } else {
    Warn "setup-margin-service.ps1 + setup-seren-service.ps1 not found in $ScriptDir."
    Warn "Keep the shared setup scripts together and run (elevated):"
    Warn "  .\setup-margin-service.ps1 -Instance '$Instance'"
  }
}

# -- done -------------------------------------------------------------------
$connectHost = if ($MarginHost -eq "0.0.0.0") { "127.0.0.1" } else { $MarginHost }
Write-Host ""
Write-Host "==========================================" -ForegroundColor Green
Write-Host "  SerenMargin is set up +" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green
if (-not $Service) {
  Write-Host "  Start it:        $launcher" -ForegroundColor Blue
  Write-Host "  (or directly:    $vpy -m seren_margin --config $CfgPath)" -ForegroundColor Blue
}
Write-Host "  Health:          http://${connectHost}:$Port/health" -ForegroundColor Blue
Write-Host "  Engine-check:    http://${connectHost}:$Port/notes/stats  (content-blind)" -ForegroundColor Blue
Write-Host "  MCP manifest:    http://${connectHost}:$Port/mcp-manifest" -ForegroundColor Blue
Write-Host ""
Write-Host "  Private by default, transparent in mechanism, opt-in by deploy." -ForegroundColor Yellow
Write-Host "Rip it and win. 🌭🔧" -ForegroundColor Green
