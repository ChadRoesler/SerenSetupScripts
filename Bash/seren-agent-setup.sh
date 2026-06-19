#!/usr/bin/env bash
# ==========================================================================
#  seren-agent-setup.sh  -  one-shot SerenAgent installer (Linux + macOS)
#
#  Lives in D:\serenDaemon\SerenSetupScripts (shared home for setup scripts).
#  Installs the per-node management plane and (optionally) services it via the
#  shared generic core.
#
#  The agent FOLLOWS THE LEADER now: host/port live in
#  ~/seren-agent/seren-agent.yaml (server: block) and the service starts with
#  --config. The bearer TOKEN is separate - it's a safety interlock in
#  ~/.seren/secrets.json (run seren-secrets.sh), not a yaml field.
#
#  USAGE
#    bash seren-agent-setup.sh                  # GitHub release, local-only run
#    bash seren-agent-setup.sh --service        # + autostart (sudo on linux)
#    bash seren-agent-setup.sh --wheel ./seren_agent-1.0.0-py3-none-any.whl
#    bash seren-agent-setup.sh --pypi           # once published
#    bash seren-agent-setup.sh --ref v1.0.0     # pin to a release tag
#
#  FLAGS
#    --port N         Port to listen on            (default 7777)
#    --host HOST      Bind address                 (default 0.0.0.0, cluster LAN)
#    --wheel PATH     Install from a local .whl
#    --pypi           Install seren-agent from PyPI
#    --ref TAG        Pin to a GitHub release tag   (default latest)
#    --repo SLUG      GitHub repo                   (default ChadRoesler/SerenAgent)
#    --service        Autostart via setup-agent-service.sh
#    --instance NAME  Instance name                 (default: "")
#    --venv PATH      Override venv location        (default ~/seren-venvs/agent)
#    -h, --help       This help
# ==========================================================================
set -euo pipefail

OS="$(uname -s)"; IS_MAC=false; [[ "$OS" == "Darwin" ]] && IS_MAC=true
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

PORT=7777
HOST="0.0.0.0"
WHEEL=""
USE_PYPI=false
REF=""
REPO=""
INSTALL_SERVICE=false
INSTANCE=""
VENV_DIR="$HOME/seren-venvs/agent"
APP_DIR="$HOME/seren-agent"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)      PORT="$2"; shift 2 ;;
    --host)      HOST="$2"; shift 2 ;;
    --wheel)     WHEEL="$2"; shift 2 ;;
    --pypi)      USE_PYPI=true; shift ;;
    --ref)       REF="$2"; shift 2 ;;
    --repo)      REPO="$2"; shift 2 ;;
    --service)   INSTALL_SERVICE=true; shift ;;
    --instance)  INSTANCE="$2"; shift 2 ;;
    --venv)      VENV_DIR="$2"; shift 2 ;;
    -h|--help)   sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           die "unknown flag: $1  (try --help)" ;;
  esac
done

VENV_DIR="$VENV_DIR$INSTANCE"
APP_DIR="$APP_DIR$INSTANCE"
CFG_PATH="$APP_DIR/seren-agent.yaml"
CONNECT_HOST="$HOST"; [[ "$HOST" == "0.0.0.0" ]] && CONNECT_HOST="127.0.0.1"
if [[ -n "$INSTANCE" && "$PORT" == "7777" ]]; then
  warn "Instance '$INSTANCE' is using the default port 7777 - give each concurrent instance its own --port or they'll collide."
fi

echo -e "${G}==========================================${NC}"
$IS_MAC && echo -e "${G}  SerenAgent setup (macOS)${NC}" || echo -e "${G}  SerenAgent setup (Linux)${NC}"
echo -e "${G}==========================================${NC}"

step "Finding a usable Python (3.10-3.12)"
PYBIN=""
for cand in python3.12 python3.11 python3.10 python3 python; do
  if command -v "$cand" >/dev/null 2>&1; then
    ver="$("$cand" -c 'import sys; print("%d.%d"%sys.version_info[:2])' 2>/dev/null || echo "")"
    case "$ver" in 3.10|3.11|3.12) PYBIN="$cand"; break ;; esac
  fi
done
[[ -n "$PYBIN" ]] || die "No Python 3.10-3.12 found. Install python3.12 + python3.12-venv."
PYVER="$("$PYBIN" -c 'import sys; print("%d.%d.%d"%sys.version_info[:3])')"
ok "Using $PYBIN (Python $PYVER)"

[[ -n "$REF" && -z "$REPO" ]] && REPO="ChadRoesler/SerenAgent"
# Default install source: GitHub release (the agent ships releases). PyPI/wheel override.
[[ -z "$WHEEL" && "$USE_PYPI" == false && -z "$REPO" ]] && REPO="ChadRoesler/SerenAgent"

WHEEL_SRC=""; CLEANUP_WHEEL=false
if [[ -n "$WHEEL" ]]; then
  [[ -f "$WHEEL" ]] || die "wheel not found: $WHEEL"
  WHEEL_SRC="$WHEEL"; ok "Installing from local wheel: $(basename "$WHEEL")"
