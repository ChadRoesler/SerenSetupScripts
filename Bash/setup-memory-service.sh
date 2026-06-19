#!/usr/bin/env bash
# ==========================================================================
#  setup-memory-service.sh  -  SerenMemory pointed wrapper (Linux + macOS)
#
#  The CONVENTION half of the generic-core / pointed-wrapper split. Knows what
#  a SerenMemory install looks like (dirs, instance suffix, module, token
#  env-file) and hands it to setup-seren-service.sh, which does the
#  systemd/launchd work. Lives alongside the core in
#  D:\serenDaemon\SerenSetupScripts.
#
#  INSTANCE CONVENTION (mirrors seren-memory-setup.sh):
#    --instance Test suffixes everything:
#      Service:  seren-memoryTest
#      Venv:     ~/seren-venvs/memoryTest
#      AppDir:   ~/seren-memoryTest
#      Config:   ~/seren-memoryTest/seren-memory.yaml
#    Run the installer with --instance Test FIRST, then this with the same.
#
#  Passes the token env-file (seren-memory.env) through to the core, which
#  wires it into the systemd unit ONLY if it exists - keeping the bearer
#  token out of the unit text.
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
SERVICE_NAME="seren-memory$INSTANCE"
MODULE="seren_memory"
[[ -n "$VENV_DIR" ]] || VENV_DIR="$HOME/seren-venvs/memory$INSTANCE"
[[ -n "$APP_DIR"  ]] || APP_DIR="$HOME/seren-memory$INSTANCE"
[[ -n "$CFG_PATH" ]] || CFG_PATH="$APP_DIR/seren-memory.yaml"
ENV_FILE="$APP_DIR/seren-memory.env"   # wired in only if it exists (token lives there)

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

exec bash "$CORE" \
  --service-name "$SERVICE_NAME" \
  --module       "$MODULE" \
  --venv         "$VENV_DIR" \
  --app-dir      "$APP_DIR" \
  --config       "$CFG_PATH" \
  --env-file     "$ENV_FILE" \
  --env          PYTHONUTF8=1 \
  --env          SEREN_SUPERVISED=1 \
  --health-port  "$HEALTH_PORT" \
  --description  "SerenMemory$INSTANCE - three-tier LLM memory"
