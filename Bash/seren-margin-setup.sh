#!/usr/bin/env bash
# ==========================================================================
#  seren-margin-setup.sh  -  one-shot SerenMargin installer (Linux + macOS)
#
#  Lives in D:\serenDaemon\SerenSetupScripts (the shared home for every
#  seren service's setup scripts). This script:
#    1. Finds a usable Python (3.10-3.12)
#    2. Makes a clean venv at ~/seren-venvs/margin  (Seren convention)
#    3. Installs seren-margin
#         - DEFAULT: builds a wheel from the SerenMargin repo checkout
#           (Margin isn't on PyPI yet, so local build is the floor)
#         - --wheel FILE       to install a prebuilt wheel
#         - --pypi             to pull from PyPI once it's published
#         - --repo/--ref       to pull a wheel from a GitHub release
#    4. Writes a friendly config at ~/seren-margin/seren-margin.yaml
#    5. Drops a run-seren-margin.sh launcher
#    6. (optional) installs an autostart service via setup-margin-service.sh
#
#  Defaults are SAFE: binds 127.0.0.1 (localhost only). Margin is PRIVATE
#  notes - it deliberately does NOT default to the LAN like Memory does.
#
#  USAGE
#    bash seren-margin-setup.sh                  # build from repo, local-only
#    bash seren-margin-setup.sh --service        # + autostart (sudo on linux)
#    bash seren-margin-setup.sh --wheel ./seren_margin-0.1.0-py3-none-any.whl
#    bash seren-margin-setup.sh --pypi           # once published
#    bash seren-margin-setup.sh --ref v0.1.0     # from a GitHub release tag
#
#  FLAGS
#    --port N         Port to listen on            (default 7421)
#    --host HOST      Bind address                 (default 127.0.0.1)
#    --repo-dir PATH  SerenMargin repo checkout    (default: sibling ../SerenMargin)
#    --wheel PATH     Install from a local .whl
#    --pypi           Install seren-margin from PyPI
#    --ref TAG        Pin to a GitHub release tag   (implies --repo if unset)
#    --repo SLUG      GitHub release repo           (default ChadRoesler/SerenMargin)
#    --service        Autostart via setup-margin-service.sh
#    --instance NAME  Instance name                 (default: "")
#    --venv PATH      Override venv location        (default ~/seren-venvs/margin)
#    -h, --help       This help
# ==========================================================================
set -euo pipefail

OS="$(uname -s)"
IS_MAC=false
[[ "$OS" == "Darwin" ]] && IS_MAC=true

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; B='\033[0;34m'; NC='\033[0m'
step() { echo -e "\n${B}==>${NC} $1"; }
ok()   { echo -e "${G}  ✓${NC} $1"; }
warn() { echo -e "${Y}  !${NC} $1"; }
die()  { echo -e "${R}ERROR:${NC} $1" >&2; exit 1; }

# -- where this script lives (shared dir); the repo is a sibling by default --
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"


# -- locate a file by walking UP the tree (reorg-robust; injected by fixup) ---
# Survives the Bash/Powershell/Generics split AND any future reorg - we never
# hardcode a relative hop, we search upward for the target.
find_upward() {
  local rel="$1" dir="${2:-$SCRIPT_DIR}"
  while [[ "$dir" != "/" && -n "$dir" ]]; do
    [[ -e "$dir/$rel" ]] && { echo "$dir/$rel"; return 0; }
    dir="$(dirname "$dir")"
  done
  return 1
}

# -- defaults ---------------------------------------------------------------
PORT=7421
HOST="127.0.0.1"          # localhost only. Private notes - safe by default.
REPO_DIR="$(find_upward "SerenMargin")"   # sibling checkout (build source)
WHEEL=""
USE_PYPI=false
REF=""
REPO=""
INSTALL_SERVICE=false
INSTANCE=""
VENV_DIR="$HOME/seren-venvs/margin"
APP_DIR="$HOME/seren-margin"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)      PORT="$2"; shift 2 ;;
    --host)      HOST="$2"; shift 2 ;;
    --repo-dir)  REPO_DIR="$2"; shift 2 ;;
    --wheel)     WHEEL="$2"; shift 2 ;;
    --pypi)      USE_PYPI=true; shift ;;
    --ref)       REF="$2"; shift 2 ;;
    --repo)      REPO="$2"; shift 2 ;;
    --service)   INSTALL_SERVICE=true; shift ;;
    --instance)  INSTANCE="$2"; shift 2 ;;
    --venv)      VENV_DIR="$2"; shift 2 ;;
    -h|--help)   sed -n '2,42p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           die "unknown flag: $1  (try --help)" ;;
  esac
done

