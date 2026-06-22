#!/usr/bin/env bash
# ==========================================================================
#  seren-corpus-callosum-setup.sh  -  one-shot SCC installer (Linux + macOS)
#
#  Lives in D:\serenDaemon\SerenSetupScripts (the shared home for every
#  seren service's setup scripts). This script:
#    1. Finds a usable Python (3.10+; no upper cap - SCC never pulls torch)
#    2. Makes a clean venv at ~/seren-venvs/callosum  (Seren convention)
#    3. Installs seren-corpus-callosum
#         - DEFAULT: from PyPI (seren-corpus-callosum is published)
#         - --wheel FILE       to install a prebuilt wheel
#         - --ref/--repo       to pull a wheel from a GitHub release
#    4. Writes a friendly config at ~/seren-corpus-callosum/seren-corpus-callosum.yaml
#         (pre-wired to fan your local hemispheres: memory 7420 + loci 7422)
#    5. Drops a run-seren-corpus-callosum.sh launcher
#    6. (optional) installs an autostart service via setup-corpus-callosum-service.sh
#
#  The defaults are SAFE: binds 127.0.0.1 (this machine only), no auth.
#  Crank the flags if you want it on the network or behind a token.
#
#  USAGE
#    bash seren-corpus-callosum-setup.sh                 # easy mode, PyPI, local-only
#    bash seren-corpus-callosum-setup.sh --mcp           # + the `search` MCP tool surface
#    bash seren-corpus-callosum-setup.sh --gen-token     # generate a bearer token
#    bash seren-corpus-callosum-setup.sh --service       # + autostart (sudo on linux)
#    bash seren-corpus-callosum-setup.sh --wheel ./seren_corpus_callosum-0.1.0-py3-none-any.whl
#    bash seren-corpus-callosum-setup.sh --ref v0.1.0    # pin to a GitHub release tag
#    bash seren-corpus-callosum-setup.sh --host 0.0.0.0  # expose on the LAN (careful!)
#    bash seren-corpus-callosum-setup.sh --corp          # OS trust store (corp proxy)
#
#  FLAGS
#    --port N         Port to listen on            (default 7423)
#    --host HOST      Bind address                 (default 127.0.0.1)
#    --token TOKEN    Set a bearer token
#    --gen-token      Generate a random bearer token for you
#    --wheel PATH     Install from a local .whl instead of PyPI
#    --ref TAG        Pin to a GitHub release tag   (implies --repo if unset)
#    --repo SLUG      GitHub release repo           (default: install from PyPI)
#    --service        Autostart via setup-corpus-callosum-service.sh (systemd/launchd)
#    --mcp            Install the [mcp] extra - the /mcp route + the `search` tool
#                     a connected model fans every store through. Without this,
#                     SCC runs HTTP-only and the MCP surface never mounts.
#    --corp           Route TLS through the OS trust store (corp proxy boxes).
#                     Installs the [corp] extra + bootstraps pip via truststore,
#                     and sets tls.trust_system_store: true in the config. Matters
#                     for SCC's OUTBOUND calls to any https store.
#    --instance NAME  Instance name                 (default: "")
#    --venv PATH      Override venv location        (default ~/seren-venvs/callosum)
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
PORT=7423                 # callosum's port (memory 7420, margin 7421, loci 7422)
HOST="127.0.0.1"          # this machine only. Safe by default.
TOKEN=""
GEN_TOKEN=false
WHEEL=""
REF=""
REPO=""
INSTALL_SERVICE=false
MCP=false
CORP=false
INSTANCE=""
VENV_DIR="$HOME/seren-venvs/callosum"
APP_DIR="$HOME/seren-corpus-callosum"

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
    --instance)  INSTANCE="$2"; shift 2 ;;
    --venv)      VENV_DIR="$2"; shift 2 ;;
    -h|--help)   sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           die "unknown flag: $1  (try --help)" ;;
  esac
done

VENV_DIR="$VENV_DIR$INSTANCE"
APP_DIR="$APP_DIR$INSTANCE"
CFG_PATH="$APP_DIR/seren-corpus-callosum.yaml"
CONNECT_HOST="$HOST"
[[ "$HOST" == "0.0.0.0" ]] && CONNECT_HOST="127.0.0.1"
if [[ -n "$INSTANCE" && "$PORT" == "7423" ]]; then
  warn "Instance '$INSTANCE' is using the default port 7423 - give each concurrent instance its own --port or they'll collide."
fi

echo -e "${G}==========================================${NC}"
$IS_MAC && echo -e "${G}  SerenCorpusCallosum setup (macOS)${NC}" || echo -e "${G}  SerenCorpusCallosum setup (Linux)${NC}"
echo -e "${G}==========================================${NC}"

