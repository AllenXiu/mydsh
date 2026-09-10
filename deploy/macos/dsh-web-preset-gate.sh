#!/bin/bash
# ============================================================================
#  dsh-web-preset-gate.sh - keep sessions startable when a preset stops mounting.
#
#  The web profile resolves the preset a new/resumed session mounts from the
#  user setting `agent-presets.default` in $DSH_HOME/settings.yaml. When that
#  preset stops mounting - a host upgrade renames a plugin config key, a plugin
#  re-syncs its bundled preset, a hand-authored row goes stale - EVERY new and
#  resumed session fails with "preset ... failed to mount", while the rest of
#  the deployment (update check, plugins, web process) looks healthy. This gate
#  therefore runs before the web starts and right after a dsh upgrade:
#
#    1. probe the effective default preset through the mount probe, which calls
#       agentPresets.standingKeyFor() - the same path a session creation uses;
#    2. FAIL(config) -> repair the known row-key renames in place (file backed
#       up first) and probe again;
#    3. still FAIL(config) -> fall back `agent-presets.default` to `standard`
#       (settings backed up first), so sessions work while the preset is fixed;
#    4. FAIL(host) / INCONCLUSIVE -> log only; an ambiguous signal never
#       rewrites a user file.
#
#  The gate NEVER blocks the web start: every path logs and exits 0, and the
#  notification dialog runs in the background.
#
#  Usage: bash dsh-web-preset-gate.sh [options]
#    --preset <id>      preset to guard (default: agent-presets.default)
#    --fallback <id>    preset used when the guard cannot repair (default: standard)
#    --settings <path>  settings file (default: $DSH_HOME/settings.yaml)
#    --home <dir>       harness home (default: $DSH_HOME, else $HOME/.dsh)
#    --no-notify        do not open a dialog (tests / automation)
#    --dry-run          report what would change without writing
#    --quiet            log only actions and failures
# ============================================================================
set -u

DSH_HOME_DIR="${DSH_HOME:-$HOME/.dsh}"
LOG="$DSH_HOME_DIR/autostart-update.log"
BIN_DIR="$DSH_HOME_DIR/bin"
PROBE_BIN="${PRESET_PROBE_BIN:-$BIN_DIR/dsh-agent-preset-mount-probe.mjs}"
FALLBACK="standard"
PRESET=""
SETTINGS=""
NO_NOTIFY=0
DRY_RUN=0
QUIET=0

while [ $# -gt 0 ]; do
  case "$1" in
    --preset) PRESET="${2:-}" ; shift 2 ;;
    --fallback) FALLBACK="${2:-}" ; shift 2 ;;
    --settings) SETTINGS="${2:-}" ; shift 2 ;;
    --home) DSH_HOME_DIR="${2:-}" ; shift 2 ;;
    --no-notify) NO_NOTIFY=1 ; shift ;;
    --dry-run) DRY_RUN=1 ; shift ;;
    --quiet) QUIET=1 ; shift ;;
    *) echo "dsh-web-preset-gate: unknown option: $1" >&2 ; exit 2 ;;
  esac
done

DSH_HOME_DIR="${DSH_HOME_DIR/#\~/$HOME}"
SETTINGS="${SETTINGS:-$DSH_HOME_DIR/settings.yaml}"
LOG="$DSH_HOME_DIR/autostart-update.log"
BIN_DIR="$DSH_HOME_DIR/bin"
: "${PROBE_BIN:=}"
[ -n "$PROBE_BIN" ] || PROBE_BIN="$BIN_DIR/dsh-agent-preset-mount-probe.mjs"

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*" >> "$LOG"; }

