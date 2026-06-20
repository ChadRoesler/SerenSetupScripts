#!/usr/bin/env bash
# ==========================================================================
#  seren-loci-setup.sh  -  one-shot SerenLoci installer (Linux + macOS)
#
#  Lives in D:\serenDaemon\SerenSetupScripts (the shared home for every
#  seren service's setup scripts). This script:
#    1. Finds a usable Python (3.10-3.12)
#    2. Makes a clean venv at ~/seren-venvs/loci  (Seren convention)
#    3. Installs seren-loci
#         - DEFAULT: from PyPI (seren-loci is published)
#         - --wheel FILE       to install a prebuilt wheel
#         - --ref/--repo       to pull a wheel from a GitHub release
#    4. Writes a friendly config at ~/seren-loci/seren-loci.yaml
#    5. Drops a run-seren-loci.sh launcher
#    6. (optional) installs an autostart service via setup-loci-service.sh
#
#  The defaults are SAFE: binds 127.0.0.1 (this machine only), no auth.
#  Crank the flags if you want it on the network or behind a token.
#
#  USAGE
#    bash seren-loci-setup.sh                 # easy mode, PyPI, local-only
#    bash seren-loci-setup.sh --gen-token     # generate a bearer token
#    bash seren-loci-setup.sh --service       # + autostart (sudo on linux)
#    bash seren-loci-setup.sh --wheel ./seren_loci-0.1.0-py3-none-any.whl
#    bash seren-loci-setup.sh --ref v0.4.0    # pin to a GitHub release tag
#    bash seren-loci-setup.sh --host 0.0.0.0  # expose on the LAN (careful!)
#    bash seren-loci-setup.sh --mcp           # install the [mcp] extra
#    bash seren-loci-setup.sh --vector        # install the [vector] extra
#    bash seren-loci-setup.sh --corp          # OS trust store (corp proxy)
#
#  FLAGS
#    --port N         Port to listen on            (default 7422)
#    --host HOST      Bind address                 (default 127.0.0.1)
#    --token TOKEN    Set a bearer token
#    --gen-token      Generate a random bearer token for you
#    --wheel PATH     Install from a local .whl instead of PyPI
#    --ref TAG        Pin to a GitHub release tag   (implies --repo if unset)
#    --repo SLUG      GitHub release repo           (default: install from PyPI)
#    --service        Autostart via setup-loci-service.sh (systemd/launchd)
#    --mcp            Install the [mcp] extra (the /mcp route for a connected model)
#    --vector         Install the [vector] extra (sqlite-vec + sentence-transformers)
#                     for the associative finder, AND set storage.embedding_model
#                     so the vector path is actually live (not just installed).
#    --corp           Route TLS through the OS trust store (corp proxy boxes).
#                     Installs the [corp] extra + bootstraps pip via truststore,
#                     and sets tls.trust_system_store: true in the config.
#    --instance NAME  Instance name                 (default: "")
#    --venv PATH      Override venv location        (default ~/seren-venvs/loci)
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
PORT=7422                 # loci's port (memory 7420, margin 7421, loci 7422)
HOST="127.0.0.1"          # this machine only. Safe by default.
TOKEN=""
GEN_TOKEN=false
WHEEL=""
REF=""
REPO=""
INSTALL_SERVICE=false
MCP=false
CORP=false
VECTOR=false
INSTANCE=""
VENV_DIR="$HOME/seren-venvs/loci"
APP_DIR="$HOME/seren-loci"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)      PORT="$2"; shift 2 ;;
    --host)      HOST="$2"; shift 2 ;;
    --token)     TOKEN="$2"; shift 2 ;;
    --gen-token) GEN_TOKEN=true; shift ;;
    --wheel)     WHEEL="$2"; shift 2 ;;
    --ref)       REF="$2"; shift 2 ;;
    --repo)      REPO="$2"; shift 2 ;;
    --service)   INSTALL_SERVICE=true; shift ;;
    --mcp)       MCP=true; shift ;;
    --corp)      CORP=true; shift ;;
    --vector)    VECTOR=true; shift ;;
    --instance)  INSTANCE="$2"; shift 2 ;;
    --venv)      VENV_DIR="$2"; shift 2 ;;
    -h|--help)   sed -n '2,52p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           die "unknown flag: $1  (try --help)" ;;
  esac
done

VENV_DIR="$VENV_DIR$INSTANCE"
APP_DIR="$APP_DIR$INSTANCE"
CFG_PATH="$APP_DIR/seren-loci.yaml"
CONNECT_HOST="$HOST"
[[ "$HOST" == "0.0.0.0" ]] && CONNECT_HOST="127.0.0.1"
if [[ -n "$INSTANCE" && "$PORT" == "7422" ]]; then
  warn "Instance '$INSTANCE' is using the default port 7422 - give each concurrent instance its own --port or they'll collide."
