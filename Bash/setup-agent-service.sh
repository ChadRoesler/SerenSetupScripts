#!/usr/bin/env bash
# ==========================================================================
#  setup-agent-service.sh  -  SerenAgent pointed wrapper (Linux + macOS)
#
#  CONVENTION half of the generic-core / pointed-wrapper split. Knows what a
#  SerenAgent install looks like and hands it to setup-seren-service.sh (the
#  Python mechanism core). Lives in the shared SerenSetupScripts dir.
#
#  The agent now FOLLOWS THE LEADER: host/port come from
#  ~/seren-agent/seren-agent.yaml via --config (same as Memory/Margin), so
#  this wrapper is a near-twin of the Memory wrapper.
#
#  ONE DELIBERATE DIFFERENCE: the agent's bearer token is NOT a config field.
#  It's a safety interlock in ~/.seren/secrets.json (written by
#  seren-secrets.sh), loaded by auth.load_token(). So this wrapper passes NO
#  --env-file for a token - there's no token env to wire. The agent fails
#  CLOSED on mutating endpoints until secrets.json exists.
#
#  INSTANCE CONVENTION (mirrors seren-agent-setup.sh):
#    --instance Test suffixes everything:
#      Service:  seren-agentTest
#      Venv:     ~/seren-venvs/agentTest
#      AppDir:   ~/seren-agentTest
#      Config:   ~/seren-agentTest/seren-agent.yaml
#
#  FLAGS
#    --instance NAME   Instance name                 (default: "")
#    --venv PATH       Override venv location
#    --app-dir PATH    Override app dir
#    --config PATH     Override config path
#    --health-port N   Override the health-check port
#    -h, --help        This help
# ==========================================================================
set -euo pipefail

INSTANCE=""
VENV_DIR=""
APP_DIR=""
CFG_PATH=""
HEALTH_PORT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --instance)    INSTANCE="$2"; shift 2 ;;
    --venv)        VENV_DIR="$2"; shift 2 ;;
    --app-dir)     APP_DIR="$2"; shift 2 ;;
    --config)      CFG_PATH="$2"; shift 2 ;;
    --health-port) HEALTH_PORT="$2"; shift 2 ;;
    -h|--help)     sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)             echo "unknown flag: $1  (try --help)" >&2; exit 1 ;;
  esac
done

# -- the identity lines (the whole point of this wrapper) ---------------------
SERVICE_NAME="seren-agent$INSTANCE"
MODULE="seren_agent"
[[ -n "$VENV_DIR" ]] || VENV_DIR="$HOME/seren-venvs/agent$INSTANCE"
[[ -n "$APP_DIR"  ]] || APP_DIR="$HOME/seren-agent$INSTANCE"
[[ -n "$CFG_PATH" ]] || CFG_PATH="$APP_DIR/seren-agent.yaml"

# -- delegate to the shared generic core --------------------------------------
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

CORE="$(find_upward "Generics/setup-seren-service.sh")"
if [[ ! -f "$CORE" ]]; then
  echo "ERROR: setup-seren-service.sh not found walking up from this script ($SCRIPT_DIR)." >&2
  echo "       The wrapper is just conventions - the core does the work. Keep the shared scripts together." >&2
  exit 1
fi

# Health: the agent's public liveness path is /api/v1/system/ping (NOT
# /health). Port reads from server.port in the config (the core's default
# --config-port-key server.port is correct here).
exec bash "$CORE" \
  --service-name "$SERVICE_NAME" \
  --module       "$MODULE" \
  --venv         "$VENV_DIR" \
  --app-dir      "$APP_DIR" \
  --config       "$CFG_PATH" \
  --health-port  "$HEALTH_PORT" \
  --health-path  /api/v1/system/ping \
  --description  "SerenAgent$INSTANCE - per-node management plane"