# --- read the value of a nested key under a top-level block in settings.yaml ---
settings_value() {
  awk -v block="$1" -v key="$2" '
    $0 ~ "^" block ":" { inblock = 1; next }
    inblock && /^[^[:space:]#]/ { inblock = 0 }
    inblock && $0 ~ "^[[:space:]]+" key ":" {
      value = $0
      sub("^[[:space:]]+" key ":[[:space:]]*", "", value)
      sub(/[[:space:]]+$/, "", value)
      gsub(/^["'"'"']|["'"'"']$/, "", value)
      print value
      exit
    }
  ' "$3"
}

# --- line number of `default:` inside the top-level `agent-presets:` block ---
settings_default_line() {
  awk '
    /^agent-presets:[[:space:]]*$/ { inblock = 1; next }
    inblock && /^[^[:space:]#]/ { inblock = 0 }
    inblock && /^[[:space:]]+default:/ { print NR }
  ' "$1"
}

# --- line number of the `text:` key of the persona row in agent.cordis.yml ---
persona_text_line() {
  awk '
    /^- id:[[:space:]]*persona[[:space:]]*$/ { inrow = 1; named = 0; prefixed = 0; next }
    inrow && /^- / { if (named && !prefixed && textline > 0) print textline; inrow = 0 }
    inrow && /dsh-persona/ { named = 1 }
    inrow && /^[[:space:]]+prefix:/ { prefixed = 1 }
    inrow && /^[[:space:]]+text:/ { textline = NR }
    END { if (inrow && named && !prefixed && textline > 0) print textline }
  ' "$1"
}

# --- run the mount probe for one preset; echoes "<VERDICT>|<message>" ---
probe_verdict() {
  local out first
  out="$(node "$PROBE_BIN" --preset "$1" --home "$DSH_HOME_DIR" 2>&1)" || true
  first="$(printf '%s\n' "$out" | awk 'NF { print; exit }')"
  printf '%s|%s\n' "$(printf '%s' "$first" | awk '{ print $1 }')" \
    "$(printf '%s' "$first" | sed 's/^[^ ]*[[:space:]][^ ]*[[:space:]]-[[:space:]]*//')"
}

# --- background dialog so a login-time notification never delays the web ---
notify() {
  [ "$NO_NOTIFY" -eq 1 ] && return 0
  command -v osascript >/dev/null 2>&1 || return 0
  local escaped
  escaped="$(printf '%s' "$1" | sed 's/"/\\"/g')"
  (
    osascript >/dev/null 2>&1 <<EOF
set appName to "DeepSeek Harness"
set msg to "$escaped"
display dialog msg with title appName buttons {"知道了"} default button "知道了" with icon caution giving up after 60
EOF
  ) &
}

# --- rewrite the known persona key rename in place (idempotent, backed up) ---
repair_persona_prefix() {
  local file="$1/agent.cordis.yml" line count
  [ -f "$file" ] || return 1
  line="$(persona_text_line "$file")"
  count="$(printf '%s\n' "$line" | grep -c '[0-9]')"
  if [ "$count" -ne 1 ]; then
    log "preset-gate: persona repair skipped (candidate rows=$count in $file)"
    return 1
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    log "preset-gate: [dry-run] would rewrite $file:$line (text: -> prefix:)"
    return 0
  fi
  cp "$file" "$file.bak-$(date +%Y%m%d-%H%M%S)"
  sed -i '' "${line}s/^\([[:space:]]*\)text:/\1prefix:/" "$file"
  log "preset-gate: rewrote $file:$line (persona text: -> prefix:), backup beside it"
  return 0
}

# --- fall back the user default preset (idempotent, backed up) ---
set_settings_default() {
  local new="$1" line count
  [ -f "$SETTINGS" ] || return 1
  line="$(settings_default_line "$SETTINGS")"
  count="$(printf '%s\n' "$line" | grep -c '[0-9]')"
  if [ "$count" -ne 1 ]; then
    log "preset-gate: settings fallback skipped (agent-presets.default lines=$count in $SETTINGS)"
    return 1
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    log "preset-gate: [dry-run] would set $SETTINGS:$line agent-presets.default -> $new"
    return 0
  fi
  cp "$SETTINGS" "$SETTINGS.bak-$(date +%Y%m%d-%H%M%S)"
  sed -i '' "${line}s/default:.*/default: ${new}/" "$SETTINGS"
  log "preset-gate: set agent-presets.default -> $new ($SETTINGS), backup beside it"
  return 0
}

# --- main -------------------------------------------------------------------
if [ ! -f "$PROBE_BIN" ]; then
  log "WARN preset-gate: probe missing ($PROBE_BIN) - run deploy/macos/install.sh; skipping"
  exit 0
fi
if ! command -v node >/dev/null 2>&1; then
  log "WARN preset-gate: node not on PATH - skipping"
  exit 0
fi
if [ ! -f "$SETTINGS" ]; then
  log "preset-gate: no $SETTINGS - nothing user-owned to guard"
  exit 0
fi

if [ -z "$PRESET" ]; then
  PRESET="$(settings_value agent-presets default "$SETTINGS")" || {
    log "WARN preset-gate: cannot parse $SETTINGS - skipping (no file was changed)"
    exit 0
  }
fi
if [ -z "$PRESET" ]; then
  log "preset-gate: no agent-presets.default set (composition default applies) - nothing to guard"
  exit 0
fi
PRESET_DIR="$DSH_HOME_DIR/.agent-presets/$PRESET"

[ "$QUIET" -eq 1 ] || log "preset-gate: guarding preset \"$PRESET\" ($PRESET_DIR)"
RESULT="$(probe_verdict "$PRESET")"
VERDICT="${RESULT%%|*}"
MESSAGE="${RESULT#*|}"

case "$VERDICT" in
  OK)
    [ "$QUIET" -eq 1 ] || log "preset-gate: preset \"$PRESET\" mounts OK"
    exit 0
    ;;
  FAIL\(config\))
    log "preset-gate: preset \"$PRESET\" failed config validation - $MESSAGE"
    case "$MESSAGE" in
      *dsh-persona*)
        if repair_persona_prefix "$PRESET_DIR"; then
          if [ "$DRY_RUN" -eq 1 ]; then
            log "preset-gate: [dry-run] repair not applied - stopping here"
            exit 0
          fi
          RESULT="$(probe_verdict "$PRESET")"
          VERDICT="${RESULT%%|*}"
          if [ "$VERDICT" = "OK" ]; then
            log "preset-gate: repaired preset \"$PRESET\" - sessions can start again"
            notify "预设「${PRESET}」与当前 dsh 不兼容（配置键改名），已自动修复并保留原文件备份。"
            exit 0
          fi
          log "preset-gate: preset \"$PRESET\" still failing after repair - $RESULT"
        fi
        ;;
    esac
    if [ "$DRY_RUN" -eq 1 ]; then
      set_settings_default "$FALLBACK"
      log "preset-gate: [dry-run] fallback not applied - stopping here"
      exit 0
    fi
    if set_settings_default "$FALLBACK"; then
      log "preset-gate: fell back to \"$FALLBACK\" (previous default: \"$PRESET\")"
      notify "预设「${PRESET}」无法挂载（会导致所有会话打不开），已把默认预设临时改为「${FALLBACK}」；原值见日志与备份文件。"
    else
      log "WARN preset-gate: fallback failed; manual action required"
      notify "预设「${PRESET}」无法挂载，且自动回退失败：请手动修改 ~/.dsh/settings.yaml 的 agent-presets.default。"
    fi
    exit 0
    ;;
  *)
    log "preset-gate: verdict=$VERDICT for \"$PRESET\" - not acting on it ($MESSAGE)"
    exit 0
    ;;
esac
