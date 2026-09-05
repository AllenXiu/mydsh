#!/bin/bash
# ============================================================================
#  DeepSeek Harness Web UI - screen-unlock sync (macOS)
#  What    : runs after every screen unlock (via the dsh-web-unlock watcher).
#            macOS rarely reboots, so this gives Windows' "every boot" the
#            chance to refresh dsh - but only AFTER the human confirms.
#  Logic   : 1. ask npm what the latest official @deepseek-ai/dsh is
#            2. compare with the currently installed / running version
#            3. a newer official release exists (or the web UI is down) ->
#               ask the human via a native dialog (dsh-web-confirm-update.sh);
#               only an explicit "Update" restarts the web UI. A "Skip" never
#               interrupts a running session.
#  Logs    : $HOME/.dsh/autostart-update.log
# ============================================================================
set -u

PORT="${PORT:-3080}"
LABEL="com.allern.dsh-web"
# Official npm dist-tag this deployment follows (`latest` = 0.1.2 line as of
# 2026-09). Must match dsh-web-autostart.sh / dsh-web-confirm-update.sh.
DSH_TAG="${DSH_TAG:-latest}"
LOG="$HOME/.dsh/autostart-update.log"
NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
CONFIRM="$HOME/.dsh/bin/dsh-web-confirm-update.sh"

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

NEED_RESTART=0
if [ "$RUNNING" -eq 0 ]; then
  # Web is down: always bring it back. The autostart step it triggers will ask
  # the update question on its own, so no extra prompt here.
  log "web UI is not running - restarting via LaunchAgent."
  NEED_RESTART=1
elif [ "$LATEST" != "unknown" ] && [ "$LATEST" != "$INSTALLED" ]; then
  # Web is up but a newer official release exists: ask the human first.
  log "newer official dsh available ($INSTALLED -> $LATEST) - asking user"
  if [ -x "$CONFIRM" ]; then
    if bash "$CONFIRM"; then
      log "user declined the update - keeping $INSTALLED and running session."
    else
      # User clicked Update (exit 1): upgrade now, then restart to run it.
      log "user approved the update - restarting web UI via LaunchAgent."
      NEED_RESTART=1
    fi
  else
    log "WARN $CONFIRM missing - keeping current version (no silent upgrade)."
  fi
else
  log "already on the latest official dsh and web is up - nothing to do."
fi

if [ "$NEED_RESTART" -eq 1 ]; then
  if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
    # -k kills the current instance, then starts it again (RunAtLoad); the
    # autostart script asks the update question if needed, then runs
    # `dsh web --no-open`.
    launchctl kickstart -k "gui/$(id -u)/$LABEL"
    log "kickstarted $LABEL"
  else
    log "WARN LaunchAgent $LABEL not loaded; starting directly."
    bash "$HOME/.dsh/bin/dsh-web-autostart.sh" >> "$LOG" 2>&1 &
  fi
fi

log "===== unlock sync end ====="
exit 0
