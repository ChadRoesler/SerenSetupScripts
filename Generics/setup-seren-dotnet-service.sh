#!/usr/bin/env bash
# ==========================================================================
#  setup-seren-dotnet-service.sh  -  GENERIC autostart installer for any
#  .NET-published seren service (SerenRuntimeHost, SerenMcpServer, ...).
#
#  The MECHANISM half of the generic-core / pointed-wrapper split, .NET
#  edition. Sibling to setup-seren-service.sh (which is the Python edition).
#  The Python core was left untouched on purpose - .NET launches nothing like
#  `python -m module`, so forcing one core to do both would mean re-proving
#  the working Python one. Two clean cores, each honest about one launch
#  model.
#
#  What it does:
#    1. (optional) publishes the project self-contained single-file for a RID
#    2. deploys the publish output to a target dir (local copy or rsync)
#    3. installs an autostart service:
#         Linux -> systemd system service (needs sudo)
#         macOS -> launchd user agent (no sudo)
#    4. waits for health on the service's OWN health path
#
#  KEY DIFFERENCE FROM THE PYTHON CORE: there's no venv and no `-m module`.
#  A .NET service launches a published executable with service-specific args.
#  How a given service wants to be launched differs (RuntimeHost takes the
#  config path POSITIONALLY; MCP is env-driven with no positional config), so
#  this core does NOT bake in a launch convention. The wrapper supplies:
#       --exec-name   the published binary's filename (e.g. SerenRuntimeHost)
#       --exec-args   everything after the binary (positional config, flags)
#       --env         repeatable KEY=VALUE lines wired into the unit
#  and this core assembles `<deploy-dir>/<exec-name> <exec-args>`.
#
#  USAGE (the wrapper calls this; you normally don't):
#    bash setup-seren-dotnet-service.sh \
#      --service-name seren-runtime-host \
#      --project-dir  ../SerenRuntimeHost/SerenRuntimeHost \
#      --exec-name    SerenRuntimeHost \
#      --exec-args    "~/seren-runtime-host/seren-runtime.yaml" \
#      --deploy-dir   ~/seren-runtime-host \
#      --health-port  6361 --health-path /api/v1/system/ping
#
#  FLAGS
#    --service-name NAME    systemd unit / launchd label          (required)
#    --exec-name NAME       published binary filename             (required)
#    --deploy-dir PATH      where the published bits live + run   (required)
#    --exec-args STR        args appended after the binary        (default "")
#    --project-dir PATH     .csproj dir to publish from           (publish mode)
#    --publish-profile NAME -p:PublishProfile=<NAME>              (default SelfContained)
#    --rid RID              runtime identifier                    (default linux-x64)
#    --publish-dir PATH     where `dotnet publish` output lands
#                           (default <project-dir>/bin/Release/<tfm>/<rid>/publish)
#    --tfm TFM              target framework moniker for the path  (default net10.0)
#    --no-publish           skip publish; deploy/service an already-built dir
#    --no-deploy            skip deploy; service whatever's in --deploy-dir
#    --env KEY=VALUE        unit environment line (repeatable)
#    --env-file PATH        EnvironmentFile, wired only if it exists (linux)
#    --description TEXT     unit description
#    --health-port N        health-check port                     (0 = skip)
#    --health-path PATH     health endpoint                       (default /health)
#    --no-health-check      skip the wait-for-health loop
#    --memory-max VAL       systemd MemoryMax (default none; 'none' omits)
#    --launchd-prefix P     launchd label prefix   (default com.chadroesler)
#    --dotnet BIN           dotnet executable      (default: dotnet on PATH)
#    -h, --help             this help
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

# -- defaults ---------------------------------------------------------------
SERVICE_NAME=""
EXEC_NAME=""
DEPLOY_DIR=""
EXEC_ARGS=""
PROJECT_DIR=""
PUBLISH_PROFILE="SelfContained"
RID="linux-x64"
PUBLISH_DIR=""
TFM="net10.0"
DO_PUBLISH=true
DO_DEPLOY=true
ENV_FILE=""
DESCRIPTION=""
HEALTH_PORT=0
HEALTH_PATH="/health"
NO_HEALTH_CHECK=false
MEMORY_MAX="none"
LAUNCHD_PREFIX="com.chadroesler"
DOTNET_BIN="dotnet"
declare -a ENV_LINES=()

