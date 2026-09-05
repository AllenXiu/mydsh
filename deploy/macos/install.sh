#!/bin/bash
# ============================================================================
#  Install the macOS deployment for the DeepSeek Harness Web UI.
#  This mirrors the Windows deployment (Startup autostart) with a macOS twist:
#  because a Mac is rarely rebooted, the "always run the latest official dsh"
#  guarantee is enforced after every SCREEN UNLOCK instead of only at login.
#    - copies the autostart script to ~/.dsh/bin/dsh-web-autostart.sh
#    - compiles + installs the unlock watcher and its sync script
#    - installs two LaunchAgents:
#        com.allern.dsh-web           starts the web UI (owns the process)
#        com.allern.dsh-web-unlock    watches for screen unlock, restarts the
#                                     web UI when a newer official dsh exists
#    - makes restart-dsh-web.sh / .command executable
#  Usage   : bash deploy/macos/install.sh
# ============================================================================
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
SHARED_DIR="$(cd "$HERE/../shared" && pwd)"
USER_HOME="$HOME"
LABEL_SERVER="com.allern.dsh-web"
LABEL_UNLOCK="com.allern.dsh-web-unlock"
LA_DIR="$HOME/Library/LaunchAgents"
BIN_DIR="$HOME/.dsh/bin"
PLIST_SERVER_SRC="$HERE/$LABEL_SERVER.plist"
PLIST_UNLOCK_SRC="$HERE/$LABEL_UNLOCK.plist"
PLIST_SERVER_DST="$LA_DIR/$LABEL_SERVER.plist"
PLIST_UNLOCK_DST="$LA_DIR/$LABEL_UNLOCK.plist"

echo "==> 1/6 Prepare directories"
mkdir -p "$LA_DIR" "$BIN_DIR"

echo "==> 2/6 Install autostart + unlock + confirm + lock scripts into $BIN_DIR"
cp "$HERE/dsh-web-autostart.sh" "$BIN_DIR/dsh-web-autostart.sh"
cp "$HERE/dsh-web-unlock.sh" "$BIN_DIR/dsh-web-unlock.sh"
cp "$HERE/dsh-web-confirm-update.sh" "$BIN_DIR/dsh-web-confirm-update.sh"
cp "$HERE/dsh-web-plugin-lock.sh" "$BIN_DIR/dsh-web-plugin-lock.sh"
cp "$SHARED_DIR/dsh-web-plugin-compat-check.mjs" "$BIN_DIR/dsh-web-plugin-compat-check.mjs"
chmod +x "$BIN_DIR/dsh-web-autostart.sh" "$BIN_DIR/dsh-web-unlock.sh" "$BIN_DIR/dsh-web-confirm-update.sh" "$BIN_DIR/dsh-web-plugin-lock.sh"

echo "==> 3/6 Compile the screen-unlock watcher and the update progress window"
if [ ! -x "$BIN_DIR/dsh-web-unlock-watcher" ] || [ "$HERE/dsh-web-unlock-watcher.swift" -nt "$BIN_DIR/dsh-web-unlock-watcher" ]; then
  swiftc -O -o "$BIN_DIR/dsh-web-unlock-watcher" "$HERE/dsh-web-unlock-watcher.swift"
fi
chmod +x "$BIN_DIR/dsh-web-unlock-watcher"

if [ ! -x "$BIN_DIR/dsh-update-progress" ] || [ "$HERE/dsh-update-progress.swift" -nt "$BIN_DIR/dsh-update-progress" ]; then
  swiftc -O -o "$BIN_DIR/dsh-update-progress" "$HERE/dsh-update-progress.swift"
fi
chmod +x "$BIN_DIR/dsh-update-progress"

echo "==> 4/6 Install LaunchAgents"
# Substitute the real absolute home path into the plists.
sed -e "s|/Users/allern|$USER_HOME|g" "$PLIST_SERVER_SRC" > "$PLIST_SERVER_DST"
sed -e "s|/Users/allern|$USER_HOME|g" "$PLIST_UNLOCK_SRC" > "$PLIST_UNLOCK_DST"

echo "==> 5/6 Make restart entries executable"
chmod +x "$HERE/../../restart-dsh-web.sh" "$HERE/../../restart-dsh-web.command" 2>/dev/null || true

echo "==> 6/6 Boot the LaunchAgents"

# Boot the agents now (also covers "start right now" via RunAtLoad).
for LABEL in "$LABEL_SERVER" "$LABEL_UNLOCK"; do
  if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
    echo "==> Reloading existing LaunchAgent $LABEL"
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    # launchd needs a beat after bootout before the service name is released;
    # bootstrapping too fast yields "Bootstrap failed: 5: Input/output error".
    sleep 2
  fi
done

boot_or_retry() {
  # shellcheck disable=SC2086
  launchctl bootstrap "gui/$(id -u)" "$1" && return 0
  echo "    bootstrap transient failure; retrying in 2s..."
  sleep 2
  # shellcheck disable=SC2086
  launchctl bootstrap "gui/$(id -u)" "$1"
}
boot_or_retry "$PLIST_SERVER_DST"
boot_or_retry "$PLIST_UNLOCK_DST"
echo ""
echo "Installed. Behavior:"
echo "  - web UI starts at login"
echo "  - on every (re)start and screen unlock, a native dialog asks whether"
echo "    the official @deepseek-ai/dsh should be updated - never a silent"
echo "    upgrade. Skip keeps the running version; Update UNINSTALLS any"
echo "    conflicting plugin first, shows a live progress window while"
echo "    installing, and restarts the web UI."
echo "  - conflict detection uses the cross-platform checker at"
echo "    deploy/shared/dsh-web-plugin-compat-check.mjs (single source)"
echo "  - after a restart, the current token URL is at $HOME/.dsh/current-url.txt"
echo "    (dsh 0.1.2 browser authentication changes the token per process)"
echo "To restart it anytime:  $HERE/../../restart-dsh-web.sh"
echo "Log: $HOME/.dsh/autostart-update.log"
