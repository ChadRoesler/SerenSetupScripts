#!/usr/bin/env bash
# ==========================================================================
#  setup-seren-service.sh  -  GENERIC autostart installer for any
#  Python-module-shaped seren service (SerenMemory, SerenMargin, whatever
#  joins the constellation next).
#
#  This is the MECHANISM half of the generic-core / pointed-wrapper split:
#    Linux  -> systemd system service (needs sudo)
#    macOS  -> launchd user agent (no sudo, starts at login)
#  plus the wait-for-health loop and port-from-config resolution.
#
#  It deliberately knows NOTHING about any specific service's conventions -
#  that's the wrapper's job (see setup-service.sh for the SerenMemory
#  wrapper as the reference example). Want to service-ify a new seren
#  python service? Write a ten-line wrapper. Done.
#
#  Design notes (the why, for future-us):
#    * Health-check port reads from the service's OWN yaml config by
#      default (dotted key, default 'server.port') using the venv's python.
#      One source of truth - the config the service actually loads.
#      Pass --health-port to override; if the read fails we warn-and-skip
#      rather than refuse to install (lenient by design - not every
#      service's schema will match).
#    * --env-file is wired into the systemd unit ONLY if the file exists.
#      That keeps secrets out of the unit text (`systemctl show` leaks it)
#      without this script ever needing to know what the secret is.
#      launchd has no EnvironmentFile equivalent - on macOS, secrets live
#      in the service's config file (which the wrapper should chmod 600).
#    * --env KEY=VALUE (repeatable) injects inline env vars into BOTH the
#      systemd [Service] block and the launchd EnvironmentVariables dict.
#      This is the per-service non-secret env (PYTHONUTF8=1 to kill the
#      Windows-less cp1252 path / be explicit, SEREN_SUPERVISED=1 so the
#      service's /migrate/restart may self-exit knowing we'll revive it).
#      The wrapper decides which vars; the core just plumbs them.
#
#  USAGE (normally you don't call this directly - the wrapper does):
#    bash setup-seren-service.sh \
#      --service-name seren-memory \
#      --module       seren_memory \
#      --venv         ~/seren-venvs/memory \
#      --app-dir      ~/seren-memory \
#      --config       ~/seren-memory/seren-memory.yaml \
#      --env          PYTHONUTF8=1 --env SEREN_SUPERVISED=1
#
#  FLAGS
#    --service-name NAME   systemd unit / launchd label name   (required)
#    --module MOD          python -m <this>                    (required)
#    --venv PATH           venv directory                      (required)
#    --app-dir PATH        working directory                   (required)
#    --config PATH         service yaml config                 (required)
#    --description TEXT    unit description
#    --env-file PATH       EnvironmentFile, wired only if it exists (linux)
#    --env KEY=VALUE       inline env var, repeatable; into systemd [Service]
#                          AND the launchd EnvironmentVariables dict
#    --health-port N       health-check port (default: read from config)
#    --config-port-key K   dotted yaml key for the port  (default server.port)
#    --health-path PATH    health endpoint               (default /health)
#    --no-health-check     skip the wait-for-health loop
#    --memory-max VAL      systemd MemoryMax             (default 2G; 'none' to omit)
#    --launchd-prefix P    launchd label prefix  (default com.chadroesler)
#    -h, --help            this help
# ==========================================================================
set -euo pipefail

# -- OS detection -----------------------------------------------------------
OS="$(uname -s)"
IS_MAC=false
[[ "$OS" == "Darwin" ]] && IS_MAC=true

# -- pretty output ----------------------------------------------------------
G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; B='\033[0;34m'; NC='\033[0m'
step() { echo -e "\n${B}==>${NC} $1"; }
ok()   { echo -e "${G}  ✓${NC} $1"; }
warn() { echo -e "${Y}  !${NC} $1"; }
die()  { echo -e "${R}ERROR:${NC} $1" >&2; exit 1; }

# -- defaults ---------------------------------------------------------------
SERVICE_NAME=""
MODULE=""
VENV_DIR=""
APP_DIR=""
CFG_PATH=""
DESCRIPTION=""
ENV_FILE=""
EXTRA_ENV=()
HEALTH_PORT=0
CONFIG_PORT_KEY="server.port"
HEALTH_PATH="/health"
NO_HEALTH_CHECK=false
MEMORY_MAX="2G"
LAUNCHD_PREFIX="com.chadroesler"

