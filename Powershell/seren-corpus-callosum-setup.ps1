<#
══════════════════════════════════════════════════════════════════════════
  seren-corpus-callosum-setup.ps1  -  one-shot SCC installer (Windows)

  Lives in D:\serenDaemon\SerenSetupScripts (shared home for setup scripts).
  This script:
    1. Finds a usable Python (3.10+; no upper cap - SCC never pulls torch)
    2. Makes a clean venv at %USERPROFILE%\seren-venvs\callosum
    3. Installs seren-corpus-callosum
         - DEFAULT: from PyPI (seren-corpus-callosum is published)
         - -Wheel FILE   to install a prebuilt wheel
         - -Ref TAG      to pull a wheel from a GitHub release
         - -Mcp          install the [mcp] extra - the /mcp route + `search` tool.
                         Without it SCC runs HTTP-only and the MCP surface never
                         mounts.
         - -Corp         route TLS through the OS trust store (corp proxy). Matters
                         for SCC's OUTBOUND calls to any https store.
    4. Writes a config at %USERPROFILE%\seren-corpus-callosum\seren-corpus-callosum.yaml
         (pre-wired to fan your local hemispheres: memory 7420 + loci 7422)
    5. Drops a run-seren-corpus-callosum.ps1 launcher
    6. (optional) installs an NSSM autostart service via setup-corpus-callosum-service.ps1

  Defaults are SAFE: binds 127.0.0.1 (this machine only), no auth.

  USAGE
    powershell -ExecutionPolicy Bypass -File .\seren-corpus-callosum-setup.ps1
    powershell -ExecutionPolicy Bypass -File .\seren-corpus-callosum-setup.ps1 -Mcp
    powershell -ExecutionPolicy Bypass -File .\seren-corpus-callosum-setup.ps1 -GenToken
    powershell -ExecutionPolicy Bypass -File .\seren-corpus-callosum-setup.ps1 -Service
    powershell -ExecutionPolicy Bypass -File .\seren-corpus-callosum-setup.ps1 -Corp