# macOS publishes osx-* RIDs, not linux-*; flip the default if unset later.
$IS_MAC && RID="osx-x64"

# -- flag parsing (while/case) ----------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --service-name)    SERVICE_NAME="$2"; shift 2 ;;
    --exec-name)       EXEC_NAME="$2"; shift 2 ;;
    --deploy-dir)      DEPLOY_DIR="$2"; shift 2 ;;
    --exec-args)       EXEC_ARGS="$2"; shift 2 ;;
    --project-dir)     PROJECT_DIR="$2"; shift 2 ;;
    --publish-profile) PUBLISH_PROFILE="$2"; shift 2 ;;
    --rid)             RID="$2"; shift 2 ;;
    --publish-dir)     PUBLISH_DIR="$2"; shift 2 ;;
    --tfm)             TFM="$2"; shift 2 ;;
    --no-publish)      DO_PUBLISH=false; shift ;;
    --no-deploy)       DO_DEPLOY=false; shift ;;
    --env)             ENV_LINES+=("$2"); shift 2 ;;
    --env-file)        ENV_FILE="$2"; shift 2 ;;
    --description)     DESCRIPTION="$2"; shift 2 ;;
    --health-port)     HEALTH_PORT="$2"; shift 2 ;;
    --health-path)     HEALTH_PATH="$2"; shift 2 ;;
    --no-health-check) NO_HEALTH_CHECK=true; shift ;;
    --memory-max)      MEMORY_MAX="$2"; shift 2 ;;
    --launchd-prefix)  LAUNCHD_PREFIX="$2"; shift 2 ;;
    --dotnet)          DOTNET_BIN="$2"; shift 2 ;;
    -h|--help)         sed -n '2,70p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)                 die "unknown flag: $1  (try --help)" ;;
  esac
done

[[ -n "$SERVICE_NAME" ]] || die "--service-name is required"
[[ -n "$EXEC_NAME"    ]] || die "--exec-name is required"
[[ -n "$DEPLOY_DIR"   ]] || die "--deploy-dir is required"
[[ -n "$DESCRIPTION"  ]] || DESCRIPTION="$SERVICE_NAME - seren constellation service"

# Expand a leading ~ ourselves: we build absolute paths for the unit, and the
# unit never goes through a shell that would expand it.
expand_tilde() {
  local p="$1"
  # Matching a literal leading ~ on purpose, to expand it ourselves (the unit
  # file never goes through a shell that would expand it).
  # shellcheck disable=SC2088
  case "$p" in
    "~")   echo "$HOME" ;;
    "~/"*) echo "$HOME/${p:2}" ;;
    *)     echo "$p" ;;
  esac
}
DEPLOY_DIR="$(expand_tilde "$DEPLOY_DIR")"
[[ -n "$PROJECT_DIR" ]] && PROJECT_DIR="$(expand_tilde "$PROJECT_DIR")"
[[ -n "$PUBLISH_DIR" ]] && PUBLISH_DIR="$(expand_tilde "$PUBLISH_DIR")"
[[ -n "$ENV_FILE"    ]] && ENV_FILE="$(expand_tilde "$ENV_FILE")"

ok "service: $SERVICE_NAME"
ok "exec:    $EXEC_NAME $EXEC_ARGS"
ok "deploy:  $DEPLOY_DIR"

