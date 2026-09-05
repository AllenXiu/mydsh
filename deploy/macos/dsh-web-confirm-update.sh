#!/bin/bash
# ============================================================================
#  dsh-web-confirm-update.sh - interactive "update the official dsh?" prompt.
#
#  Called on every dsh web (re)start and after every screen unlock. Instead of
#  silently running `npm install -g`, it asks the human first via a native
#  macOS dialog (osascript). The launchd autostart never upgrades behind the
#  user's back again.
#
#  Behaviour:
#    - compares the installed @deepseek-ai/dsh with the official npm release
#      on the configured dist-tag (DSH_TAG, default: latest)
#    - if they match           -> prints "up-to-date", exit 0 (no prompt)
#    - if a newer release exists:
#        - in a GUI session    -> native dialog with Update / Skip buttons
#        - without GUI/terminal-> logs a note, does NOT update (fail safe)
#    - "Update" -> runs `npm install -g @deepseek-ai/dsh@<tag>`
#    - "Skip"   -> leaves the installed version untouched
#  Exit: 0 when the installed dsh is current OR the user chose Skip
#        1 when an update was performed (caller may restart the server)
# ============================================================================
set -u

PORT="${PORT:-3080}"
DSH_TAG="${DSH_TAG:-latest}"
LOG="$HOME/.dsh/autostart-update.log"
NVM_DIR="${NVM_DIR:-$HOME/.nvm}"

export NVM_DIR
# shellcheck source=/dev/null
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
nvm use default >/dev/null 2>&1 || true

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*" >> "$LOG"; }

INSTALLED="$(dsh --version 2>/dev/null || echo none)"
LATEST="$(npm view "@deepseek-ai/dsh@$DSH_TAG" version 2>/dev/null || echo unknown)"

log "confirm-update: installed=$INSTALLED latest($DSH_TAG)=$LATEST"

# --- No newer release (or registry unreachable): nothing to ask ---
if [ "$LATEST" = "unknown" ]; then
  log "confirm-update: registry unreachable - keeping $INSTALLED"
  exit 0
fi
if [ "$LATEST" = "$INSTALLED" ]; then
  log "confirm-update: already on $INSTALLED - no prompt needed"
  exit 0
fi

# --- A newer official release exists: ask the human ---
log "confirm-update: newer official dsh available ($INSTALLED -> $LATEST), prompting"

# Try a native GUI dialog first (macOS Aqua session).
ANSWER=""
if command -v osascript >/dev/null 2>&1; then
  ANSWER="$(osascript <<EOF 2>/dev/null
set appName to "DeepSeek Harness"
set msg to "官方发布了新版本 dsh：\r当前 $INSTALLED\r最新 $LATEST\r\r是否立即更新？"
display dialog msg with title appName buttons {"跳过", "更新"} default button "更新" cancel button "跳过" with icon caution
EOF
)"
  rc=$?
fi

if [ "$rc" = 0 ]; then
  # Dialog answered. osascript returns the clicked button text.
  case "$ANSWER" in
    *"更新"*)
      log "confirm-update: user chose UPDATE"
      if npm install -g "@deepseek-ai/dsh@$DSH_TAG" >> "$LOG" 2>&1; then
        log "confirm-update: updated to $(dsh --version 2>/dev/null || echo unknown)"
        exit 1
      else
        log "WARN confirm-update: npm install failed; keeping $INSTALLED"
        exit 0
      fi
      ;;
    *)
      log "confirm-update: user chose SKIP - staying on $INSTALLED"
      exit 0
      ;;
  esac
fi

# No GUI session / dialog dismissed: fail safe, do not auto-upgrade.
log "confirm-update: no interactive session - keeping $INSTALLED (no silent upgrade)"
exit 0