elif $USE_PYPI; then
  WHEEL_SRC="seren-agent"; ok "Installing the latest seren-agent from PyPI"
else
  step "Resolving the seren-agent release from GitHub ($REPO)"
  command -v curl >/dev/null 2>&1 || die "curl is required to download from GitHub"
  api="https://api.github.com/repos/${REPO}/releases/${REF:+tags/$REF}"
  [[ -z "$REF" ]] && api="https://api.github.com/repos/${REPO}/releases/latest"
  json="$(curl -fsSL "$api" 2>/dev/null)" || die "GitHub API request failed ($api)."
  read -r TAG WHL_URL < <("$PYBIN" - "$json" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
tag = data.get("tag_name", "?")
whl = next((a["browser_download_url"] for a in data.get("assets", []) if a.get("name","").endswith(".whl")), "")
print(tag, whl)
PY
)
  [[ -n "$WHL_URL" && "$WHL_URL" != "None" ]] || die "No .whl asset in release '$TAG'. Pass --wheel."
  ok "Release $TAG  ($(basename "$WHL_URL"))"
  WHEEL_SRC="$(mktemp /tmp/seren_agent_XXXXXX.whl)"; CLEANUP_WHEEL=true
  trap '[[ "$CLEANUP_WHEEL" == true ]] && rm -f "$WHEEL_SRC"' EXIT
  curl -fsSL "$WHL_URL" -o "$WHEEL_SRC" || die "download failed"; ok "Downloaded"
fi

step "Creating venv at $VENV_DIR"
if [[ -x "$VENV_DIR/bin/python" ]]; then warn "venv already exists - reusing it"
else "$PYBIN" -m venv "$VENV_DIR" || die "venv creation failed (need python3-venv?)"; ok "venv created"; fi
VPY="$VENV_DIR/bin/python"

step "Installing seren-agent"
"$VPY" -m pip install -q --upgrade pip
"$VPY" -m pip install -q --upgrade "$WHEEL_SRC" || die "pip install failed - see output above"
ok "Installed"

step "Sanity-checking the install"
CHECK="$("$VPY" -c 'import seren_agent; print("OK: v"+seren_agent.__version__)' 2>&1)"
case "$CHECK" in OK:*) ok "Package imports cleanly ($CHECK)" ;; *) die "Install looks broken: $CHECK" ;; esac

step "Writing config at $CFG_PATH"
mkdir -p "$APP_DIR"
if [[ -f "$CFG_PATH" ]]; then bak="$CFG_PATH.bak.$(date +%s)"; cp "$CFG_PATH" "$bak"; warn "Existing config backed up to $(basename "$bak")"; fi
cat > "$CFG_PATH" <<YAML
# SerenAgent config - generated by seren-agent-setup.sh
# host/port only. The bearer TOKEN is NOT here - it's a safety interlock in
# ~/.seren/secrets.json (run seren-secrets.sh). See the repo's yaml sample.
server:
  host: ${HOST}          # 0.0.0.0 = reachable across the trusted LAN (cluster plane)
  port: ${PORT}
YAML
ok "Config written"

LAUNCHER="$APP_DIR/run-seren-agent.sh"
cat > "$LAUNCHER" <<LAUNCHEOF
#!/usr/bin/env bash
exec "$VPY" -m seren_agent --config "$CFG_PATH"
LAUNCHEOF
chmod +x "$LAUNCHER"; ok "Launcher written: $LAUNCHER"

if $INSTALL_SERVICE; then
  step "Installing the autostart service"
  WRAPPER="$SCRIPT_DIR/setup-agent-service.sh"; CORE="$(find_upward "Generics/setup-seren-service.sh")"
  if [[ -f "$WRAPPER" && -f "$CORE" ]]; then
    bash "$WRAPPER" --instance "$INSTANCE" || die "service install failed - see output above"
  else
    warn "setup-agent-service.sh + setup-seren-service.sh not found in $SCRIPT_DIR."
    warn "Keep the shared setup scripts together and run:  bash setup-agent-service.sh --instance '$INSTANCE'"
  fi
fi

echo
echo -e "${G}==========================================${NC}"
echo -e "${G}  SerenAgent is set up ✓${NC}"
echo -e "${G}==========================================${NC}"
if ! $INSTALL_SERVICE; then
  echo -e "  Start it:        ${B}$LAUNCHER${NC}"
  echo -e "  (or directly:    ${B}$VPY -m seren_agent --config $CFG_PATH${NC})"
fi
echo -e "  Ping:            ${B}http://${CONNECT_HOST}:${PORT}/api/v1/system/ping${NC}"
echo -e "  Docs:            ${B}http://${CONNECT_HOST}:${PORT}/docs${NC}"
echo
echo -e "  ${Y}Token is a safety interlock: run seren-secrets.sh to write ~/.seren/secrets.json.${NC}"
echo -e "  ${Y}Until then the agent fails CLOSED on service-management endpoints.${NC}"
echo -e "${G}Rip it and win. 🌭🔧${NC}"