# -- 1. find a usable Python ------------------------------------------------
# No upper bound: SCC is embedder-agnostic and never pulls torch, so 3.13 is
# fine here (unlike loci/memory, which cap <3.13 for their [vector] extra).
step "Finding a usable Python (3.10+)"
PYBIN=""
for cand in python3.13 python3.12 python3.11 python3.10 python3 python; do
  if command -v "$cand" >/dev/null 2>&1; then
    ver="$("$cand" -c 'import sys; print("%d.%d"%sys.version_info[:2])' 2>/dev/null || echo "")"
    case "$ver" in
      3.10|3.11|3.12|3.13) PYBIN="$cand"; break ;;
    esac
  fi
done
if [[ -z "$PYBIN" ]]; then
  die "No Python 3.10+ found.
  Install one, e.g.:
    macOS:          brew install python@3.12
    Debian/Ubuntu:  sudo apt install python3.12 python3.12-venv
    Fedora:         sudo dnf install python3.12
    Arch:           sudo pacman -S python"
fi
PYVER="$("$PYBIN" -c 'import sys; print("%d.%d.%d"%sys.version_info[:3])')"
ok "Using $PYBIN (Python $PYVER)"

[[ -n "$REF" && -z "$REPO" ]] && REPO="ChadRoesler/SerenCorpusCallosum"

# -- 2. resolve the wheel to install ----------------------------------------
WHEEL_SRC=""
CLEANUP_WHEEL=false
if [[ -n "$WHEEL" ]]; then
  [[ -f "$WHEEL" ]] || die "wheel not found: $WHEEL"
  WHEEL_SRC="$WHEEL"
  ok "Installing from local wheel: $(basename "$WHEEL")"
elif [[ -n "$REPO" ]]; then
  step "Resolving the SerenCorpusCallosum release from GitHub ($REPO)"
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
  WHEEL_SRC="$(mktemp /tmp/seren_scc_XXXXXX.whl)"
  CLEANUP_WHEEL=true
  trap '[[ "$CLEANUP_WHEEL" == true ]] && rm -f "$WHEEL_SRC"' EXIT
  curl -fsSL "$WHL_URL" -o "$WHEEL_SRC" || die "download failed"
  ok "Downloaded"
else
  WHEEL_SRC="seren-corpus-callosum"  # latest from PyPI
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

# Build the extras suffix from any combination of mcp / corp. (No [vector] -
# the callosum embeds nothing, so there's no such extra to offer.)
EXTRAS_LIST=()
$MCP  && EXTRAS_LIST+=("mcp")
$CORP && EXTRAS_LIST+=("corp")
EXTRAS=""
if [[ ${#EXTRAS_LIST[@]} -gt 0 ]]; then
  EXTRAS="[$(IFS=,; echo "${EXTRAS_LIST[*]}")]"
fi
CORP_ARGS="$(pip_corp_args)"
step "Installing seren-corpus-callosum${EXTRAS}  (web stack + httpx$( $MCP && echo " + the MCP SDK" )$( $CORP && echo " + truststore" ))"
"$VPY" -m pip install -q --upgrade pip
# shellcheck disable=SC2086  # CORP_ARGS is intentionally word-split (0 or 1 flag)
"$VPY" -m pip install -q --upgrade $CORP_ARGS "${WHEEL_SRC}${EXTRAS}" || die "pip install failed - see output above"
ok "Installed"

# -- 4. sanity check (import; + verify the MCP extra actually landed) --------
# The callosum has no viewer asset to check (it owns no store / no UI yet), but
# IF --mcp was requested we verify `import mcp` works - because that's the exact
# silent failure mode: extra not pulled -> app.py falls to HTTP-only -> the
# `search` tool never mounts. Catch it here, loudly, not in production.
step "Sanity-checking the install"
CHECK="$("$VPY" - "$($MCP && echo 1 || echo 0)" <<'PY'
import sys
want_mcp = sys.argv[1] == "1"
try:
    import seren_corpus_callosum  # noqa: F401
except Exception as e:
    print(f"IMPORT_FAILED: {e}"); raise SystemExit
if want_mcp:
    try:
        import mcp  # noqa: F401
    except Exception:
        print("MCP_MISSING"); raise SystemExit
    print("OK_MCP")
else:
    print("OK")
PY
)"
case "$CHECK" in
  OK)     ok "Package imports cleanly" ;;
  OK_MCP) ok "Package imports + the MCP SDK is present (the /mcp surface will mount)" ;;
  MCP_MISSING) die "Package installed but the [mcp] extra didn't land - 'import mcp' failed.
  The /mcp surface would silently NOT mount. Re-run the install, or:
    $VPY -m pip install 'seren-corpus-callosum[mcp]'" ;;
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
# SerenCorpusCallosum config - generated by seren-corpus-callosum-setup.sh
# Full reference: see seren-corpus-callosum.yaml.sample in the repo.
server:
  host: ${HOST}          # 127.0.0.1 = this machine only; 0.0.0.0 = the LAN
  port: ${PORT}
  # Empty = no auth (fine for local). A token requires
  #   Authorization: Bearer <token>  on every route except /, /health.
  bearer_token: "${TOKEN}"

