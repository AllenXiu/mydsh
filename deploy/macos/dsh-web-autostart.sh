#!/bin/bash
# ============================================================================
#  DeepSeek Harness Web UI - macOS login autostart (equivalent to the Windows
#  Startup\dsh-web-autostart.vbs)
#  What    : before launching, ASKS the human (via dsh-web-confirm-update.sh)
#            whether the official @deepseek-ai/dsh should be updated; then
#            launches `dsh web --no-open`. Used both by the LaunchAgent (login
#            autostart) and by restart-dsh-web.sh after a manual restart.
#            No silent upgrade happens anymore - the user decides.
#  Logs    : $HOME/.dsh/autostart-update.log
#  Port    : change PORT below if your web UI is configured on another port.
# ============================================================================
set -u

PORT="${PORT:-3080}"
# Official npm dist-tag this deployment follows: `latest` (0.1.2 line as of
# 2026-09). usage-billing (0.1.1-only) was uninstalled; this host anchors the
# official latest mainline. Keep in sync with the unlock + confirm scripts.
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

# ---- 1. ask the human whether the official dsh should be updated ----
# No silent `npm install -g` anymore: the confirm script compares installed vs
# latest on $DSH_TAG and prompts via a native dialog when a newer release
# exists. Exit 1 means "updated - keep going with the fresh binary".
CONFIRM="$HOME/.dsh/bin/dsh-web-confirm-update.sh"
if [ -x "$CONFIRM" ]; then
  bash "$CONFIRM" || log "confirm-update requested a restart on next start"
else
  log "WARN $CONFIRM missing - skipping update check"
fi

# ---- 2. if the port is already served, nothing more to do ----
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  log "dsh web already listening on 127.0.0.1:$PORT - nothing to start."
  exit 0
fi

# ---- 3. launch the web UI without opening a browser ----
# Foreground exec is intentional: the LaunchAgent owns the server process.
# A background helper watches the startup log and, once the server is up,
# copies the CURRENT process's token URL to ~/.dsh/current-url.txt so the
# human never has to dig for the printed URL after a restart (0.1.2 browser
# auth). web.log is append-only and may hold older processes' URLs, so the
# helper only scans lines appended AFTER this launch began.
CURRENT_URL="$HOME/.dsh/current-url.txt"
LOG_START_LINE="$(wc -l < "$WEB_LOG" 2>/dev/null | tr -d ' ')"
: > "$CURRENT_URL"
(
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
    URL="$(tail -n +$((LOG_START_LINE + 1)) "$WEB_LOG" 2>/dev/null \
      | grep -o 'http://127.0.0.1:[0-9]*/?token=[A-Za-z0-9_-]*' | tail -1)"
    if [ -n "$URL" ]; then
      printf '%s\n' "$URL" > "$CURRENT_URL"
      exit 0
    fi
    sleep 5
  done
) &
log "starting: dsh web --no-open"
exec dsh web --no-open >> "$WEB_LOG" 2>&1