# -- 1. publish --------------------------------------------------------------
if $DO_PUBLISH; then
  [[ -n "$PROJECT_DIR" ]] || die "--project-dir is required to publish (or pass --no-publish)"
  [[ -d "$PROJECT_DIR" ]] || die "project dir not found: $PROJECT_DIR"
  command -v "$DOTNET_BIN" >/dev/null 2>&1 || die "'$DOTNET_BIN' not found. Install the .NET 10 SDK, or pass --no-publish and deploy a prebuilt dir."
  step "Publishing $SERVICE_NAME ($PUBLISH_PROFILE, $RID, self-contained single-file)"
  # The profile sets SelfContained/PublishSingleFile; we pass RID explicitly so
  # the same profile serves x64 and arm64 without editing the pubxml.
  "$DOTNET_BIN" publish "$PROJECT_DIR" -c Release \
    -p:PublishProfile="$PUBLISH_PROFILE" -r "$RID" \
    || die "dotnet publish failed - see output above"
  ok "published"
  # Default publish-dir matches the csproj's documented output location.
  [[ -n "$PUBLISH_DIR" ]] || PUBLISH_DIR="$PROJECT_DIR/bin/Release/$TFM/$RID/publish"
else
  step "Skipping publish (--no-publish)"
  # When not publishing, the bits are expected to already be at --publish-dir
  # (for a deploy) or directly at --deploy-dir (with --no-deploy).
  [[ -n "$PUBLISH_DIR" ]] || PUBLISH_DIR="$DEPLOY_DIR"
fi

# -- 2. deploy ---------------------------------------------------------------
if $DO_DEPLOY; then
  [[ -d "$PUBLISH_DIR" ]] || die "publish output not found at $PUBLISH_DIR  (publish first, or fix --publish-dir)"
  [[ -f "$PUBLISH_DIR/$EXEC_NAME" ]] || warn "expected binary '$EXEC_NAME' not found in $PUBLISH_DIR - check --exec-name"
  step "Deploying to $DEPLOY_DIR"
  mkdir -p "$DEPLOY_DIR"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete "$PUBLISH_DIR/" "$DEPLOY_DIR/"
  else
    # No rsync (common on a bare box) - cp -R is fine for a local deploy.
    rm -rf "${DEPLOY_DIR:?}/"* 2>/dev/null || true
    cp -R "$PUBLISH_DIR/." "$DEPLOY_DIR/"
  fi
  ok "deployed"
else
  step "Skipping deploy (--no-deploy); servicing $DEPLOY_DIR as-is"
fi

EXEC_PATH="$DEPLOY_DIR/$EXEC_NAME"
[[ -f "$EXEC_PATH" ]] || die "executable not found at $EXEC_PATH after deploy"
chmod +x "$EXEC_PATH" 2>/dev/null || true

# -- 3. install the service --------------------------------------------------
# Assemble the ExecStart. EXEC_ARGS may contain a ~; expand it here so the
# unit gets an absolute path (the unit isn't shell-expanded).
EXEC_ARGS_EXPANDED="$EXEC_ARGS"
# shellcheck disable=SC2088  # matching a literal leading ~ to expand it ourselves
[[ "$EXEC_ARGS" == "~/"* ]] && EXEC_ARGS_EXPANDED="$HOME/${EXEC_ARGS:2}"
EXEC_START="$EXEC_PATH"
[[ -n "$EXEC_ARGS_EXPANDED" ]] && EXEC_START="$EXEC_PATH $EXEC_ARGS_EXPANDED"