fi

echo -e "${G}==========================================${NC}"
$IS_MAC && echo -e "${G}  SerenLoci setup (macOS)${NC}" || echo -e "${G}  SerenLoci setup (Linux)${NC}"
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
    Arch:           sudo pacman -S python
  (Avoid 3.13+ for now - the optional [vector] extra pulls torch, which has no
   3.13 wheels yet. The dep-free floor would run on 3.13, but we cap to keep
   'pip install seren-loci[vector]' resolving cleanly.)"
fi
PYVER="$("$PYBIN" -c 'import sys; print("%d.%d.%d"%sys.version_info[:3])')"
ok "Using $PYBIN (Python $PYVER)"

[[ -n "$REF" && -z "$REPO" ]] && REPO="ChadRoesler/SerenLoci"

# -- 2. resolve the wheel to install ----------------------------------------
WHEEL_SRC=""
CLEANUP_WHEEL=false
if [[ -n "$WHEEL" ]]; then
  [[ -f "$WHEEL" ]] || die "wheel not found: $WHEEL"
  WHEEL_SRC="$WHEEL"
  ok "Installing from local wheel: $(basename "$WHEEL")"
elif [[ -n "$REPO" ]]; then
  step "Resolving the SerenLoci release from GitHub ($REPO)"
  command -v curl >/dev/null 2>&1 || die "curl is required to download from GitHub (sudo apt install curl)"
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
  [[ -n "$WHL_URL" && "$WHL_URL" != "None" ]] || die "No .whl asset in release '$TAG'. Pass --wheel to install a local file instead."
  ok "Release $TAG  ($(basename "$WHL_URL"))"
  WHEEL_SRC="$(mktemp /tmp/seren_loci_XXXXXX.whl)"
  CLEANUP_WHEEL=true
  trap '[[ "$CLEANUP_WHEEL" == true ]] && rm -f "$WHEEL_SRC"' EXIT
  curl -fsSL "$WHL_URL" -o "$WHEEL_SRC" || die "download failed"
  ok "Downloaded"
else
  WHEEL_SRC="seren-loci"  # latest from PyPI
  ok "No wheel or GitHub ref specified - will install the latest from PyPI"
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

# When --corp: pip 24.2+ can use the OS trust store for its OWN TLS during the
# install (so fetching deps through a corp TLS-intercepting proxy works). Older
# pip doesn't have the feature - we just skip the flag (the [corp] extra still
# installs if the proxy isn't intercepting PyPI itself).
pip_corp_args() {
  $CORP || return 0
  local pipver major minor
  pipver="$("$VPY" -m pip --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)"
  major="${pipver%%.*}"; minor="${pipver#*.}"
  if (( major > 24 || (major == 24 && minor >= 2) )); then
    echo "--use-feature=truststore"
  fi
}

# Build the extras suffix from any combination of mcp / corp / vector.
EXTRAS_LIST=()
$MCP    && EXTRAS_LIST+=("mcp")
$CORP   && EXTRAS_LIST+=("corp")
$VECTOR && EXTRAS_LIST+=("vector")
EXTRAS=""
if [[ ${#EXTRAS_LIST[@]} -gt 0 ]]; then
  EXTRAS="[$(IFS=,; echo "${EXTRAS_LIST[*]}")]"
fi
CORP_ARGS="$(pip_corp_args)"
step "Installing seren-loci${EXTRAS}  (web stack$( $VECTOR && echo " + sqlite-vec + sentence-transformers/torch" )$( $MCP && echo " + the MCP SDK" )$( $CORP && echo " + truststore" ))"
"$VPY" -m pip install -q --upgrade pip
# shellcheck disable=SC2086  # CORP_ARGS is intentionally word-split (0 or 1 flag)
"$VPY" -m pip install -q --upgrade $CORP_ARGS "${WHEEL_SRC}${EXTRAS}" || die "pip install failed - see output above"
ok "Installed"

# -- 4. sanity check (import + the viewer asset that's bitten us before) -----
step "Sanity-checking the install"
CHECK="$("$VPY" - <<'PY'
import pathlib
try:
    import seren_loci
except Exception as e:
    print(f"IMPORT_FAILED: {e}"); raise SystemExit
v = pathlib.Path(seren_loci.__file__).parent / "viewer" / "loci.html"
print("OK" if v.exists() else "VIEWER_MISSING")
PY
)"
case "$CHECK" in
  OK) ok "Package imports and the Halls viewer asset is present" ;;
  VIEWER_MISSING) warn "Package installed but loci.html is missing - /viewer will 404 (wheel-packaging regression)" ;;
  *) die "Install looks broken: $CHECK" ;;