══════════════════════════════════════════════════════════════════════════
#>
[CmdletBinding()]
param(
  [int]    $Port      = 7423,
  [string] $SccHost   = "127.0.0.1",   # NOT $Host - that's a reserved automatic var
  [string] $Token     = "",
  [switch] $GenToken,
  [string] $Wheel     = "",
  [string] $Ref       = "",
  [string] $Repo      = "",
  [switch] $Service,
  [switch] $Mcp,
  [switch] $Corp,
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

if (-not $VenvDir) { $VenvDir = "$env:USERPROFILE\seren-venvs\callosum" }

$VenvDir = "$VenvDir$Instance"
$AppDir  = "$env:USERPROFILE\seren-corpus-callosum$Instance"
$CfgPath = "$AppDir\seren-corpus-callosum.yaml"
if ($Instance -and $Port -eq 7423) {
  Warn "Instance '$Instance' is using the default port 7423 - give each concurrent instance its own -Port or they'll collide."
}

Write-Host "==========================================" -ForegroundColor Green
Write-Host "  SerenCorpusCallosum setup (Windows)" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green

# -- 1. find a usable Python ------------------------------------------------
# No upper bound: SCC is embedder-agnostic and never pulls torch, so 3.13 is
# fine here (unlike loci/memory, which cap <3.13 for their [vector] extra).
Step "Finding a usable Python (3.10+)"
$pyBin = $null
foreach ($cand in @("python", "py -3.13", "py -3.12", "py -3.11", "py -3.10")) {
  $parts = $cand.Split(" ")
  $exe = $parts[0]
  if (Get-Command $exe -ErrorAction SilentlyContinue) {
    try {
      $ver = & $exe $parts[1..($parts.Length-1)] -c "import sys; print('%d.%d'%sys.version_info[:2])" 2>$null
    } catch { $ver = "" }
    if ($ver -match '^3\.(10|11|12|13)$') { $pyBin = $cand; break }
  }
}
if (-not $pyBin) { Die "No Python 3.10+ found. Install from python.org or 'winget install Python.Python.3.12'." }
$pyArr = $pyBin.Split(" ")
$pyExe = $pyArr[0]; $pyArgs = $pyArr[1..($pyArr.Length-1)]
$pyVer = & $pyExe $pyArgs -c "import sys; print('%d.%d.%d'%sys.version_info[:3])"
Ok "Using '$pyBin' (Python $pyVer)"

if ($Ref -and -not $Repo) { $Repo = "ChadRoesler/SerenCorpusCallosum" }

# -- 2. resolve what to install ---------------------------------------------
# Precedence: -Wheel > -Repo/-Ref (GitHub) > PyPI (default)
$wheelSrc = $null
$cleanupWheel = $false
if ($Wheel) {
  if (-not (Test-Path $Wheel)) { Die "wheel not found: $Wheel" }
  $wheelSrc = (Resolve-Path $Wheel).Path
  Ok "Installing from local wheel: $(Split-Path $wheelSrc -Leaf)"
} elseif ($Repo) {
  Step "Resolving the SerenCorpusCallosum release from GitHub ($Repo)"
  $api = if ($Ref) { "https://api.github.com/repos/$Repo/releases/tags/$Ref" }
         else      { "https://api.github.com/repos/$Repo/releases/latest" }
  try { $rel = Invoke-RestMethod -Uri $api -Headers @{ "User-Agent" = "seren-corpus-callosum-setup" } }
  catch { Die "GitHub API request failed ($api). Check the repo/tag and your network." }
  $asset = $rel.assets | Where-Object { $_.name -like "*.whl" } | Select-Object -First 1
  if (-not $asset) { Die "No .whl asset in release '$($rel.tag_name)'. Use -Wheel instead." }
  Ok "Release $($rel.tag_name)  ($($asset.name))"
  $wheelSrc = Join-Path $env:TEMP $asset.name
  $cleanupWheel = $true
  Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $wheelSrc -UseBasicParsing
  Ok "Downloaded"
} else {
  $wheelSrc = "seren-corpus-callosum"
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

# [mcp]/[corp] extras must be glued to the spec with no space. Build the suffix
# ([mcp], [corp], [mcp,corp], or none) then append it to the wheel/PyPI name.
# (No [vector] - the callosum embeds nothing, so there's no such extra.)
$extras = if ($Mcp -and $Corp) { "[mcp,corp]" }
          elseif ($Mcp)        { "[mcp]" }
          elseif ($Corp)       { "[corp]" }
          else                 { "" }
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
Step ("Installing seren-corpus-callosum" + $extras)
& $vpy -m pip install -q --upgrade pip
& $vpy -m pip install -q --upgrade @corpArgs $installSpec
if ($LASTEXITCODE -ne 0) { Die "pip install failed - see output above" }
Ok "Installed"
if ($cleanupWheel) { Remove-Item -Force $wheelSrc -ErrorAction SilentlyContinue }

# -- 4. sanity check (import; + verify the MCP extra actually landed) --------
# No viewer asset to check (SCC owns no store / no UI yet). IF -Mcp was asked,
# verify `import mcp` works - the silent failure mode is: extra not pulled ->
# app.py falls to HTTP-only -> the `search` tool never mounts. Catch it loudly.
Step "Sanity-checking the install"
$wantMcp = if ($Mcp) { "1" } else { "0" }
$check = & $vpy -c @"
import sys
want_mcp = "$wantMcp" == "1"
try:
    import seren_corpus_callosum
except Exception as e:
    print(f'IMPORT_FAILED: {e}'); raise SystemExit
if want_mcp:
    try:
        import mcp
    except Exception:
        print('MCP_MISSING'); raise SystemExit
    print('OK_MCP')
else:
    print('OK')
"@
switch -Wildcard ($check) {
  "OK"          { Ok "Package imports cleanly" }
  "OK_MCP"      { Ok "Package imports + the MCP SDK is present (the /mcp surface will mount)" }
  "MCP_MISSING" { Die "Package installed but the [mcp] extra didn't land - 'import mcp' failed. The /mcp surface would silently NOT mount. Re-run, or: $vpy -m pip install 'seren-corpus-callosum[mcp]'" }
  default       { Die "Install looks broken: $check" }
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
@"
# SerenCorpusCallosum config - generated by seren-corpus-callosum-setup.ps1
# Full reference: see seren-corpus-callosum.yaml.sample in the repo.
server:
  host: $SccHost          # 127.0.0.1 = this machine only; 0.0.0.0 = the LAN
  port: $Port
  bearer_token: "$Token"

federation:
  # The callosum fans these stores and RRF-merges the results. A down/slow store
  # is skipped for that call - it degrades the result, never crashes the fan.
  # RRF reads only rank ordering, so the merge is correct across different
  # embedders. weight = trust multiplier (default 1.0); floor = pre-fusion
  # relevance floor (default 0.0).
  stores:
    - name: memory          # right brain - episodic memory
      type: seren_memory
      url: http://127.0.0.1:7420
    - name: loci            # left brain - keyed facts
      type: seren_loci
      url: http://127.0.0.1:7422$(if ($Corp) {"`n`ntls:`n  # Route outbound TLS through the OS trust store (corp proxy boxes).`n  # Requires the [corp] extra (truststore). Logged at startup when active.`n  trust_system_store: true"})
"@ | Set-Content -Path $CfgPath -Encoding UTF8
Ok "Config written (pre-wired to fan memory:7420 + loci:7422)"

# -- 5b. launcher -----------------------------------------------------------
$launcher = "$AppDir\run-seren-corpus-callosum.ps1"
"& `"$vpy`" -m seren_corpus_callosum --config `"$CfgPath`"" | Set-Content -Path $launcher -Encoding UTF8
Ok "Launcher written: $launcher"

# -- 6. optional autostart ----------------------------------------------------
if ($Service) {
  Step "Installing the autostart service"
  $wrapper = Join-Path $ScriptDir "setup-corpus-callosum-service.ps1"
  $core = Find-Upward "Generics\setup-seren-service.ps1"
  if ((Test-Path $wrapper) -and $core -and (Test-Path $core)) {
    & $wrapper -Instance $Instance
  } else {
    Warn "setup-corpus-callosum-service.ps1 + setup-seren-service.ps1 not found in $ScriptDir."
    Warn "Keep the shared setup scripts together and run (elevated):"
    Warn "  .\setup-corpus-callosum-service.ps1 -Instance '$Instance'"
  }
}

# -- done -------------------------------------------------------------------
$connectHost = if ($SccHost -eq "0.0.0.0") { "127.0.0.1" } else { $SccHost }
Write-Host ""
Write-Host "==========================================" -ForegroundColor Green
Write-Host "  SerenCorpusCallosum is set up +" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green
if (-not $Service) {
  Write-Host "  Start it:        $launcher" -ForegroundColor Blue
  Write-Host "  (or directly:    $vpy -m seren_corpus_callosum --config $CfgPath)" -ForegroundColor Blue
}
Write-Host "  Fan/search:      POST http://${connectHost}:$Port/search" -ForegroundColor Blue
Write-Host "  Health:          http://${connectHost}:$Port/health" -ForegroundColor Blue
Write-Host "  VSCode plugin:   set the endpoint to http://${connectHost}:$Port" -ForegroundColor Blue
if ($Token) { Write-Host "  Bearer token:    $Token" -ForegroundColor Yellow }
if ($Mcp)   { Write-Host "  MCP endpoint:    http://${connectHost}:$Port/mcp/  (tool: search)" -ForegroundColor Blue }
if ($Corp)  { Write-Host "  TLS:             OS trust store (truststore injected at startup)" -ForegroundColor Blue }
Write-Host "Rip it and win. 🌭🔧" -ForegroundColor Green