VENV_DIR="$VENV_DIR$INSTANCE"
APP_DIR="$APP_DIR$INSTANCE"
CFG_PATH="$APP_DIR/seren-margin.yaml"
# Can't *connect* to 0.0.0.0 - use loopback for the health check + printed URLs.
CONNECT_HOST="$HOST"
[[ "$HOST" == "0.0.0.0" ]] && CONNECT_HOST="127.0.0.1"
if [[ -n "$INSTANCE" && "$PORT" == "7421" ]]; then
  warn "Instance '$INSTANCE' is using the default port 7421 - give each concurrent instance its own --port or they'll collide."
fi

echo -e "${G}==========================================${NC}"
$IS_MAC && echo -e "${G}  SerenMargin setup (macOS)${NC}" || echo -e "${G}  SerenMargin setup (Linux)${NC}"
echo -e "${G}==========================================${NC}"

# -- 1. find a usable Python ------------------------------------------------
step "Finding a usable Python (3.10-3.12)"
PYBIN=""
for cand in python3.12 python3.11 python3.10 python3 python; do
  if command -v "$cand" >/dev/null 2>&1; then
    ver="$("$cand" -c 'import sys; print("%d.%d"%sys.version_info[:2])' 2>/dev/null || echo "")"
    case "$ver" in
      3.10|3.11|3.12) PYBIN="$cand"; break ;;
    esac
  fi
done
if [[ -z "$PYBIN" ]]; then
  die "No Python 3.10-3.12 found.
  Install one, e.g.:
    macOS:          brew install python@3.12
    Debian/Ubuntu:  sudo apt install python3.12 python3.12-venv
    Fedora:         sudo dnf install python3.12
    Arch:           sudo pacman -S python"
fi
PYVER="$("$PYBIN" -c 'import sys; print("%d.%d.%d"%sys.version_info[:3])')"
ok "Using $PYBIN (Python $PYVER)"

# --ref implies a GitHub release; default the repo so `--ref vX` works alone.
[[ -n "$REF" && -z "$REPO" ]] && REPO="ChadRoesler/SerenMargin"

# -- 2. resolve what to install ---------------------------------------------
# Precedence: --wheel > --repo/--ref (GitHub) > --pypi > local build (default)
WHEEL_SRC=""
CLEANUP_WHEEL=false
if [[ -n "$WHEEL" ]]; then
  [[ -f "$WHEEL" ]] || die "wheel not found: $WHEEL"
  WHEEL_SRC="$WHEEL"
  ok "Installing from local wheel: $(basename "$WHEEL")"
elif [[ -n "$REPO" ]]; then
  step "Resolving the SerenMargin release from GitHub ($REPO)"
  command -v curl >/dev/null 2>&1 || die "curl is required to download from GitHub"
  api="https://api.github.com/repos/${REPO}/releases/${REF:+tags/$REF}"
  [[ -z "$REF" ]] && api="https://api.github.com/repos/${REPO}/releases/latest"
  json="$(curl -fsSL "$api" 2>/dev/null)" || die "GitHub API request failed ($api). Check the repo/tag and your network."
  read -r TAG WHL_URL < <("$PYBIN" - "$json" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
tag = data.get("tag_name", "?")
whl = ""
for a in data.get("assets", []):
    if a.get("name", "").endswith(".whl"):
        whl = a["browser_download_url"]; break
print(tag, whl)
PY
)
  [[ -n "$WHL_URL" && "$WHL_URL" != "None" ]] || die "No .whl asset in release '$TAG'. Pass --wheel instead."
  ok "Release $TAG  ($(basename "$WHL_URL"))"
  WHEEL_SRC="$(mktemp /tmp/seren_margin_XXXXXX.whl)"
  CLEANUP_WHEEL=true
  trap '[[ "$CLEANUP_WHEEL" == true ]] && rm -f "$WHEEL_SRC"' EXIT
  curl -fsSL "$WHL_URL" -o "$WHEEL_SRC" || die "download failed"
  ok "Downloaded"
elif $USE_PYPI; then
  WHEEL_SRC="seren-margin"
  ok "Installing the latest seren-margin from PyPI"
else
  # DEFAULT: build a wheel from the repo checkout. Margin isn't on PyPI yet.
  step "Building a wheel from the SerenMargin checkout"
  PKG_DIR="${REPO_DIR}/SerenMargin"   # nested package dir (repo/SerenMargin/)
  [[ -f "${PKG_DIR}/pyproject.toml" ]] || die "SerenMargin checkout not found at ${PKG_DIR}
  Point --repo-dir at your SerenMargin repo, or use --wheel / --pypi / --ref."
  BUILD_VENV="$(mktemp -d)/build-venv"
  "$PYBIN" -m venv "$BUILD_VENV"
  "$BUILD_VENV/bin/pip" install -q --upgrade pip build
  rm -f "${PKG_DIR}/dist/"*.whl 2>/dev/null || true
  "$BUILD_VENV/bin/python" -m build --wheel "$PKG_DIR"
  rm -rf "${BUILD_VENV%/*}"
  WHEEL_SRC="$(ls -t "${PKG_DIR}/dist/"*.whl 2>/dev/null | head -1 || true)"
  [[ -n "$WHEEL_SRC" && -f "$WHEEL_SRC" ]] || die "build completed but no wheel in ${PKG_DIR}/dist/"
  ok "Built $(basename "$WHEEL_SRC")"