# -- flag parsing (while/case) ----------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --service-name)    SERVICE_NAME="$2"; shift 2 ;;
    --module)          MODULE="$2"; shift 2 ;;
    --venv)            VENV_DIR="$2"; shift 2 ;;
    --app-dir)         APP_DIR="$2"; shift 2 ;;
    --config)          CFG_PATH="$2"; shift 2 ;;
    --description)     DESCRIPTION="$2"; shift 2 ;;
    --env-file)        ENV_FILE="$2"; shift 2 ;;
    --env)             EXTRA_ENV+=("$2"); shift 2 ;;
    --health-port)     HEALTH_PORT="$2"; shift 2 ;;
    --config-port-key) CONFIG_PORT_KEY="$2"; shift 2 ;;
    --health-path)     HEALTH_PATH="$2"; shift 2 ;;
    --no-health-check) NO_HEALTH_CHECK=true; shift ;;
    --memory-max)      MEMORY_MAX="$2"; shift 2 ;;
    --launchd-prefix)  LAUNCHD_PREFIX="$2"; shift 2 ;;
    -h|--help)         sed -n '2,63p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)                 die "unknown flag: $1  (try --help)" ;;
  esac
done

[[ -n "$SERVICE_NAME" ]] || die "--service-name is required"
[[ -n "$MODULE"       ]] || die "--module is required"
[[ -n "$VENV_DIR"     ]] || die "--venv is required"
[[ -n "$APP_DIR"      ]] || die "--app-dir is required"
[[ -n "$CFG_PATH"     ]] || die "--config is required"
[[ -n "$DESCRIPTION"  ]] || DESCRIPTION="$SERVICE_NAME - seren constellation service"

VPY="$VENV_DIR/bin/python"
[[ -x "$VPY" ]] || die "venv python not found at $VPY  (run the installer for this service first)"
[[ -d "$APP_DIR" ]] || die "app dir not found: $APP_DIR  (run the installer for this service first)"
[[ -f "$CFG_PATH" ]] || warn "config not found at $CFG_PATH - the service will fail until it exists"

