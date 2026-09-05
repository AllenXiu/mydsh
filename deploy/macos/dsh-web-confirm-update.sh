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
#    - the dialog splits plugins into a prominent CONFLICT section and a
#      compatible section; "Update" UNINSTALLS every conflicting plugin, then
#      runs `npm install -g @deepseek-ai/dsh@<tag>` and shows a progress window
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

# Pre-flight plugin compatibility report against the TARGET version, so the
# dialog shows whether an upgrade would break installed plugins.
COMPAT_CHECK="$HOME/.dsh/bin/dsh-web-plugin-compat-check.mjs"
COMPAT_MSG=""
if [ -f "$COMPAT_CHECK" ]; then
  COMPAT_MSG="$(node "$COMPAT_CHECK" --host "$LATEST" 2>/dev/null || true)"
  log "confirm-update: plugin compat vs $LATEST:"
  log "$COMPAT_MSG"
fi

# Split the compat report into two visually separate sections: CONFLICT
# plugins first (prominent), compatible ones after.
CONFLICT_LINES=""
OK_LINES=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  case "$line" in
    *'CONFLICT'*) CONFLICT_LINES="$CONFLICT_LINES$line
" ;;
    *) OK_LINES="$OK_LINES$line
" ;;
  esac
done <<< "$COMPAT_MSG"

# Compact every report line to just its status token and package@version so
# the dialog stays small (full reasons stay in the log). Line shape:
#   "  !! @scope/pkg@1.2.3  CONFLICT on dsh ..."  ->  "⚠  @scope/pkg@1.2.3"
#   "  ok pkg@1.2.3 ..." / "  -- pkg@1.2.3 ..."   ->  "✓  pkg@1.2.3"
compact_lines() {
  printf '%s\n' "$1" \
    | awk '{ if (NF >= 2) { if ($1 == "!!") print "⚠ ", $2; else print "✓ ", $2 } }' \
    | sed 's/^/    /'
}
CONFLICT_COMPACT="$(compact_lines "$CONFLICT_LINES")"
OK_COMPACT="$(compact_lines "$OK_LINES")"
if [ -n "$OK_COMPACT" ]; then
  OK_COUNT="$(printf '%s\n' "$OK_COMPACT" | sed '/^[[:space:]]*$/d' | grep -c .)"
else
  OK_COUNT=0
fi

# Try a native GUI dialog first (macOS Aqua session).
ANSWER=""
rc=1
if command -v osascript >/dev/null 2>&1; then
  if [ -n "$CONFLICT_COMPACT" ]; then
    BODY="官方发布了新版本 dsh：$INSTALLED → $LATEST

⚠️ 升级将自动卸载以下不兼容插件：
$CONFLICT_COMPACT
✅ 其余 $OK_COUNT 个已安装插件兼容新版

是否更新？"
  else
    BODY="官方发布了新版本 dsh：$INSTALLED → $LATEST

✅ 已安装插件均兼容新版

是否立即更新？"
  fi
  # osascript heredoc: escape double quotes for AppleScript string safety.
  BODY_ESC="$(printf '%s' "$BODY" | sed 's/"/\\"/g')"
  ANSWER="$(osascript <<EOF 2>/dev/null
set appName to "DeepSeek Harness"
set msg to "$BODY_ESC"
display dialog msg with title appName buttons {"跳过", "更新"} default button "更新" cancel button "跳过" with icon caution giving up after 60
EOF
)"
  rc=$?
fi

if [ "$rc" = 0 ]; then
  # Dialog answered. osascript returns the clicked button text.
  case "$ANSWER" in
    *"更新"*)
      log "confirm-update: user chose UPDATE"
      # 1) UNINSTALL plugins that would conflict with the target host version,
      #    so a broken third-party plugin can never take the main project
      #    down. (Previously these were locked via cordis disable; removal is
      #    cleaner and keeps the profile manifest in sync.)
      if [ -n "$CONFLICT_LINES" ]; then
        CONFLICT_NAMES="$(printf '%s' "$CONFLICT_LINES" \
          | grep -oE '@[a-z0-9._-]+/[a-z0-9._-]+@[0-9][^ ]*|[a-z0-9][a-z0-9._-]*@[0-9][^ ]*' \
          | sed -E 's/@[0-9][^@]*$//' \
          | sort -u)"
        for PLUGIN in $CONFLICT_NAMES; do
          log "confirm-update: uninstalling conflicting plugin $PLUGIN"
          ( cd "$HOME/.dsh/profiles/web" \
              && dsh plugin --profile web remove "$PLUGIN" >> "$LOG" 2>&1 ) \
            || log "WARN confirm-update: failed to remove $PLUGIN; continuing"
        done
        # Clean any leftover lock rows for the removed plugins (from earlier
        # plugin-lock versions of this flow).
        LOCKER="$HOME/.dsh/bin/dsh-web-plugin-lock.sh"
        if [ -x "$LOCKER" ]; then
          bash "$LOCKER" unlock >> "$LOG" 2>&1 || true
        fi
      fi
      # 2) Show a live progress window while npm installs the new dsh.
      PROGRESS_BIN="$HOME/.dsh/bin/dsh-update-progress"
      STATUS_FILE="$HOME/.dsh/update-progress.txt"
      NPM_LIVE="$HOME/.dsh/npm-install.live.log"
      PROGRESS_PID=""
      if [ -x "$PROGRESS_BIN" ]; then
        printf 'STATUS:UPDATE|正在更新官方 dsh（%s -> %s）...\n' "$INSTALLED" "$LATEST" > "$STATUS_FILE"
        "$PROGRESS_BIN" "$STATUS_FILE" >/dev/null 2>&1 &
        PROGRESS_PID=$!
        log "confirm-update: progress window pid=$PROGRESS_PID"
      fi

      # Run npm, appending output to a live log. The dialog shows only short
      # canned status lines (never raw npm output, which would widen it).
      : > "$NPM_LIVE"
      npm install -g "@deepseek-ai/dsh@$DSH_TAG" >> "$NPM_LIVE" 2>&1 &
      NPM_PID=$!
      PHASE=0
      while kill -0 "$NPM_PID" 2>/dev/null; do
        if [ -n "$PROGRESS_PID" ]; then
          PHASE=$(( (PHASE + 1) % 3 ))
          case "$PHASE" in
            0) MSG="正在下载并安装新版本，请稍候..." ;;
            1) MSG="正在更新依赖包..." ;;
            2) MSG="即将完成..." ;;
          esac
          printf 'STATUS:UPDATE|%s\n' "$MSG" > "$STATUS_FILE"
        fi
        sleep 1
      done
      wait "$NPM_PID"
      NPM_RC=$?

      if [ "$NPM_RC" -eq 0 ]; then
        log "confirm-update: updated to $(dsh --version 2>/dev/null || echo unknown)"
        if [ -n "$PROGRESS_PID" ]; then
          printf 'STATUS:DONE|更新完成，当前版本：%s\n' "$(dsh --version 2>/dev/null)" > "$STATUS_FILE"
        fi
        exit 1
      else
        log "WARN confirm-update: npm install failed; keeping $INSTALLED"
        if [ -n "$PROGRESS_PID" ]; then
          printf 'STATUS:ERROR|更新失败，请查看 %s\n' "$LOG" > "$STATUS_FILE"
        fi
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