esac

# -- 5. config --------------------------------------------------------------
step "Writing config at $CFG_PATH"
mkdir -p "$APP_DIR"
$GEN_TOKEN && TOKEN="$("$VPY" -c 'import secrets; print(secrets.token_urlsafe(32))')"
if [[ -f "$CFG_PATH" ]]; then
  bak="$CFG_PATH.bak.$(date +%s)"
  cp "$CFG_PATH" "$bak"
  warn "Existing config backed up to $(basename "$bak")"
fi
cat > "$CFG_PATH" <<YAML
# SerenLoci config - generated by seren-loci-setup.sh
# Full reference: see seren-loci.yaml.sample in the repo.
server:
  host: ${HOST}          # 127.0.0.1 = this machine only; 0.0.0.0 = the LAN
  port: ${PORT}
  # Empty = no auth (fine for local). A token requires
  #   Authorization: Bearer <token>  on every route except /, /health, /viewer.
  bearer_token: "${TOKEN}"

storage:
  # ~ expands to your home dir. THIS is your left brain - one sqlite file.
  # Back it up; it survives package upgrades untouched.
  db_path: ~/.seren-loci${INSTANCE}/loci.db
$( $VECTOR && printf '  # Vector finder ON (--vector). An embedder turns key+value+why into\n  # vectors for the associative jump. Needs the [vector] extra. Comment these\n  # two lines out to run the embedding-free floor (exact + FTS5 lexical).\n  embedding_model: sentence-transformers/all-MiniLM-L6-v2\n  embedding_device: cpu\n' )
$( $CORP && printf '\ntls:\n  # Route outbound TLS through the OS trust store (corp proxy boxes).\n  # Requires the [corp] extra (truststore). Logged at startup when active.\n  trust_system_store: true\n' )
YAML
[[ -n "$TOKEN" ]] && chmod 600 "$CFG_PATH" && ok "Config locked to 0600 (it holds your token)"
ok "Config written"

# -- 5b. launcher -----------------------------------------------------------
LAUNCHER="$APP_DIR/run-seren-loci.sh"
cat > "$LAUNCHER" <<LAUNCHEOF
#!/usr/bin/env bash
exec "$VPY" -m seren_loci --config "$CFG_PATH"
LAUNCHEOF
chmod +x "$LAUNCHER"
ok "Launcher written: $LAUNCHER"

# -- 6. optional autostart ----------------------------------------------------
if $INSTALL_SERVICE; then
  step "Installing the autostart service"
  WRAPPER="$SCRIPT_DIR/setup-loci-service.sh"
  CORE="$(find_upward "Generics/setup-seren-service.sh")"
  if [[ -f "$WRAPPER" && -f "$CORE" ]]; then
    if [[ -n "$TOKEN" ]]; then
      printf 'SEREN_LOCI_BEARER_TOKEN=%s\n' "$TOKEN" > "$APP_DIR/seren-loci.env"
      chmod 600 "$APP_DIR/seren-loci.env"
    fi
    bash "$WRAPPER" --instance "$INSTANCE" || die "service install failed - see output above"
  else
    warn "setup-loci-service.sh + setup-seren-service.sh not found in $SCRIPT_DIR."
    warn "Keep the shared setup scripts together and run:"
    warn "  bash setup-loci-service.sh --instance '$INSTANCE'"
  fi
fi

# -- done -------------------------------------------------------------------
echo
echo -e "${G}==========================================${NC}"
echo -e "${G}  SerenLoci is set up ✓${NC}"
echo -e "${G}==========================================${NC}"
if ! $INSTALL_SERVICE; then
  echo -e "  Start it:        ${B}$LAUNCHER${NC}"
  echo -e "  (or directly:    ${B}$VPY -m seren_loci --config $CFG_PATH${NC})"
fi
echo -e "  Viewer:          ${B}http://${CONNECT_HOST}:${PORT}/viewer${NC}"
echo -e "  VSCode plugin:   set serenLoci.endpoint to ${B}http://${CONNECT_HOST}:${PORT}${NC}"
[[ -n "$TOKEN" ]] && echo -e "  Bearer token:    ${Y}${TOKEN}${NC}  (also set it in the plugin via 'Seren Loci: Set Bearer Token')"
echo
if $MCP; then
  echo -e "  MCP endpoint:    ${B}http://${CONNECT_HOST}:${PORT}/mcp/${NC}"
fi
if $VECTOR; then
  echo -e "  Finder:          ${B}vector (sqlite-vec + all-MiniLM-L6-v2)${NC}"
fi
if $CORP; then
  echo -e "  TLS:             ${B}OS trust store (truststore injected at startup)${NC}"
fi
echo -e "${G}Rip it and win. 🌭🔧${NC}"
