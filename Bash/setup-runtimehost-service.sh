#!/usr/bin/env bash
# ==========================================================================
#  setup-runtimehost-service.sh  -  SerenRuntimeHost pointed wrapper (.NET)
#
#  CONVENTION half for the cluster head. Knows RuntimeHost's shape and hands
#  it to setup-seren-dotnet-service.sh (the .NET mechanism core). Lives in
#  the shared D:\serenDaemon\SerenSetupScripts.
#
#  RuntimeHost launch contract (from Program.cs):
#    * config path is POSITIONAL: `SerenRuntimeHost <path-to-yaml>`
#      (defaults to ./seren-runtime.yaml if omitted)
#    * binds runtime.host:runtime.port from the yaml (default 0.0.0.0:6361)
#    * public health path is /api/v1/system/ping  (NOT /health)
#  So we pass the yaml positionally and point the health check at /ping.
#
#  Runs on the NUC (x64). Self-contained single-file: no .NET runtime needed
#  on the box. Override --rid linux-arm64 only if you (against advice) run it
#  on a Jetson.
#
#  FLAGS
#    --repo-dir PATH   SerenRuntimeHost checkout (default sibling ../SerenRuntimeHost)
#    --deploy-dir PATH where it's deployed + runs (default ~/seren-runtime-host)
#    --config PATH     the runtime yaml          (default <deploy-dir>/seren-runtime.yaml)
#    --rid RID         runtime identifier        (default linux-x64)
#    --no-publish      service an already-published/deployed dir
#    -h, --help        this help
# ==========================================================================
set -euo pipefail

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

REPO_DIR="$(find_upward "SerenRuntimeHost")"
DEPLOY_DIR="$HOME/seren-runtime-host"
CONFIG_PATH=""
RID="linux-x64"
NO_PUBLISH=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-dir)   REPO_DIR="$2"; shift 2 ;;
    --deploy-dir) DEPLOY_DIR="$2"; shift 2 ;;
    --config)     CONFIG_PATH="$2"; shift 2 ;;
    --rid)        RID="$2"; shift 2 ;;
    --no-publish) NO_PUBLISH=true; shift ;;
    -h|--help)    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)            echo "unknown flag: $1  (try --help)" >&2; exit 1 ;;
  esac
done

# -- identity lines -----------------------------------------------------------
SERVICE_NAME="seren-runtime-host"
EXEC_NAME="SerenRuntimeHost"
PROJECT_DIR="${REPO_DIR}/SerenRuntimeHost"   # nested project dir
[[ -n "$CONFIG_PATH" ]] || CONFIG_PATH="$DEPLOY_DIR/seren-runtime.yaml"

CORE="$(find_upward "Generics/setup-seren-dotnet-service.sh")"
if [[ ! -f "$CORE" ]]; then
  echo "ERROR: setup-seren-dotnet-service.sh not found in $SCRIPT_DIR." >&2
  echo "       The wrapper is just conventions - the core does the work. Keep the shared scripts together." >&2
  exit 1
fi

PUBLISH_FLAG=()
$NO_PUBLISH && PUBLISH_FLAG=(--no-publish)

# config is POSITIONAL for RuntimeHost; pass it as the exec arg.
# Health: 6361 + /api/v1/system/ping (a public path, no auth needed).
exec bash "$CORE" \
  --service-name "$SERVICE_NAME" \
  --project-dir  "$PROJECT_DIR" \
  --exec-name    "$EXEC_NAME" \
  --exec-args    "$CONFIG_PATH" \
  --deploy-dir   "$DEPLOY_DIR" \
  --rid          "$RID" \
  --health-port  6361 \
  --health-path  /api/v1/system/ping \
  --description  "SerenRuntimeHost - cluster head (aggregates agent APIs, serves dashboard)" \
  "${PUBLISH_FLAG[@]}"
