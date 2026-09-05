#!/bin/bash
# ============================================================================
#  dsh-web-plugin-lock.sh - "plugin lock" for the dsh web profile.
#
#  Purpose : when the main project (official @deepseek-ai/dsh) is upgraded,
#            third-party plugins that would CONFLICT with the new host version
#            are automatically DISABLED (locked) so they can never break the
#            main project's boot or runtime. The plugin stays installed; only
#            its cordis row is patched to `disabled: true`. Nothing is removed.
#
#  Where   : the user patch layer of the web profile
#            (~/.dsh/profiles/web/cordis.patch.yml) is maintained by this
#            script. Lock bookkeeping lives in ~/.dsh/plugin-lock.json.
#
#  Commands:
#    lock   <hostVersion>   disable every third-party plugin whose declared
#                           compatibility rejects <hostVersion>
#    unlock [plugin...]     re-enable locked plugins (default: all)
#    status                 print the current lock table
#    sync                   reconcile the patch layer against the lock file
#
#  Exit: 0 always (report is text output); lock failures are logged.
# ============================================================================
set -u

PROFILE_DIR="${DSH_PROFILE_DIR:-$HOME/.dsh/profiles/web}"
PATCH="$PROFILE_DIR/cordis.patch.yml"
LOCK="$HOME/.dsh/plugin-lock.json"
LOG="$HOME/.dsh/autostart-update.log"
NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
COMPAT_CHECK="$HOME/.dsh/bin/dsh-web-plugin-compat-check.mjs"

export NVM_DIR
# shellcheck source=/dev/null
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
nvm use default >/dev/null 2>&1 || true

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] plugin-lock: $*" >> "$LOG"; }

command="${1:-status}"
host_version="${2:-}"

mkdir -p "$(dirname "$LOCK")"

