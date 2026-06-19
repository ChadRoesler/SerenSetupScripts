#!/usr/bin/env bash
# ==========================================================================
#  setup-mcp-service.sh  -  SerenMcpServer pointed wrapper (.NET)
#
#  CONVENTION half for the MCP server. Knows MCP's shape and hands it to
#  setup-seren-dotnet-service.sh. Lives in the shared SerenSetupScripts dir.
#
#  MCP launch contract (from Program.cs):
#    * NO positional config. Reads seren-mcp.yaml from the binary dir, plus
#      SEREN_* env overrides. Bind is hardcoded 0.0.0.0:6362, overridable
#      via ASPNETCORE_URLS.
#    * tools/ ships next to the binary; SEREN_MCP_TOOLS_DIR overrides.
#    * public health path is /health.
#  So we pass NO exec-args and set the canonical env explicitly in the unit
#  (so the deployed service's bind + downstreams are pinned, not implicit).
#
#  Runs on the NUC (x64), sibling to RuntimeHost. Self-contained single-file.
#
#  FLAGS
#    --repo-dir PATH    SerenMcp checkout      (default sibling ../SerenMcp)
#    --deploy-dir PATH  deployed + run dir     (default ~/seren-mcp-server)
#    --rid RID          runtime identifier     (default linux-x64)
#    --runtime-url URL  RuntimeHost URL env    (default http://localhost:6361)
#    --searxng-url URL  SearXNG URL env        (default http://localhost:8080)
#    --memory-url URL   SerenMemory URL env    (default http://localhost:7420)
#    --no-publish       service an already-published/deployed dir
#    -h, --help         this help
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

REPO_DIR="$(find_upward "SerenMcp")"
DEPLOY_DIR="$HOME/seren-mcp-server"
RID="linux-x64"
RUNTIME_URL="http://localhost:6361"
SEARXNG_URL="http://localhost:8080"
MEMORY_URL="http://localhost:7420"
NO_PUBLISH=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-dir)    REPO_DIR="$2"; shift 2 ;;
    --deploy-dir)  DEPLOY_DIR="$2"; shift 2 ;;
    --rid)         RID="$2"; shift 2 ;;
    --runtime-url) RUNTIME_URL="$2"; shift 2 ;;
    --searxng-url) SEARXNG_URL="$2"; shift 2 ;;
    --memory-url)  MEMORY_URL="$2"; shift 2 ;;
    --no-publish)  NO_PUBLISH=true; shift ;;
    -h|--help)     sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)             echo "unknown flag: $1  (try --help)" >&2; exit 1 ;;
  esac
done

# -- identity lines -----------------------------------------------------------
SERVICE_NAME="seren-mcp-server"
EXEC_NAME="SerenMcpServer"
PROJECT_DIR="${REPO_DIR}/SerenMcpServer"   # nested project dir

CORE="$(find_upward "Generics/setup-seren-dotnet-service.sh")"
if [[ ! -f "$CORE" ]]; then
  echo "ERROR: setup-seren-dotnet-service.sh not found in $SCRIPT_DIR." >&2
  echo "       The wrapper is just conventions - the core does the work. Keep the shared scripts together." >&2
  exit 1
fi

PUBLISH_FLAG=()
$NO_PUBLISH && PUBLISH_FLAG=(--no-publish)

# No positional config. Pin the bind + downstream URLs as env so the deployed
# service is explicit rather than relying on the hardcoded defaults. Health:
# 6362 + /health.
exec bash "$CORE" \
  --service-name "$SERVICE_NAME" \
  --project-dir  "$PROJECT_DIR" \
  --exec-name    "$EXEC_NAME" \
  --deploy-dir   "$DEPLOY_DIR" \
  --rid          "$RID" \
  --env          "ASPNETCORE_URLS=http://0.0.0.0:6362" \
  --env          "SEREN_RUNTIME_HOST_URL=$RUNTIME_URL" \
  --env          "SEREN_SEARXNG_URL=$SEARXNG_URL" \
  --env          "SEREN_MEMORY_URL=$MEMORY_URL" \
  --health-port  6362 \
  --health-path  /health \
  --description  "SerenMcpServer - MCP tool server for the Seren stack" \
  "${PUBLISH_FLAG[@]}"