federation:
  # The callosum fans these stores and RRF-merges the results. Each entry is one
  # store; add/remove freely. A store that's down or slow is skipped for that
  # call - it degrades the result, it never crashes the fan. (RRF reads only
  # rank ordering, so the merge is correct even across different embedders.)
  #   weight: per-store trust multiplier (default 1.0)
  #   floor:  per-store relevance floor, pre-fusion (default 0.0)
  stores:
    - name: memory          # right brain - episodic memory
      type: seren_memory
      url: http://127.0.0.1:7420
    - name: loci            # left brain - keyed facts
      type: seren_loci
      url: http://127.0.0.1:7422
$( $CORP && printf '\ntls:\n  # Route outbound TLS through the OS trust store (corp proxy boxes).\n  # Requires the [corp] extra (truststore). Logged at startup when active.\n  trust_system_store: true\n' )
YAML
[[ -n "$TOKEN" ]] && chmod 600 "$CFG_PATH" && ok "Config locked to 0600 (it holds your token)"
ok "Config written (pre-wired to fan memory:7420 + loci:7422)"

# -- 5b. launcher -----------------------------------------------------------
LAUNCHER="$APP_DIR/run-seren-corpus-callosum.sh"
cat > "$LAUNCHER" <<LAUNCHEOF
#!/usr/bin/env bash
exec "$VPY" -m seren_corpus_callosum --config "$CFG_PATH"
LAUNCHEOF
chmod +x "$LAUNCHER"
ok "Launcher written: $LAUNCHER"

# -- 6. optional autostart ----------------------------------------------------
if $INSTALL_SERVICE; then
  step "Installing the autostart service"
  WRAPPER="$SCRIPT_DIR/setup-corpus-callosum-service.sh"
  CORE="$(find_upward "Generics/setup-seren-service.sh")"
  if [[ -f "$WRAPPER" && -f "$CORE" ]]; then
    if [[ -n "$TOKEN" ]]; then
      printf 'SEREN_SCC_BEARER_TOKEN=%s\n' "$TOKEN" > "$APP_DIR/seren-corpus-callosum.env"
      chmod 600 "$APP_DIR/seren-corpus-callosum.env"
    fi
    bash "$WRAPPER" --instance "$INSTANCE" || die "service install failed - see output above"
  else
    warn "setup-corpus-callosum-service.sh + setup-seren-service.sh not found in $SCRIPT_DIR."
    warn "Keep the shared setup scripts together and run:"
    warn "  bash setup-corpus-callosum-service.sh --instance '$INSTANCE'"
  fi
fi

# -- done -------------------------------------------------------------------
echo
echo -e "${G}==========================================${NC}"
echo -e "${G}  SerenCorpusCallosum is set up ✓${NC}"
echo -e "${G}==========================================${NC}"
if ! $INSTALL_SERVICE; then
  echo -e "  Start it:        ${B}$LAUNCHER${NC}"
  echo -e "  (or directly:    ${B}$VPY -m seren_corpus_callosum --config $CFG_PATH${NC})"
fi
echo -e "  Fan/search:      ${B}POST http://${CONNECT_HOST}:${PORT}/search${NC}"
echo -e "  Health:          ${B}http://${CONNECT_HOST}:${PORT}/health${NC}"
echo -e "  VSCode plugin:   set the endpoint to ${B}http://${CONNECT_HOST}:${PORT}${NC}"
[[ -n "$TOKEN" ]] && echo -e "  Bearer token:    ${Y}${TOKEN}${NC}  (also set it in the plugin's Set-Bearer-Token command)"
echo
if $MCP; then
  echo -e "  MCP endpoint:    ${B}http://${CONNECT_HOST}:${PORT}/mcp/${NC}  (tool: search)"
fi
if $CORP; then
  echo -e "  TLS:             ${B}OS trust store (truststore injected at startup)${NC}"
fi
echo -e "${G}Rip it and win. 🌭🔧${NC}"