# ---- helpers for the YAML patch layer (delegated to node) ----
merge_patch() {
  node - "$@" <<'EOF'
const fs = require('node:fs')
// argv: [node, '-', <patchPath>, <mode>, <targets...>]
const patchPath = process.argv[2]
const mode = process.argv[3]            // 'disable' | 'enable'
const targets = process.argv.slice(4)   // plugin row ids

let patch = []
try { patch = JSON.parse(fs.readFileSync(patchPath, 'utf8')) } catch {
  // file is YAML '[]' or comment header; fall back to a bare array parse
  try {
    const text = fs.readFileSync(patchPath, 'utf8')
    const trimmed = text.replace(/^#.*$/gm, '').trim()
    if (trimmed === '[]' || trimmed === '') patch = []
    else throw new Error('unparsable patch')
  } catch { patch = [] }
}

// Remove any previous lock rows for these ids so re-running is idempotent.
patch = patch.filter((row) => !(row && typeof row === 'object' && !Array.isArray(row)
  && targets.includes(row.id) && (row.disabled === true || (mode === 'enable' && typeof row.disabled === 'boolean'))))

if (mode === 'disable') {
  for (const id of targets) {
    patch.push({ id, disabled: true })
  }
}

fs.writeFileSync(patchPath, JSON.stringify(patch, null, 2) + '\n')
EOF
}

write_lock() {
  printf '%s\n' "$1" > "$LOCK"
}

read_lock() {
  if [ -f "$LOCK" ]; then cat "$LOCK"; else echo '{}'; fi
}

# ---- command: status ----
status_cmd() {
  echo "Lock file: $LOCK"
  if [ -s "$LOCK" ]; then cat "$LOCK"; else echo "  (no locked plugins)"; fi
  echo ""
  echo "Patch rows currently disabled:"
  node - "$PATCH" <<'EOF'
const fs = require('node:fs')
const p = process.argv[1]
let patch = []
try { patch = JSON.parse(fs.readFileSync(p, 'utf8')) } catch { /* noop */ }
const rows = patch.filter((r) => r && typeof r === 'object' && !Array.isArray(r) && r.disabled === true)
if (rows.length === 0) console.log('  (none)')
else for (const r of rows) console.log(`  - ${r.id}  disabled`)
EOF
}
# ---- command: lock <hostVersion> ----
lock_cmd() {
  if [ -z "$host_version" ]; then
    echo "usage: dsh-web-plugin-lock.sh lock <hostVersion>"
    exit 1
  fi
  if [ ! -f "$COMPAT_CHECK" ]; then
    echo "compat checker not found: $COMPAT_CHECK"
    exit 1
  fi

  # Conflicting plugin package names come straight from the shared compat-check
  # (its --conflict-names mode) so the extraction regex is not re-implemented
  # in bash here (single source: deploy/shared/dsh-web-plugin-compat-check.mjs).
  local conflicts
  conflicts="$(node "$COMPAT_CHECK" --host "$host_version" --conflict-names 2>/dev/null || true)"

  if [ -z "$conflicts" ]; then
    log "lock: no conflicts detected for dsh $host_version - nothing to lock"
    echo "No conflicting plugins for dsh $host_version - nothing to lock."
    return 0
  fi

  echo "Locking conflicting plugins for dsh $host_version:"
  local names=()
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    names+=("$name")
    echo "  - $name"
  done <<< "$conflicts"

  # Map plugin names to row ids from each plugin's own patch file.
  local rows=()
  local lock_map='{}'
  local name
  for name in "${names[@]}"; do
    local pkg_patch="$PROFILE_DIR/node_modules/$name/cordis.patch.yml"
    local row_id="$name"
    if [ -f "$pkg_patch" ]; then
      row_id="$(sed -n 's/^[[:space:]]*-[[:space:]]*id:[[:space:]]*\([^[:space:]]*\).*/\1/p' "$pkg_patch" | head -1)"
      [ -n "$row_id" ] || row_id="$name"
    fi
    rows+=("$row_id")
    lock_map="$(node -e "const m=JSON.parse(process.argv[1]);m[process.argv[2]]={rowId:process.argv[3],lockedAt:new Date().toISOString(),reason:'conflicts with dsh '+process.argv[4]};console.log(JSON.stringify(m))" "$lock_map" "$name" "$row_id" "$host_version")"
  done

  merge_patch "$PATCH" disable "${rows[@]}"

  local prev next_lock
  prev="$(read_lock)"
  # Merge the new conflict entries into lock.locked (a.locked is the map of
  # pluginName -> {rowId, lockedAt, reason}); do not nest another 'locked' key.
  next_lock="$(node -e "const a=JSON.parse(process.argv[1]);const entries=JSON.parse(process.argv[2]);a.locked=a.locked||{};for(const k of Object.keys(entries))a.locked[k]=entries[k];a.updatedAt=new Date().toISOString();console.log(JSON.stringify(a))" "$prev" "$lock_map")"
  write_lock "$next_lock"

  log "locked ${#rows[@]} plugin(s) for dsh $host_version: ${rows[*]}"
  echo "Locked ${#rows[@]} plugin(s). Run 'dsh-web-plugin-lock.sh unlock' to re-enable later."
}


# ---- command: unlock [plugin...] ----
unlock_cmd() {
  local lock_data ids
  lock_data="$(read_lock)"
  if [ $# -gt 1 ]; then
    ids=""
    local n
    for n in "${@:2}"; do
      local rid
      rid="$(node -e "const l=JSON.parse(process.argv[1]);console.log((l.locked||{})[process.argv[2]]?.rowId||'')" "$lock_data" "$n")"
      [ -n "$rid" ] && ids="$ids $rid"
    done
  else
    ids="$(node -e "const l=JSON.parse(process.argv[1]);for(const k in (l.locked||{}))console.log(l.locked[k].rowId)" "$lock_data")"
  fi

  if [ -z "$(echo "$ids" | tr -d ' ')" ]; then
    echo "Nothing to unlock."
    return 0
  fi

  merge_patch "$PATCH" enable ${ids}

  local next_lock
  next_lock="$(node - "$lock_data" ${ids} <<'EOF'
// argv: [node, '-', <lockData>, <rowIds...>]
const lock = JSON.parse(process.argv[2])
const ids = new Set(process.argv.slice(3))
for (const k of Object.keys(lock.locked || {})) {
  if (ids.has(lock.locked[k].rowId)) delete lock.locked[k]
}
if (!lock.locked || Object.keys(lock.locked).length === 0) {
  console.log('{}')
} else {
  console.log(JSON.stringify(lock))
}
EOF
)"
  write_lock "$next_lock"
  echo "Unlocked: ${ids}"
  log "unlocked: ${ids}"
}

# ---- command: sync (reconcile patch rows from lock file, idempotent) ----
sync_cmd() {
  local lock_data locked_rows
  lock_data="$(read_lock)"
  locked_rows="$(node -e "const l=JSON.parse(process.argv[1]);for(const k in (l.locked||{}))console.log(l.locked[k].rowId)" "$lock_data")"
  if [ -n "$(echo "$locked_rows" | tr -d ' ')" ]; then
    merge_patch "$PATCH" disable ${locked_rows}
    echo "synced: disabled ${locked_rows}"
  else
    echo "no locked plugins to sync."
  fi
}

case "$command" in
  lock) lock_cmd "$@" ;;
  unlock) unlock_cmd "$@" ;;
  status) status_cmd ;;
  sync) sync_cmd ;;
  *) echo "usage: dsh-web-plugin-lock.sh {lock <hostVersion>|unlock [plugin...]|status|sync}"; exit 1 ;;
esac