fi

# -- 3. venv + install ------------------------------------------------------
step "Creating venv at $VENV_DIR"
if [[ -x "$VENV_DIR/bin/python" ]]; then
  warn "venv already exists - reusing it (will upgrade the package)"
else
  "$PYBIN" -m venv "$VENV_DIR" || die "venv creation failed (need the python3-venv package?)"
  ok "venv created"
fi
VPY="$VENV_DIR/bin/python"

step "Installing seren-margin"
"$VPY" -m pip install -q --upgrade pip
"$VPY" -m pip install -q --upgrade "$WHEEL_SRC" || die "pip install failed - see output above"
ok "Installed"

# -- 4. sanity check (import + the manifest asset) --------------------------
step "Sanity-checking the install"
CHECK="$("$VPY" - <<'PY'
import pathlib
try:
    import seren_margin
except Exception as e:
    print(f"IMPORT_FAILED: {e}"); raise SystemExit
m = pathlib.Path(seren_margin.__file__).parent / "mcp-manifest.yaml"
print("OK" if m.exists() else "MANIFEST_MISSING")
PY
)"
case "$CHECK" in
  OK) ok "Package imports and the MCP manifest asset is present" ;;
  MANIFEST_MISSING) warn "Installed but mcp-manifest.yaml is missing - /mcp-manifest will 500 (package-data regression)" ;;
  *) die "Install looks broken: $CHECK" ;;
esac

# -- 5. config --------------------------------------------------------------
step "Writing config at $CFG_PATH"
mkdir -p "$APP_DIR"
if [[ -f "$CFG_PATH" ]]; then
  bak="$CFG_PATH.bak.$(date +%s)"
  cp "$CFG_PATH" "$bak"
  warn "Existing config backed up to $(basename "$bak")"
fi
cat > "$CFG_PATH" <<YAML
# SerenMargin config - generated by seren-margin-setup.sh
# Full reference: see seren-margin.yaml.sample in the repo.
#
# Lego framing: 'server:' is what SerenMargin reads. A future 'tools:' block
# is reserved for the plug-and-play MCP tool layer (a different reader).
server:
  host: ${HOST}          # 127.0.0.1 = localhost only (private notes default)
  port: ${PORT}

# Where the sqlite notes db lives. ~ expands to your home dir. THIS is your
# private corkboard - back it up, it survives package upgrades untouched.
  db_path: ~/.seren-margin${INSTANCE}/notes.db
YAML
ok "Config written"

# -- 5b. launcher -----------------------------------------------------------
LAUNCHER="$APP_DIR/run-seren-margin.sh"
cat > "$LAUNCHER" <<LAUNCHEOF
#!/usr/bin/env bash
exec "$VPY" -m seren_margin --config "$CFG_PATH"
LAUNCHEOF
chmod +x "$LAUNCHER"
ok "Launcher written: $LAUNCHER"

# -- 6. optional autostart ----------------------------------------------------
if $INSTALL_SERVICE; then
  step "Installing the autostart service"
  WRAPPER="$SCRIPT_DIR/setup-margin-service.sh"
  CORE="$(find_upward "Generics/setup-seren-service.sh")"
  if [[ -f "$WRAPPER" && -f "$CORE" ]]; then
    bash "$WRAPPER" --instance "$INSTANCE" || die "service install failed - see output above"
  else
    warn "setup-margin-service.sh + setup-seren-service.sh not found in $SCRIPT_DIR."
    warn "Keep the shared setup scripts together and run:"
    warn "  bash setup-margin-service.sh --instance '$INSTANCE'"
  fi
fi

# -- done -------------------------------------------------------------------
echo
echo -e "${G}==========================================${NC}"
echo -e "${G}  SerenMargin is set up ✓${NC}"
echo -e "${G}==========================================${NC}"
if ! $INSTALL_SERVICE; then
  echo -e "  Start it:        ${B}$LAUNCHER${NC}"
  echo -e "  (or directly:    ${B}$VPY -m seren_margin --config $CFG_PATH${NC})"
fi
echo -e "  Health:          ${B}http://${CONNECT_HOST}:${PORT}/health${NC}"
echo -e "  Engine-check:    ${B}http://${CONNECT_HOST}:${PORT}/notes/stats${NC}  (content-blind)"
echo -e "  MCP manifest:    ${B}http://${CONNECT_HOST}:${PORT}/mcp-manifest${NC}"
echo
echo -e "  ${Y}Private by default, transparent in mechanism, opt-in by deploy.${NC}"
echo -e "${G}Rip it and win. 🌭🔧${NC}"
