#!/bin/bash
# ============================================================================
#  DeepSeek Harness Web UI - screen-unlock sync (macOS)
#  What    : runs after every screen unlock (via the dsh-web-unlock watcher).
#            macOS rarely reboots, so this gives the "always run the latest
#            official dsh" guarantee that Windows gets from its Startup
#            autostart on every boot.
#  Logic   : 1. ask npm what the latest official @deepseek-ai/dsh is
#            2. compare with the currently installed / running version
#            3. only when a newer official release exists (or the web UI is
#               down) restart the web UI through the LaunchAgent, which
#               re-runs the update check and starts `web --no-open`.
#  Logs    : $HOME/.dsh/autostart-update.log
# ============================================================================
set -u

PORT="${PORT:-3080}"
LABEL="com.allern.dsh-web"
# Dist-tag this deployment follows. dsh-web-all requires the 0.1.2 line that
# npm publishes under `next`; must match dsh-web-autostart.sh's DSH_TAG.
DSH_TAG="${DSH_TAG:-next}"
LOG="$HOME/.dsh/autostart-update.log"
NVM_DIR="${NVM_DIR:-$HOME/.nvm}"

# Ensure Node/npm are on PATH when launched from the watcher (GUI session).
export NVM_DIR
# shellcheck source=/dev/null
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
nvm use default >/dev/null 2>&1 || true

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*" >> "$LOG"; }

log "===== unlock sync begin ====="

# ---- 1. is the web UI currently up? ----
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  RUNNING=1
else
  RUNNING=0
fi

# ---- 2. compare installed vs latest official release on the chosen tag ----
INSTALLED="$(dsh --version 2>/dev/null || echo none)"
LATEST="$(npm view "@deepseek-ai/dsh@$DSH_TAG" version 2>/dev/null || echo unknown)"
log "installed dsh: $INSTALLED | latest official ($DSH_TAG): $LATEST | web running: $RUNNING"

# ---- 3. decide ----
NEED_RESTART=0
if [ "$RUNNING" -eq 0 ]; then
  log "web UI is not running - restarting."
  NEED_RESTART=1
elif [ "$LATEST" != "unknown" ] && [ "$LATEST" != "$INSTALLED" ]; then
  log "newer official dsh available ($INSTALLED -> $LATEST) - restarting."
  NEED_RESTART=1
else
  log "already on the latest official dsh and web is up - nothing to do."
fi

if [ "$NEED_RESTART" -eq 1 ]; then
  if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
    # -k kills the current instance, then starts it again (RunAtLoad); the
    # autostart script re-runs `npm install -g @deepseek-ai/dsh@next`
    # followed by `dsh web --no-open`.
    launchctl kickstart -k "gui/$(id -u)/$LABEL"
    log "kickstarted $LABEL"
  else
    log "WARN LaunchAgent $LABEL not loaded; starting directly."
    bash "$HOME/.dsh/bin/dsh-web-autostart.sh" >> "$LOG" 2>&1 &
  fi
fi

log "===== unlock sync end ====="
exit 0