ok "service: $SERVICE_NAME"
ok "python:  $VPY"
ok "module:  $MODULE"
ok "appdir:  $APP_DIR"
ok "config:  $CFG_PATH"
[[ ${#EXTRA_ENV[@]} -gt 0 ]] && ok "env:     ${EXTRA_ENV[*]}"

# -- resolve the health-check port -------------------------------------------
if ! $NO_HEALTH_CHECK && [[ "$HEALTH_PORT" -eq 0 && -f "$CFG_PATH" ]]; then
  step "Reading health-check port from config ($CONFIG_PORT_KEY)"
  PORT_READ="$("$VPY" - "$CFG_PATH" "$CONFIG_PORT_KEY" 2>/dev/null <<'PY'
import sys
try:
    import yaml
    cfg = yaml.safe_load(open(sys.argv[1], encoding='utf-8')) or {}
    node = cfg
    for part in sys.argv[2].split('.'):
        node = node[part]
    print(int(node))
except Exception as e:
    print(f'READ_FAILED: {e}')
PY
)"
  if [[ "$PORT_READ" =~ ^[0-9]+$ ]]; then
    HEALTH_PORT="$PORT_READ"
    ok "Port $HEALTH_PORT (from config)"
  else
    warn "Couldn't read '$CONFIG_PORT_KEY' from the config ($PORT_READ)."
    warn "Pass --health-port to enable the post-start health check; skipping it this run."
  fi
fi

# -- render the inline env block (shared by both managers) -------------------
# Empty-array-safe under set -u via the ${arr[@]+...} guard.
SYSTEMD_ENV_LINES=""
for kv in ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"}; do
  SYSTEMD_ENV_LINES+="Environment=${kv}
"
done
LAUNCHD_ENV_BLOCK=""
if [[ ${#EXTRA_ENV[@]} -gt 0 ]]; then
  LAUNCHD_ENV_BLOCK="    <key>EnvironmentVariables</key>
    <dict>
"
  for kv in "${EXTRA_ENV[@]}"; do
    k="${kv%%=*}"; v="${kv#*=}"
    LAUNCHD_ENV_BLOCK+="        <key>${k}</key>
        <string>${v}</string>
"
  done
  LAUNCHD_ENV_BLOCK+="    </dict>
"
fi

# -- install ------------------------------------------------------------------
if $IS_MAC; then
  step "Installing launchd user agent (starts at login, no sudo needed)"
  PLIST_DIR="$HOME/Library/LaunchAgents"
  PLIST="$PLIST_DIR/$LAUNCHD_PREFIX.$SERVICE_NAME.plist"
  mkdir -p "$PLIST_DIR"
  cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LAUNCHD_PREFIX.$SERVICE_NAME</string>
    <key>ProgramArguments</key>
    <array>
        <string>$VPY</string>
        <string>-m</string>
        <string>$MODULE</string>
        <string>--config</string>
        <string>$CFG_PATH</string>
    </array>
${LAUNCHD_ENV_BLOCK}    <key>WorkingDirectory</key>
    <string>$APP_DIR</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$APP_DIR/$SERVICE_NAME.log</string>
    <key>StandardErrorPath</key>
    <string>$APP_DIR/$SERVICE_NAME.err</string>
</dict>
</plist>
PLISTEOF
  launchctl unload "$PLIST" 2>/dev/null || true
  launchctl load -w "$PLIST"
  ok "launchd agent installed: $PLIST"
  ok "Starts automatically at login. Logs: $APP_DIR/$SERVICE_NAME.log"
  LOG_HINT="tail -f $APP_DIR/$SERVICE_NAME.log"
else
  step "Installing systemd service (needs sudo)"
  UNIT="/etc/systemd/system/$SERVICE_NAME.service"
  WIRE_ENV=false
  [[ -n "$ENV_FILE" && -f "$ENV_FILE" ]] && WIRE_ENV=true
  sudo tee "$UNIT" >/dev/null <<UNITEOF
[Unit]
Description=$DESCRIPTION
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$(id -un)
WorkingDirectory=$APP_DIR
ExecStart=$VPY -m $MODULE --config $CFG_PATH
$( $WIRE_ENV && echo "EnvironmentFile=$ENV_FILE" )
${SYSTEMD_ENV_LINES}Restart=on-failure
RestartSec=5
$( [[ "$MEMORY_MAX" != "none" && "$MEMORY_MAX" != "0" ]] && echo "MemoryMax=$MEMORY_MAX" )

[Install]
WantedBy=multi-user.target
UNITEOF
  sudo systemctl daemon-reload
  sudo systemctl enable --now "$SERVICE_NAME"
  ok "Service installed and started"
  LOG_HINT="journalctl -u $SERVICE_NAME -f"
fi

# -- wait for health -----------------------------------------------------------
if $NO_HEALTH_CHECK || [[ "$HEALTH_PORT" -eq 0 ]]; then
  warn "Health check skipped. Eyeball it yourself: $LOG_HINT"
else
  step "Waiting for it to come up"
  for i in $(seq 1 30); do
    sleep 0.5
    if curl -fsS "http://127.0.0.1:${HEALTH_PORT}${HEALTH_PATH}" >/dev/null 2>&1; then
      ok "$SERVICE_NAME is responding on http://127.0.0.1:${HEALTH_PORT}"; break
    fi
    [[ $i -eq 30 ]] && warn "Didn't respond in 15s - check: $LOG_HINT"
  done
fi

echo
echo -e "${G}Manage it:${NC}"
if $IS_MAC; then
  echo -e "  launchctl unload/load ~/Library/LaunchAgents/$LAUNCHD_PREFIX.$SERVICE_NAME.plist"
  echo -e "  $LOG_HINT"
else
  echo -e "  sudo systemctl restart $SERVICE_NAME"
  echo -e "  sudo systemctl status  $SERVICE_NAME"
  echo -e "  $LOG_HINT"
fi
echo -e "${G}Rip it and win. 🌭🔧${NC}"