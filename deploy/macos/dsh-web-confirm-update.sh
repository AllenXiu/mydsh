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

# Split the compat report into three visually separate sections using the
# machine-readable verdict stream (shared single source, same as Windows):
#   REJECT (!!) plugins -> will be auto-uninstalled (prominent first)
#   WARN   (??) plugins -> kept; only a stale release list, surfaced for info
#   everything else      -> compatible / unverified
VERDICT_MSG=""
REJECT_NAMES=""
WARN_NAMES=""
if [ -f "$COMPAT_CHECK" ]; then
  VERDICT_MSG="$(node "$COMPAT_CHECK" --host "$LATEST" --verdict-names 2>/dev/null || true)"
  REJECT_NAMES="$(printf '%s\n' "$VERDICT_MSG" | awk -F '\t' '$1 == "!!" { print $2 }')"
  WARN_NAMES="$(printf '%s\n' "$VERDICT_MSG" | awk -F '\t' '$1 == "??" { print $2 }')"
fi

# Count remaining (compatible) plugins from the human report for a summary line.
COMPAT_COUNT="$(printf '%s' "$COMPAT_MSG" | grep -cE '^  (ok|--) ' || true)"
[ -n "$COMPAT_COUNT" ] || COMPAT_COUNT=0

REJECT_DISPLAY="$(printf '%s\n' "$REJECT_NAMES" | sed '/^$/d' | sed 's/^/    ⚠  /')"
WARN_DISPLAY="$(printf '%s\n' "$WARN_NAMES" | sed '/^$/d' | sed 's/^/    ·  /')"

# Try a native GUI dialog first (macOS Aqua session).
ANSWER=""
rc=1
if command -v osascript >/dev/null 2>&1; then
  if [ -n "$REJECT_DISPLAY" ]; then
    BODY="官方发布了新版本 dsh：$INSTALLED → $LATEST

⚠️ 升级将自动卸载以下不兼容插件：
$REJECT_DISPLAY"
    if [ -n "$WARN_DISPLAY" ]; then
      BODY="$BODY

ℹ️ 以下插件尚未声明支持 $LATEST，本次保留（升级后异常请手动卸载）：
$WARN_DISPLAY"
    fi
    BODY="$BODY
✅ 其余 $COMPAT_COUNT 个已安装插件兼容新版

是否更新？"
  elif [ -n "$WARN_DISPLAY" ]; then
    BODY="官方发布了新版本 dsh：$INSTALLED → $LATEST

ℹ️ 以下插件尚未声明支持 $LATEST（无硬冲突，本次保留）：
$WARN_DISPLAY
✅ 其余 $COMPAT_COUNT 个已安装插件兼容新版

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
      # 1) UNINSTALL plugins the shared compat-check REJECTed (!!) for the
      #    target host version, so a broken third-party plugin can never take
      #    the main project down. WARN (??) plugins are deliberately KEPT.
      if [ -n "$REJECT_NAMES" ]; then
        for PLUGIN in $REJECT_NAMES; do
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