if $IS_MAC; then
  step "Installing launchd user agent (starts at login, no sudo)"
  PLIST_DIR="$HOME/Library/LaunchAgents"
  PLIST="$PLIST_DIR/$LAUNCHD_PREFIX.$SERVICE_NAME.plist"
  mkdir -p "$PLIST_DIR"
  # Build the ProgramArguments array: binary first, then each arg.
  PROG_ARGS="        <string>$EXEC_PATH</string>"
  if [[ -n "$EXEC_ARGS_EXPANDED" ]]; then
    # shellcheck disable=SC2206  # deliberate word-split of the args string
    arr=($EXEC_ARGS_EXPANDED)
    for a in "${arr[@]}"; do PROG_ARGS="$PROG_ARGS"$'\n'"        <string>$a</string>"; done
  fi
  # Environment block from --env lines.
  ENV_BLOCK=""
  if [[ ${#ENV_LINES[@]} -gt 0 ]]; then
    ENV_BLOCK=$'    <key>EnvironmentVariables</key>\n    <dict>\n'
    for kv in "${ENV_LINES[@]}"; do
      k="${kv%%=*}"; v="${kv#*=}"
      ENV_BLOCK="$ENV_BLOCK"$'        <key>'"$k"$'</key>\n        <string>'"$v"$'</string>\n'
    done
    ENV_BLOCK="$ENV_BLOCK"$'    </dict>\n'
  fi
  cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LAUNCHD_PREFIX.$SERVICE_NAME</string>
    <key>ProgramArguments</key>
    <array>
$PROG_ARGS
    </array>
    <key>WorkingDirectory</key>
    <string>$DEPLOY_DIR</string>
$ENV_BLOCK    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$DEPLOY_DIR/$SERVICE_NAME.log</string>
    <key>StandardErrorPath</key>
    <string>$DEPLOY_DIR/$SERVICE_NAME.err</string>
</dict>
</plist>
PLISTEOF
  launchctl unload "$PLIST" 2>/dev/null || true
  launchctl load -w "$PLIST"
  ok "launchd agent installed: $PLIST"
  LOG_HINT="tail -f $DEPLOY_DIR/$SERVICE_NAME.log"
else
  step "Installing systemd service (needs sudo)"
  UNIT="/etc/systemd/system/$SERVICE_NAME.service"
  WIRE_ENV=false
  [[ -n "$ENV_FILE" && -f "$ENV_FILE" ]] && WIRE_ENV=true
  # Build Environment= lines from --env.
  ENV_DIRECTIVES=""
  for kv in "${ENV_LINES[@]}"; do
    ENV_DIRECTIVES="${ENV_DIRECTIVES}Environment=${kv}"$'\n'
  done
  sudo tee "$UNIT" >/dev/null <<UNITEOF
[Unit]
Description=$DESCRIPTION
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$(id -un)
WorkingDirectory=$DEPLOY_DIR
ExecStart=$EXEC_START
$( [[ -n "$ENV_DIRECTIVES" ]] && printf '%s' "$ENV_DIRECTIVES" )
$( $WIRE_ENV && echo "EnvironmentFile=$ENV_FILE" )
Restart=on-failure
RestartSec=5
$( [[ "$MEMORY_MAX" != "none" && "$MEMORY_MAX" != "0" ]] && echo "MemoryMax=$MEMORY_MAX" )

[Install]
WantedBy=multi-user.target
UNITEOF
  sudo systemctl daemon-reload
  sudo systemctl enable --now "$SERVICE_NAME"
  ok "service installed and started"
  LOG_HINT="journalctl -u $SERVICE_NAME -f"
fi

# -- 4. wait for health ------------------------------------------------------
if $NO_HEALTH_CHECK || [[ "$HEALTH_PORT" -eq 0 ]]; then
  warn "Health check skipped. Eyeball it yourself: $LOG_HINT"
else
  step "Waiting for it to come up"
  for i in $(seq 1 30); do
    sleep 0.5
    if curl -fsS "http://127.0.0.1:${HEALTH_PORT}${HEALTH_PATH}" >/dev/null 2>&1; then
      ok "$SERVICE_NAME is responding on http://127.0.0.1:${HEALTH_PORT}${HEALTH_PATH}"; break
    fi
    [[ $i -eq 30 ]] && warn "Didn't respond in 15s - check: $LOG_HINT"
  done
fi

echo
echo -e "${G}Manage it:${NC}"
if $IS_MAC; then
  echo -e "  launchctl unload/load ~/Library/LaunchAgents/$LAUNCHD_PREFIX.$SERVICE_NAME.plist"
else
  echo -e "  sudo systemctl restart $SERVICE_NAME"
  echo -e "  sudo systemctl status  $SERVICE_NAME"
fi
echo -e "  $LOG_HINT"
echo -e "${G}Rip it and win. 🌭🔧${NC}"
