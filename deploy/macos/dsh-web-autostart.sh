#!/bin/bash
# ============================================================================
#  DeepSeek Harness Web UI - macOS login autostart (equivalent to the Windows
#  Startup\dsh-web-autostart.vbs)
#  What    : every start first updates the official @deepseek-ai/dsh package
#            to the latest npm release (avoids version drift), then launches
#            `dsh web --no-open`. Used both by the LaunchAgent (login
#            autostart) and by restart-dsh-web.sh after a manual restart.
#  Logs    : $HOME/.dsh/autostart-update.log (same name/location intent as the
#            Windows %USERPROFILE%\.dsh\autostart-update.log)
#  Port    : change PORT below if your web UI is configured on another port.
# ============================================================================
set -u

PORT="${PORT:-3080}"
# Which official npm dist-tag this deployment follows. `latest` is the stable
# preview line (currently 0.1.1 rc). The 0.1.2 development line (dsh-web-all
# family needs it) lives under `next`; that line is NOT compatible with
# @kenz1117/dsh-ui-usage-billing, so this deployment stays on `latest`. Keep
# these three in sync.
DSH_TAG="${DSH_TAG:-latest}"
LOG="$HOME/.dsh/autostart-update.log"
WEB_LOG="$HOME/.dsh/web.log"
NVM_DIR="${NVM_DIR:-$HOME/.nvm}"

# Ensure Node/npm/npx from nvm are on PATH (interactive shells source .zshrc,
# but launchd and cron do not).
export NVM_DIR
# shellcheck source=/dev/null
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
nvm use default >/dev/null 2>&1 || true

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*" >> "$LOG"; }

echo "[$(ts)] ===== dsh web autostart begin =====" >> "$LOG"

# ---- 1. update the official dsh to the latest npm release of the chosen tag ----
# Never run the repo fork in production: this Mac deployment follows the
# official npm publish stream on every single start. DSH_TAG is `latest`;
# see the header note on why this deployment does not follow `next`.
if npm install -g "@deepseek-ai/dsh@$DSH_TAG" >> "$LOG" 2>&1; then
  log "dsh updated/verified: $(dsh --version 2>/dev/null || echo unknown)"
else
  log "WARN dsh update failed (offline?); continuing with existing install"
fi

# ---- 2. if the port is already served, nothing more to do ----
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  log "dsh web already listening on 127.0.0.1:$PORT - nothing to start."
  exit 0
fi

# ---- 3. launch the web UI without opening a browser ----
# Foreground exec is intentional:
#  - when launchd runs this script (login autostart) the LaunchAgent owns the
#    server process, so it stays alive for the whole session;
#  - restart-dsh-web.sh restarts via `launchctl kickstart -k`, which re-runs
#    this script, so the update check runs again on every restart.
log "starting: dsh web --no-open"
exec dsh web --no-open >> "$WEB_LOG" 2>&1

