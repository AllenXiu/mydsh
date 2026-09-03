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

# ---- 1. update the official dsh to the latest npm release ----
# Never run the repo fork in production: this Mac deployment follows the
# official npm publish stream on every single start.
if npm install -g @deepseek-ai/dsh@latest >> "$LOG" 2>&1; then
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

